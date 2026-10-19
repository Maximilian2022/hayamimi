# -*- coding: utf-8 -*-
"""YouTube fetcher and speech density extractor for hayamimi."""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from typing import Callable, List, Optional, Tuple

logger = logging.getLogger("hayamimi.youtube_fetcher")


@dataclass
class SubtitleSegment:
    """Represents a single timed subtitle line."""
    start_sec: float
    end_sec: float
    text: str


@dataclass
class VideoMetadata:
    """Metadata extracted from YouTube video."""
    video_id: str
    title: str
    channel: str
    description: str
    duration_sec: float
    tags: List[str]


def parse_vtt_timestamp(ts: str) -> float:
    """Parse VTT timestamp (e.g. '01:23:45.678' or '12:34.567') to seconds."""
    ts = ts.strip()
    parts = ts.split(":")
    if len(parts) == 3:
        h, m, s = parts
        return float(h) * 3600 + float(m) * 60 + float(s)
    elif len(parts) == 2:
        m, s = parts
        return float(m) * 60 + float(s)
    return float(ts)


def format_seconds_to_timestamp(seconds: float) -> str:
    """Format seconds to HH:MM:SS string."""
    seconds = max(0.0, seconds)
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    if h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def parse_vtt_content(vtt_text: str) -> List[SubtitleSegment]:
    """Parse WebVTT content into a list of SubtitleSegments."""
    segments: List[SubtitleSegment] = []
    # Pattern for timestamp lines: 00:00:10.500 --> 00:00:13.200
    ts_pattern = re.compile(
        r"(\d{1,2}:(?:\d{2}:)?\d{2}\.\d{3})\s*-->\s*(\d{1,2}:(?:\d{2}:)?\d{2}\.\d{3})"
    )

    lines = vtt_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        match = ts_pattern.search(line)
        if match:
            start_sec = parse_vtt_timestamp(match.group(1))
            end_sec = parse_vtt_timestamp(match.group(2))
            text_lines = []
            i += 1
            while i < len(lines) and lines[i].strip() and not ts_pattern.search(lines[i]):
                # Strip HTML/VTT tags like <c> </c> <v Speaker>
                cleaned = re.sub(r"<[^>]+>", "", lines[i].strip())
                if cleaned:
                    text_lines.append(cleaned)
                i += 1
            text = " ".join(text_lines).strip()
            if text and end_sec > start_sec:
                segments.append(SubtitleSegment(start_sec=start_sec, end_sec=end_sec, text=text))
            continue
        i += 1

    return segments


class YouTubeFetcher:
    """Fetches video metadata, automatic subtitles, and extracts high-density audio sections."""

    def __init__(self, yt_dlp_cmd: str = "yt-dlp"):
        self.yt_dlp_cmd = yt_dlp_cmd

    def fetch_metadata(self, url: str) -> VideoMetadata:
        """Fetch video metadata without downloading video."""
        cmd = [
            self.yt_dlp_cmd,
            "--dump-json",
            "--no-playlist",
            "--skip-download",
            url,
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", check=True)
        data = json.loads(res.stdout)
        return VideoMetadata(
            video_id=data.get("id", ""),
            title=data.get("title", ""),
            channel=data.get("uploader", "") or data.get("channel", ""),
            description=data.get("description", ""),
            duration_sec=float(data.get("duration", 0) or 0),
            tags=data.get("tags", []) or [],
        )

    def fetch_subtitles(self, url: str, temp_dir: str) -> List[SubtitleSegment]:
        """Fetch Japanese automatic subtitles (.vtt) without downloading video."""
        out_template = os.path.join(temp_dir, "%(id)s.%(ext)s")
        cmd = [
            self.yt_dlp_cmd,
            "--skip-download",
            "--write-auto-sub",
            "--sub-lang", "ja",
            "--sub-format", "vtt",
            "-o", out_template,
            url,
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
        if res.returncode != 0:
            logger.warning("Failed to fetch auto-subtitles: %s", res.stderr)
            return []

        # Find generated .vtt file
        vtt_files = [f for f in os.listdir(temp_dir) if f.endswith(".vtt")]
        if not vtt_files:
            return []

        vtt_path = os.path.join(temp_dir, vtt_files[0])
        try:
            with open(vtt_path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            return parse_vtt_content(content)
        except Exception as e:
            logger.error("Error reading VTT file %s: %s", vtt_path, e)
            return []

    def find_best_speech_section(
        self,
        segments: List[SubtitleSegment],
        video_duration_sec: float,
        window_sec: float = 720.0,  # 12 minutes
        step_sec: float = 60.0,
    ) -> Tuple[float, float, float]:
        """Find the section with highest speech density using a sliding window.
        Returns:
            (start_sec, end_sec, score)
        """
        # If video is shorter than window, return the full duration
        if video_duration_sec <= window_sec:
            return (0.0, video_duration_sec, 1.0)

        # If no subtitles available, fall back to [15min, 27min] or start of video
        if not segments:
            default_start = min(900.0, max(0.0, video_duration_sec - window_sec))
            return (default_start, min(video_duration_sec, default_start + window_sec), 0.5)

        best_start = 0.0
        best_score = -1.0

        current_start = 0.0
        max_start = max(0.0, video_duration_sec - window_sec)

        while current_start <= max_start:
            window_end = current_start + window_sec
            # Filter segments inside this window
            sub_in_window = [
                s for s in segments
                if (s.start_sec < window_end and s.end_sec > current_start)
            ]

            speech_sec = 0.0
            char_count = 0
            max_silence = 0.0
            last_end = current_start

            for s in sub_in_window:
                eff_start = max(s.start_sec, current_start)
                eff_end = min(s.end_sec, window_end)
                if eff_end > eff_start:
                    speech_sec += (eff_end - eff_start)
                    char_count += len(s.text)
                    silence = eff_start - last_end
                    if silence > max_silence:
                        max_silence = silence
                    last_end = eff_end

            tail_silence = window_end - last_end
            if tail_silence > max_silence:
                max_silence = tail_silence

            # Score calculation
            # 1. Ratio of actual speech time in window (0.0 - 1.0)
            speech_ratio = speech_sec / window_sec
            # 2. Characters per minute (approx 300 cpm is normal active speech)
            char_density = min(1.0, (char_count / (window_sec / 60.0)) / 350.0)
            # 3. Penalty for silence gaps over 30 seconds (away from keyboard / loading)
            silence_penalty = 0.3 if max_silence > 30.0 else 0.0

            # Penalty for opening 5 minutes (often standby screen / BGM)
            opening_penalty = 0.2 if current_start < 300.0 else 0.0

            score = (speech_ratio * 0.6) + (char_density * 0.4) - silence_penalty - opening_penalty

            if score > best_score:
                best_score = score
                best_start = current_start

            current_start += step_sec

        return (best_start, best_start + window_sec, max(0.0, best_score))

    def download_audio_section(
        self,
        url: str,
        start_sec: float,
        end_sec: float,
        output_wav_path: str,
        status_callback: Optional[Callable[[str], None]] = None,
    ) -> str:
        """Download only the specified section as 16kHz mono WAV for hayamimi."""
        if status_callback:
            start_str = format_seconds_to_timestamp(start_sec)
            end_str = format_seconds_to_timestamp(end_sec)
            status_callback(f"音声区間 ({start_str} 〜 {end_str}) をピンポイント取得中...")

        start_ts = format_seconds_to_timestamp(start_sec)
        end_ts = format_seconds_to_timestamp(end_sec)
        section_arg = f"*{start_ts}-{end_ts}"

        # Ensure directory exists
        os.makedirs(os.path.dirname(os.path.abspath(output_wav_path)), exist_ok=True)

        cmd = [
            self.yt_dlp_cmd,
            "--no-playlist",
            "--download-sections", section_arg,
            "-x",
            "--audio-format", "wav",
            "--postprocessor-args", "ffmpeg:-ar 16000 -ac 1",
            "-o", output_wav_path,
            url,
        ]

        logger.info("Executing download: %s", " ".join(cmd))
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
        if res.returncode != 0:
            logger.error("Download failed: %s", res.stderr)
            raise RuntimeError(f"yt-dlp failed: {res.stderr}")

        # yt-dlp might append .wav if output_wav_path didn't have it or slight variation
        if not os.path.exists(output_wav_path):
            alt_path = output_wav_path + ".wav"
            if os.path.exists(alt_path):
                return alt_path
            raise FileNotFoundError(f"Downloaded audio not found at {output_wav_path}")

        return output_wav_path
