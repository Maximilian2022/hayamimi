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
from tools.profile_builder.voiceprint_extractor import VoiceprintExtractor
from tools.profile_builder.youtube_fetcher import (
    YouTubeFetcher,
    extract_video_id,
    format_seconds_to_timestamp,
    is_channel_url,
)

logger = logging.getLogger("hayamimi.profile_pipeline")


class ProfileBuilderPipeline:
    """Orchestrates YouTube metadata fetching, section extraction, local transcription,
    and Gemini multimodal analysis to produce a complete speaker profile.
    Supports both individual video URLs and channel URLs (batch learning recent popular videos).
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
        max_videos: int = 10,
        existing_profile_id: Optional[str] = None,
        status_callback: Optional[Callable[[str, float, str], None]] = None,
        log_callback: Optional[Callable[[str, str], None]] = None,
    ) -> SpeakerProfile:
        """Execute end-to-end profile generation or incremental training.
        If youtube_url is a channel URL, fetches recent popular videos and processes them in batch.
        Callback signature: (stage: str, progress: float, message: str)
        """
        def log(level: str, msg: str):
            logger.info("[%s] %s", level, msg)
            if log_callback:
                log_callback(level, msg)

        def report(stage: str, progress: float, msg: str):
            logger.info("[%s] (%.0f%%) %s", stage, progress * 100, msg)
            if status_callback:
                status_callback(stage, progress, msg)
            log("STEP", f"({int(progress * 100)}%) {msg}")

        target_pid = existing_profile_id or speaker_id
        existing_profile = load_profile(target_pid) if target_pid else None

        # Check if URL is a YouTube channel URL
        if is_channel_url(youtube_url):
            report("channel", 0.02, f"チャンネルURLを検出しました。最新・人気動画をスキャン中: {youtube_url}")

            # Collect already processed video IDs to prevent duplicate work
            exclude_ids = set()
            if existing_profile:
                exclude_ids.update(existing_profile.processed_video_ids)
                for u in existing_profile.source_video_urls:
                    vid = extract_video_id(u)
                    if vid:
                        exclude_ids.add(vid)

            videos = self.fetcher.fetch_channel_videos(
                channel_url=youtube_url,
                limit=max_videos,
                candidate_pool=50,
                exclude_video_ids=exclude_ids,
                log_callback=log,
            )

            if not videos:
                if exclude_ids:
                    msg = f"チャンネル内の最近の人気動画はすべて学習済みです（学習済み: {len(exclude_ids)}本、スキップ完了）。"
                else:
                    msg = "チャンネルから対象動画が見つかりませんでした。"
                report("complete", 1.0, msg)
                if existing_profile:
                    return existing_profile
                raise ValueError(msg)

            total_vids = len(videos)
            report(
                "channel",
                0.05,
                f"チャンネルから直近の人気動画 {total_vids} 本を抽出しました（重複 {len(exclude_ids)} 本は自動除外）。一括学習を開始します...",
            )

            cur_prof = existing_profile
            for idx, vid_info in enumerate(videos):
                v_url = vid_info["url"]
                v_title = vid_info.get("title", "動画")
                v_chan = vid_info.get("channel", "")

                p_start = (idx / total_vids) * 0.95
                p_end = ((idx + 1) / total_vids) * 0.95

                def _sub_cb(stage: str, sub_prog: float, msg: str):
                    overall = p_start + (sub_prog * (p_end - p_start))
                    report(stage, overall, f"[{idx+1}/{total_vids}本目] 『{v_title[:22]}...』: {msg}")

                log("BATCH", f"========== [{idx+1}/{total_vids}本目] 『{v_title}』 の処理を開始 ==========")
                cur_prof = self._process_single_video(
                    youtube_url=v_url,
                    speaker_id=speaker_id or (cur_prof.speaker_id if cur_prof else None),
                    display_name=display_name or (cur_prof.display_name if cur_prof else v_chan),
                    duration_sec=duration_sec,
                    existing_profile=cur_prof,
                    status_callback=_sub_cb,
                    log_callback=log_callback,
                )

            learned_count = len(cur_prof.processed_video_ids) or len(cur_prof.source_video_urls)
            report(
                "complete",
                1.0,
                f"🎉 チャンネル一括学習が完了しました！ (累計学習: {learned_count}本, 置換ルール: {len(cur_prof.replacements)}件)",
            )
            return cur_prof

        # Single video URL processing
        return self._process_single_video(
            youtube_url=youtube_url,
            speaker_id=speaker_id,
            display_name=display_name,
            manual_start_sec=manual_start_sec,
            duration_sec=duration_sec,
            existing_profile=existing_profile,
            status_callback=status_callback,
            log_callback=log_callback,
        )

    def _process_single_video(
        self,
        youtube_url: str,
        speaker_id: Optional[str] = None,
        display_name: Optional[str] = None,
        manual_start_sec: Optional[float] = None,
        duration_sec: float = 720.0,
        existing_profile: Optional[SpeakerProfile] = None,
        status_callback: Optional[Callable[[str, float, str], None]] = None,
        log_callback: Optional[Callable[[str, str], None]] = None,
    ) -> SpeakerProfile:
        """Process a single YouTube video end-to-end and merge into existing profile if given."""
        def log(level: str, msg: str):
            logger.info("[%s] %s", level, msg)
            if log_callback:
                log_callback(level, msg)

        def report(stage: str, progress: float, msg: str):
            logger.info("[%s] (%.0f%%) %s", stage, progress * 100, msg)
            if status_callback:
                status_callback(stage, progress, msg)
            log("STEP", f"({int(progress * 100)}%) {msg}")

        temp_dir = tempfile.mkdtemp(prefix="hayamimi_prof_")
        try:
            # 1. Fetch metadata
            report("metadata", 0.05, "動画メタデータを取得中...")
            metadata = self.fetcher.fetch_metadata(youtube_url)
            log("INFO", f"メタデータ取得完了: タイトル『{metadata.title}』 / チャンネル: {metadata.channel} / 長さ: {int(metadata.duration_sec)}秒")

            # Determine speaker_id and display_name
            if existing_profile:
                speaker_id = existing_profile.speaker_id
                display_name = existing_profile.display_name
                report("metadata", 0.15, f"🌱 既存プロファイル '{display_name}' に新動画を追加学習: {metadata.title}")
            else:
                if not display_name:
                    display_name = metadata.channel or metadata.title[:20]
                if not speaker_id:
                    speaker_id = SpeakerProfile.sanitize_speaker_id(display_name)
                report("metadata", 0.15, f"プロファイル生成: {metadata.title} (話者: {display_name})")

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
                log("INFO", f"字幕メタデータ取得完了: {len(sub_segments)} 件の字幕セグメント")

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

            def _dl_status(msg: str):
                import re
                m = re.search(r"(\d+(\.\d+)?)%", msg)
                if m:
                    pct = float(m.group(1)) / 100.0
                    overall = 0.35 + (pct * 0.10)
                    clean_dl = msg.replace("[download]", "").strip()
                    report("download", overall, f"音声区間をDL中: {clean_dl}")
                else:
                    report("download", 0.38, msg)

            self.fetcher.download_audio_section(
                url=youtube_url,
                start_sec=best_start,
                end_sec=best_end,
                output_wav_path=wav_path,
                status_callback=_dl_status,
                log_callback=log_callback,
            )

            # 4. Local transcription with hayamimi ReazonSpeech
            report("transcribe", 0.45, "hayamimi (ReazonSpeech) によるテスト文字起こしを開始...")
            transcriber = LocalTranscriber()
            try:
                trans_res = transcriber.transcribe_file(
                    wav_path=wav_path,
                    status_callback=lambda msg, prog: report("transcribe", 0.45 + (prog * 0.25), msg),
                    log_callback=log_callback,
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
                log_callback=log_callback,
            )
            profile.source_video_url = youtube_url

            # Track video ID for duplicate prevention
            vid_id = metadata.video_id or extract_video_id(youtube_url)
            if vid_id and vid_id not in profile.processed_video_ids:
                profile.processed_video_ids.append(vid_id)

            # 5.5 Extract Voiceprint (CAM++ 512-dim embedding)
            report("voiceprint", 0.88, "CAM++ による話者声紋（512次元ベクトル）を抽出中...")
            try:
                voice_extractor = VoiceprintExtractor()
                if voice_extractor.is_available:
                    v_vec, v_count = voice_extractor.extract_voiceprint(
                        wav_path=wav_path,
                        log_callback=log_callback,
                    )
                    if v_vec:
                        profile.voiceprint = v_vec
                        profile.voiceprint_sample_count = v_count
                        log("VOICE", f"声紋登録完了: {v_count} サンプルから話者特徴量を学習しました。")
                else:
                    log("INFO", "声紋モデル (campplus_sv.onnx) が未検出のため声紋抽出はスキップされました。")
            except Exception as e:
                logger.warning("Voiceprint extraction failed: %s", e)
                log("WARN", f"声紋抽出で例外が発生したためスキップしました: {e}")

            # 6. Save Profile (with merge if growing)
            if existing_profile:
                report("save", 0.92, "既存プロファイルに新動画の知見（辞書・活舌・声紋）を統合・マージ中...")
                existing_profile.merge_profile(profile)
                final_profile = existing_profile
            else:
                final_profile = profile

            report("save", 0.95, "プロファイルおよび置換辞書を保存中...")
            saved_path = save_profile(final_profile)
            v_count = len(final_profile.processed_video_ids) or len(final_profile.source_video_urls) or (1 if final_profile.source_video_url else 0)
            report("complete", 1.0, f"完了: {saved_path} (学習動画: {v_count}本, 置換ルール: {len(final_profile.replacements)}件)")
            log("SUCCESS", f"プロファイルを正常に保存しました: {final_profile.display_name} ({len(final_profile.replacements)} 件の置換ルール)")

            return final_profile

        finally:
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
