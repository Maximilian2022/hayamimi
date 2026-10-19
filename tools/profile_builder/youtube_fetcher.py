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


def extract_video_id(url: str) -> Optional[str]:
    """Extract YouTube video ID (11 chars) from URL."""
    if not url:
        return None
    m = re.search(r"(?:[?&]v=|youtu\.be/|/live/|/shorts/)([a-zA-Z0-9_-]{11})", url)
    if m:
        return m.group(1)
    return None


def is_channel_url(url: str) -> bool:
    """Check if the given URL is a YouTube channel / user URL rather than a single video."""
    u = (url or "").strip()
    if not ("youtube.com" in u or "youtu.be" in u):
        return False
    if "watch?v=" in u or "youtu.be/" in u or "/shorts/" in u:
        return False
    return "/@" in u or "/channel/" in u or "/c/" in u or "/user/" in u


class YouTubeFetcher:
    """Fetches video metadata, automatic subtitles, and extracts high-density audio sections."""

    def __init__(self, yt_dlp_cmd: str = "yt-dlp"):
        self.yt_dlp_cmd = yt_dlp_cmd

    def fetch_channel_videos(
        self,
        channel_url: str,
        limit: int = 10,
        candidate_pool: int = 50,
        exclude_video_ids: Optional[set[str]] = None,
        log_callback: Optional[Callable[[str, str], None]] = None,
    ) -> List[dict]:
        """Fetch recent videos from a channel, filter out duplicates, and sort by view_count descending.
        
        Args:
            channel_url: YouTube channel URL (e.g. https://www.youtube.com/@ValChannel)
            limit: Maximum number of videos to return (default: 10)
            candidate_pool: Number of recent videos to fetch for evaluation (default: 50)
            exclude_video_ids: Set of video IDs already trained to prevent duplicate processing.
            log_callback: Optional callback for streaming log messages.
        """
        exclude_video_ids = exclude_video_ids or set()
        clean_url = channel_url.strip()

        # Prioritize /streams (stream archives) then /videos if not specified
        candidate_urls = []
        if "/streams" not in clean_url and "/videos" not in clean_url:
            base = clean_url.rstrip("/")
            candidate_urls = [f"{base}/streams", f"{base}/videos", base]
        else:
            candidate_urls = [clean_url]

        entries = []
        for target_url in candidate_urls:
            if log_callback:
                log_callback("YTDL", f"チャンネル動画をスキャン中: {target_url} (最大{candidate_pool}件)")
            cmd = [
                self.yt_dlp_cmd,
                "--flat-playlist",
                "--dump-json",
                "--playlist-end", str(candidate_pool),
                target_url,
            ]
            try:
                res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
                if res.returncode == 0 and res.stdout.strip():
                    for line in res.stdout.splitlines():
                        line = line.strip()
                        if line:
                            try:
                                data = json.loads(line)
                                entries.append(data)
                            except Exception:
                                pass
                if len(entries) >= 5:
                    break
            except Exception as e:
                logger.warning("Failed to fetch flat playlist from %s: %s", target_url, e)

        # Filter out duplicates and shorts (< 3min)
        valid_videos = []
        seen_ids = set()
        for e in entries:
            vid_id = e.get("id")
            if not vid_id or vid_id in seen_ids:
                continue
            seen_ids.add(vid_id)

            # Skip if already trained in this profile
            if vid_id in exclude_video_ids:
                logger.info("Skipping already trained video: %s - %s", vid_id, e.get("title"))
                continue

            duration = float(e.get("duration", 0) or 0)
            # Skip very short videos (e.g. < 3 minutes)
            if duration and duration < 180:
                continue

            view_count = int(e.get("view_count", 0) or 0)
            video_url = e.get("url")
            if not video_url or not video_url.startswith("http"):
                video_url = f"https://www.youtube.com/watch?v={vid_id}"

            valid_videos.append({
                "id": vid_id,
                "title": e.get("title", ""),
                "url": video_url,
                "view_count": view_count,
                "duration": duration,
                "channel": e.get("channel") or e.get("uploader") or "",
            })

        # Sort by view_count descending (最も再生数が多い人気動画順)
        valid_videos.sort(key=lambda x: x["view_count"], reverse=True)
        chosen = valid_videos[:limit]
        if log_callback:
            dup_cnt = len(seen_ids & exclude_video_ids)
            log_callback(
                "YTDL",
                f"スキャン完了: 取得候補 {len(entries)} 件中、既学習 {dup_cnt} 件をスキップし、再生数上位 {len(chosen)} 件を一括学習対象に決定。"
            )
        return chosen

    def fetch_metadata(self, url: str) -> VideoMetadata:
        """Fetch video metadata without downloading video."""
        cmd = [
            self.yt_dlp_cmd,
            "--dump-json",
            "--no-playlist",
            "--skip-download",
            "--extractor-args", "youtube:player_client=android,web",
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
            "--extractor-args", "youtube:player_client=android,web",
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
        log_callback: Optional[Callable[[str, str], None]] = None,
    ) -> str:
        """Download only the specified section as 16kHz mono WAV for hayamimi."""
        start_ts = format_seconds_to_timestamp(start_sec)
        end_ts = format_seconds_to_timestamp(end_sec)
        if status_callback:
            status_callback(f"音声区間 ({start_ts} 〜 {end_ts}) をピンポイント取得中...")
        if log_callback:
            log_callback("YTDL", f"yt-dlp による部分音声取得を開始: 区間 {start_ts} 〜 {end_ts}")

        section_arg = f"*{start_ts}-{end_ts}"

        # Ensure directory exists
        os.makedirs(os.path.dirname(os.path.abspath(output_wav_path)), exist_ok=True)

        cmd = [
            self.yt_dlp_cmd,
            "--newline",
            "--progress",
            "--progress-delta", "0.5",
            "--no-playlist",
            "--extractor-args", "youtube:player_client=android,web",
            "--download-sections", section_arg,
            "-x",
            "--audio-format", "wav",
            "--postprocessor-args", "ffmpeg:-ar 16000 -ac 1",
            "-o", output_wav_path,
            url,
        ]

        logger.info("Executing download: %s", " ".join(cmd))
        
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )

        output_lines = []
        if proc.stdout:
            for line in proc.stdout:
                line_clean = line.strip()
                if not line_clean:
                    continue
                output_lines.append(line_clean)
                logger.debug("[yt-dlp] %s", line_clean)
                if "[download]" in line_clean:
                    if log_callback:
                        log_callback("YTDL", line_clean)
                    if status_callback:
                        status_callback(line_clean)
                elif any(k in line_clean for k in ("[ExtractAudio]", "Destination", "ffmpeg", "[info]")):
                    if log_callback:
                        log_callback("YTDL", line_clean)
                elif "ERROR" in line_clean or "WARNING" in line_clean:
                    if log_callback:
                        log_callback("WARN" if "WARNING" in line_clean else "ERROR", line_clean)

        ret = proc.wait()
        if ret != 0:
            err_text = "\n".join(output_lines[-15:])
            # If 403 Forbidden or ffmpeg access denied occurred, trigger fallback
            if any(term in err_text for term in ("403", "Forbidden", "access denied", "ffmpeg exited with code")):
                if log_callback:
                    log_callback("WARN", "YouTube から 403/Forbidden を検知しました。ネイティブダウンローダーによる安定取得へ自動フォールバックします...")
                logger.warning("Download section failed with 403 or stream error, falling back to full audio download and local trim: %s", err_text)
                return self._download_and_trim_locally(
                    url=url,
                    start_sec=start_sec,
                    end_sec=end_sec,
                    output_wav_path=output_wav_path,
                    status_callback=status_callback,
                    log_callback=log_callback,
                )
            logger.error("Download failed (code %d): %s", ret, err_text)
            raise RuntimeError(f"yt-dlp failed (code {ret}): {err_text}")

        # yt-dlp might append .wav if output_wav_path didn't have it or slight variation
        if not os.path.exists(output_wav_path):
            alt_path = output_wav_path + ".wav"
            if os.path.exists(alt_path):
                if log_callback:
                    log_callback("YTDL", f"音声抽出完了: {alt_path}")
                return alt_path
            raise FileNotFoundError(f"Downloaded audio not found at {output_wav_path}")

        if log_callback:
            log_callback("YTDL", f"音声抽出完了: {output_wav_path}")
        return output_wav_path

    def _download_and_trim_locally(
        self,
        url: str,
        start_sec: float,
        end_sec: float,
        output_wav_path: str,
        status_callback: Optional[Callable[[str], None]] = None,
        log_callback: Optional[Callable[[str, str], None]] = None,
    ) -> str:
        """Fallback method: Download audio stream via native yt-dlp downloader and trim locally with ffmpeg.
        Bypasses remote ffmpeg HTTP connection to googlevideo CDN, eliminating 403 Forbidden completely.
        """
        import tempfile
        import shutil

        start_ts = format_seconds_to_timestamp(start_sec)
        end_ts = format_seconds_to_timestamp(end_sec)
        dur = max(1.0, end_sec - start_sec)

        temp_dir = tempfile.mkdtemp(prefix="hayamimi_ytdl_fallback_")
        temp_audio = os.path.join(temp_dir, "full_audio.%(ext)s")

        try:
            if status_callback:
                status_callback("音声ストリームを安全に取得中（403回避フォールバック）...")
            if log_callback:
                log_callback("YTDL", "ネイティブダウンローダーで音声ストリームを取得中（403回避）...")

            cmd = [
                self.yt_dlp_cmd,
                "--newline",
                "--progress",
                "--progress-delta", "0.5",
                "--no-playlist",
                "--extractor-args", "youtube:player_client=android,web",
                "-f", "ba/ba*",
                "-o", temp_audio,
                url,
            ]

            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )

            if proc.stdout:
                for line in proc.stdout:
                    line_clean = line.strip()
                    if not line_clean:
                        continue
                    if "[download]" in line_clean:
                        if log_callback:
                            log_callback("YTDL", line_clean)
                        if status_callback:
                            status_callback(line_clean)

            ret = proc.wait()
            if ret != 0:
                raise RuntimeError(f"Fallback full audio download failed with code {ret}")

            # Find downloaded file
            candidates = [os.path.join(temp_dir, f) for f in os.listdir(temp_dir) if os.path.isfile(os.path.join(temp_dir, f))]
            if not candidates:
                raise FileNotFoundError("Downloaded full audio file not found in temp directory")
            downloaded_file = candidates[0]

            if log_callback:
                log_callback("YTDL", f"ローカル音声の切り出し処理中 ({start_ts} 〜 {end_ts})...")
            if status_callback:
                status_callback("ローカル音声から指定区間を高速切り出し中...")

            # Trim with local ffmpeg (16kHz mono WAV)
            trim_cmd = [
                "ffmpeg",
                "-y",
                "-ss", str(start_sec),
                "-t", str(dur),
                "-i", downloaded_file,
                "-ar", "16000",
                "-ac", "1",
                output_wav_path,
            ]
            res = subprocess.run(trim_cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
            if res.returncode != 0:
                raise RuntimeError(f"Local ffmpeg trimming failed: {res.stderr}")

            if log_callback:
                log_callback("YTDL", f"音声抽出完了: {output_wav_path}")
            return output_wav_path

        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

