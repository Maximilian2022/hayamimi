# -*- coding: utf-8 -*-
"""Local ASR transcription using hayamimi's ReazonSpeech engine."""

from __future__ import annotations

import logging
import os
import sys
from dataclasses import dataclass
from typing import Callable, List, Optional

import numpy as np
import soundfile as sf

# Add scripts directory to path to import asr_engine
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "scripts"))
from asr_engine import RoutedASR  # noqa: E402

logger = logging.getLogger("hayamimi.local_transcribe")


@dataclass
class TranscribedSegment:
    """A segment of transcribed text with approximate time offset."""
    start_sec: float
    end_sec: float
    text: str


@dataclass
class LocalTranscriptionResult:
    """Full result of local transcription."""
    audio_path: str
    duration_sec: float
    segments: List[TranscribedSegment]
    full_text: str


class LocalTranscriber:
    """Transcribes audio using hayamimi's internal ReazonSpeech model to get real misrecognitions."""

    def __init__(self, threads: int = 4):
        self.threads = threads
        self._asr: Optional[RoutedASR] = None

    def _get_engine(self) -> RoutedASR:
        if self._asr is None:
            # Minimal startup: ja only, no warmup, no preload of other languages
            self._asr = RoutedASR(
                threads=self.threads,
                warmup=False,
                preload=False,
                forced_lang="ja",
                punctuate=True,
            )
        return self._asr

    def transcribe_file(
        self,
        wav_path: str,
        chunk_sec: float = 12.0,
        status_callback: Optional[Callable[[str, float], None]] = None,
        log_callback: Optional[Callable[[str, str], None]] = None,
    ) -> LocalTranscriptionResult:
        """Transcribe a 16kHz mono WAV file in chunks to produce test recognition output."""
        if not os.path.isfile(wav_path):
            raise FileNotFoundError(f"Audio file not found: {wav_path}")

        data, sr = sf.read(wav_path, dtype="float32")
        if data.ndim > 1:
            data = data.mean(axis=1)

        total_samples = len(data)
        duration_sec = float(total_samples) / float(sr)
        total_chunks = max(1, int(np.ceil(duration_sec / chunk_sec)))

        if log_callback:
            log_callback("ASR", f"hayamimi (ReazonSpeech) モデル準備完了。音声長: {int(duration_sec)}秒 (全 {total_chunks} チャンク) を順次推論開始...")

        engine = self._get_engine()
        chunk_samples = int(chunk_sec * sr)

        segments: List[TranscribedSegment] = []
        cur_pos = 0
        chunk_idx = 0

        while cur_pos < total_samples:
            end_pos = min(cur_pos + chunk_samples, total_samples)
            chunk = data[cur_pos:end_pos]
            chunk_idx += 1

            start_s = float(cur_pos) / float(sr)
            end_s = float(end_pos) / float(sr)
            progress = min(1.0, end_s / max(0.1, duration_sec))

            time_label = f"{int(start_s // 60):02d}:{int(start_s % 60):02d} - {int(end_s // 60):02d}:{int(end_s % 60):02d}"

            if status_callback:
                status_callback(
                    f"hayamimi (ReazonSpeech) で文字起こし中... ({int(progress * 100)}%)",
                    progress,
                )

            # Skip chunks that are practically silence
            rms = np.sqrt(np.mean(chunk**2)) if len(chunk) > 0 else 0.0
            if rms > 0.005 and len(chunk) > int(0.5 * sr):
                try:
                    res = engine.transcribe(chunk, sr, known_lang="ja", live=False)
                    text = (res.get("text") or "").strip()
                    if text:
                        segments.append(TranscribedSegment(start_sec=start_s, end_sec=end_s, text=text))
                        if log_callback:
                            log_callback("ASR", f"[{chunk_idx}/{total_chunks}] {time_label}: 「{text}」")
                except Exception as e:
                    logger.warning("Error transcribing chunk [%.1f - %.1f]: %s", start_s, end_s, e)
                    if log_callback:
                        log_callback("WARN", f"[{chunk_idx}/{total_chunks}] {time_label} 推論エラー: {e}")
            else:
                if log_callback and (chunk_idx % 5 == 0 or chunk_idx == total_chunks):
                    log_callback("ASR", f"[{chunk_idx}/{total_chunks}] {time_label}: (無音区間をスキップ)")

            cur_pos = end_pos

        full_text = "\n".join(f"[{s.start_sec:.1f}s - {s.end_sec:.1f}s] {s.text}" for s in segments)

        if log_callback:
            log_callback("ASR", f"ローカル文字起こし完了: 全 {len(segments)} 個の発話セグメント（誤認識含む生テキスト）を抽出しました。")
        if status_callback:
            status_callback("ローカル文字起こし完了", 1.0)

        return LocalTranscriptionResult(
            audio_path=wav_path,
            duration_sec=duration_sec,
            segments=segments,
            full_text=full_text,
        )

    def close(self):
        """Release engine resources."""
        if self._asr is not None:
            try:
                self._asr.close()
            except Exception:
                pass
            self._asr = None
