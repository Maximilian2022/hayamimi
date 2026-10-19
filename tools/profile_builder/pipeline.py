# -*- coding: utf-8 -*-
"""End-to-end Speaker Profile generation pipeline for hayamimi."""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import sys
import tempfile
from typing import Callable, Optional

# Add project root to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.profile_builder.gemini_analyzer import GeminiProfileAnalyzer, load_gemini_api_key
from tools.profile_builder.local_transcribe import LocalTranscriber
from tools.profile_builder.profile_exporter import load_profile, save_profile
from tools.profile_builder.profile_model import ExtractedSection, SpeakerProfile
from tools.profile_builder.youtube_fetcher import (
    YouTubeFetcher,
    format_seconds_to_timestamp,
)

logger = logging.getLogger("hayamimi.profile_pipeline")


class ProfileBuilderPipeline:
    """Orchestrates YouTube metadata fetching, section extraction, local transcription,
    and Gemini multimodal analysis to produce a complete speaker profile.
    """

    def __init__(
        self,
        api_key: Optional[str] = None,
        model_name: str = "gemini-2.5-flash",
    ):
        self.api_key = load_gemini_api_key(api_key)
        self.model_name = model_name
        self.fetcher = YouTubeFetcher()

    def run(
        self,
        youtube_url: str,
        speaker_id: Optional[str] = None,
        display_name: Optional[str] = None,
        manual_start_sec: Optional[float] = None,
        duration_sec: float = 720.0,  # 12 minutes
        existing_profile_id: Optional[str] = None,
        status_callback: Optional[Callable[[str, float, str], None]] = None,
    ) -> SpeakerProfile:
        """Execute end-to-end profile generation or incremental training.
        Callback signature: (stage: str, progress: float, message: str)
        """
        def report(stage: str, progress: float, msg: str):
            logger.info("[%s] (%.0f%%) %s", stage, progress * 100, msg)
            if status_callback:
                status_callback(stage, progress, msg)

        # Check if we are growing an existing profile
        target_pid = existing_profile_id or speaker_id
        existing_profile = load_profile(target_pid) if target_pid else None

        temp_dir = tempfile.mkdtemp(prefix="hayamimi_prof_")
        try:
            # 1. Fetch metadata
            report("metadata", 0.05, "動画メタデータを取得中...")
            metadata = self.fetcher.fetch_metadata(youtube_url)

            # Determine speaker_id and display_name
            if existing_profile:
                speaker_id = existing_profile.speaker_id
                display_name = existing_profile.display_name
                report("metadata", 0.15, f"🌱 既存プロファイル '{display_name}' に新動画を追加学習します: {metadata.title}")
            else:
                if not display_name:
                    display_name = metadata.channel or metadata.title[:20]
                if not speaker_id:
                    speaker_id = SpeakerProfile.sanitize_speaker_id(display_name)
                report("metadata", 0.15, f"新規プロファイル生成: {metadata.title} (話者: {display_name})")

            # 2. Determine best audio section
            if manual_start_sec is not None and manual_start_sec >= 0:
                best_start = manual_start_sec
                best_end = min(metadata.duration_sec, best_start + duration_sec)
                report("section", 0.25, f"手動指定区間を採用: {format_seconds_to_timestamp(best_start)} 〜 {format_seconds_to_timestamp(best_end)}")
            else:
                report("section", 0.20, "字幕メタデータをスキャン中...")
                sub_dir = os.path.join(temp_dir, "subtitles")
                os.makedirs(sub_dir, exist_ok=True)
                sub_segments = self.fetcher.fetch_subtitles(youtube_url, sub_dir)

                report("section", 0.25, "スライディングウィンドウ法で最高発話密度区間を計算中...")
                best_start, best_end, score = self.fetcher.find_best_speech_section(
                    sub_segments,
                    video_duration_sec=metadata.duration_sec,
                    window_sec=duration_sec,
                )
                start_str = format_seconds_to_timestamp(best_start)
                end_str = format_seconds_to_timestamp(best_end)
                report("section", 0.30, f"最適区間を特定: {start_str} 〜 {end_str} (密度スコア: {score:.2f})")

            extracted_section = ExtractedSection(
                start_time=format_seconds_to_timestamp(best_start),
                end_time=format_seconds_to_timestamp(best_end),
                duration_sec=best_end - best_start,
            )

            # 3. Download audio section
            wav_path = os.path.join(temp_dir, f"{speaker_id}_raw.wav")
            report("download", 0.35, "該当区間の音声のみをピンポイント取得中...")
            self.fetcher.download_audio_section(
                url=youtube_url,
                start_sec=best_start,
                end_sec=best_end,
                output_wav_path=wav_path,
                status_callback=lambda msg: report("download", 0.40, msg),
            )

            # 4. Local transcription with hayamimi ReazonSpeech
            report("transcribe", 0.45, "hayamimi (ReazonSpeech) によるテスト文字起こしを開始...")
            transcriber = LocalTranscriber()
            try:
                trans_res = transcriber.transcribe_file(
                    wav_path=wav_path,
                    status_callback=lambda msg, prog: report("transcribe", 0.45 + (prog * 0.25), msg),
                )
            finally:
                transcriber.close()

            report("transcribe", 0.70, f"文字起こし完了 ({len(trans_res.segments)} セグメント)")

            # 5. Gemini Multimodal Analysis
            report("analyze", 0.75, "Gemini API に接続しマルチモーダル分析を開始...")
            analyzer = GeminiProfileAnalyzer(
                api_key=self.api_key,
                model_name=self.model_name,
            )
            profile = analyzer.analyze(
                audio_wav_path=wav_path,
                local_asr_text=trans_res.full_text,
                metadata=metadata,
                speaker_id=speaker_id,
                display_name=display_name,
                extracted_section=extracted_section,
                existing_profile=existing_profile,
                status_callback=lambda msg: report("analyze", 0.85, msg),
            )
            profile.source_video_url = youtube_url

            # 6. Save Profile (with merge if growing)
            if existing_profile:
                report("save", 0.92, "既存プロファイルに新動画の知見を統合・マージ中...")
                existing_profile.merge_profile(profile)
                final_profile = existing_profile
            else:
                final_profile = profile

            report("save", 0.95, "プロファイルおよび置換辞書を保存中...")
            saved_path = save_profile(final_profile)
            v_count = len(final_profile.source_video_urls) or (1 if final_profile.source_video_url else 0)
            report("complete", 1.0, f"プロファイル育成が完了しました！ ({saved_path} - 学習動画: {v_count}本, 置換ルール: {len(final_profile.replacements)}件)")

            return final_profile

        finally:
            # Clean up temporary directory
            shutil.rmtree(temp_dir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description="hayamimi Speaker Profile Builder Pipeline")
    parser.add_argument("--url", required=True, help="YouTube video or stream archive URL")
    parser.add_argument("--speaker-id", default=None, help="Speaker identifier (e.g. val_channel)")
    parser.add_argument("--name", default=None, help="Display name (e.g. ヴァル閣下)")
    parser.add_argument("--start", type=float, default=None, help="Manual start offset in seconds")
    parser.add_argument("--duration", type=float, default=720.0, help="Duration in seconds (default: 720 = 12min)")
    parser.add_argument("--key", default=None, help="Gemini API Key")
    parser.add_argument("--model", default="gemini-2.5-flash", help="Gemini model name")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    pipeline = ProfileBuilderPipeline(api_key=args.key, model_name=args.model)
    profile = pipeline.run(
        youtube_url=args.url,
        speaker_id=args.speaker_id,
        display_name=args.name,
        manual_start_sec=args.start,
        duration_sec=args.duration,
        status_callback=lambda stage, prog, msg: print(f"[{prog*100:.0f}%] {msg}"),
    )
    print("\n=== 生成された話者プロファイル ===")
    print(f"話者: {profile.display_name} ({profile.speaker_id})")
    print(f"活舌特徴: {', '.join(profile.articulation_traits)}")
    print(f"補正辞書 ({len(profile.replacements)} 件):")
    for r in profile.replacements:
        print(f"  {r.pattern} -> {r.replacement} ({r.reason or ''})")


if __name__ == "__main__":
    main()
