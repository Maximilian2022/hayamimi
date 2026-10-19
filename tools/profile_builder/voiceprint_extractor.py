# -*- coding: utf-8 -*-
"""Voiceprint extraction module for speaker profiles using CAM++ (sherpa-onnx)."""

import logging
import os
from typing import Callable, List, Optional, Tuple

import numpy as np
import soundfile as sf

logger = logging.getLogger(__name__)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_CAM_MODEL = os.path.join(REPO_ROOT, "models", "campplus_sv.onnx")


class VoiceprintExtractor:
    """Extracts speaker embedding (voiceprint) from audio files using CAM++."""

    def __init__(self, model_path: str = DEFAULT_CAM_MODEL, num_threads: int = 2):
        self.model_path = model_path
        self.num_threads = num_threads
        self._extractor = None

        if os.path.isfile(self.model_path):
            try:
                import sherpa_onnx
                cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                    model=self.model_path, num_threads=self.num_threads
                )
                self._extractor = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)
                logger.info("Initialized CAM++ VoiceprintExtractor with %s", self.model_path)
            except Exception as e:
                logger.warning("Failed to initialize sherpa-onnx SpeakerEmbeddingExtractor: %s", e)
        else:
            logger.info("CAM++ model not found at %s. Voiceprint extraction will be skipped.", self.model_path)

    @property
    def is_available(self) -> bool:
        return self._extractor is not None

    def extract_voiceprint(
        self,
        wav_path: str,
        target_sample_rate: int = 16000,
        max_samples: int = 15,
        min_segment_sec: float = 2.0,
        max_segment_sec: float = 6.0,
        log_callback: Optional[Callable[[str, str], None]] = None,
    ) -> Tuple[Optional[List[float]], int]:
        """Extract average L2-normalized 512-dim voiceprint vector from audio."""
        if not self.is_available:
            if log_callback:
                log_callback("WARN", "声紋モデル (campplus_sv.onnx) が未配備のため、声紋学習はスキップされました。")
            return None, 0

        if not os.path.isfile(wav_path):
            logger.warning("Audio file does not exist: %s", wav_path)
            return None, 0

        try:
            audio, sr = sf.read(wav_path, dtype="float32")
        except Exception as e:
            logger.error("Failed to read audio file %s: %s", wav_path, e)
            if log_callback:
                log_callback("WARN", f"音声ファイルの読み込みに失敗しました: {e}")
            return None, 0

        # Convert stereo to mono
        if audio.ndim > 1:
            audio = np.mean(audio, axis=1)

        # Resample if needed (standard is 16kHz for CAM++)
        if sr != target_sample_rate:
            try:
                from scipy import signal
                num_samples = int(len(audio) * target_sample_rate / sr)
                audio = signal.resample(audio, num_samples)
                sr = target_sample_rate
            except Exception as e:
                logger.warning("Failed to resample audio with scipy: %s", e)

        # Slice into candidate speech segments with high energy (RMS)
        chunk_len = int(max_segment_sec * sr)
        step_len = int(chunk_len * 0.75)
        candidates = []

        total_samples = len(audio)
        for start_idx in range(0, total_samples - chunk_len, step_len):
            chunk = audio[start_idx : start_idx + chunk_len]
            rms = np.sqrt(np.mean(chunk**2))
            if rms > 0.015:  # Non-silent speech threshold
                candidates.append((rms, chunk))

        if not candidates:
            if log_callback:
                log_callback("WARN", "発話区間の音圧が不足していたため、声紋を抽出できませんでした。")
            return None, 0

        # Sort by energy and take top N segments to avoid low-volume noise
        candidates.sort(key=lambda x: x[0], reverse=True)
        selected_chunks = [c[1] for c in candidates[:max_samples]]

        embeddings = []
        for chunk in selected_chunks:
            try:
                stream = self._extractor.create_stream()
                stream.accept_waveform(sr, chunk)
                stream.input_finished()
                emb = np.asarray(self._extractor.compute(stream), dtype=np.float32)
                norm = np.linalg.norm(emb)
                if norm > 1e-9:
                    emb = emb / norm
                    embeddings.append(emb)
            except Exception as e:
                logger.debug("Failed to extract embedding for chunk: %s", e)

        if not embeddings:
            return None, 0

        # Calculate centroid
        centroid = np.mean(embeddings, axis=0)
        norm = float(np.linalg.norm(centroid))
        if norm > 1e-9:
            centroid = centroid / norm

        if log_callback:
            log_callback(
                "VOICE",
                f"CAM++ 声紋ベクトル抽出完了: {len(embeddings)} 区間の発話から 512 次元の話者特徴量を学習しました。",
            )

        return centroid.tolist(), len(embeddings)
