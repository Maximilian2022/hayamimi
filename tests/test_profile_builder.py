# -*- coding: utf-8 -*-
"""Unit tests for Speaker Profile Builder."""

import json
import os
import tempfile
import pytest

from tools.profile_builder.profile_model import (
    ExtractedSection,
    ReplacementRule,
    SpeakerProfile,
)
from tools.profile_builder.profile_exporter import (
    delete_profile,
    export_profile_json,
    import_profile_json,
    list_profiles,
    load_profile,
    save_profile,
)
from tools.profile_builder.youtube_fetcher import (
    SubtitleSegment,
    YouTubeFetcher,
    extract_video_id,
    format_seconds_to_timestamp,
    is_channel_url,
    parse_vtt_content,
    parse_vtt_timestamp,
)


def test_profile_model_sanitization_and_replace_text():
    prof = SpeakerProfile(
        speaker_id="Val Channel @Official!",
        display_name="ヴァル閣下",
        articulation_traits=["サ行が甘い", "語尾脱落"],
        replacements=[
            ReplacementRule(pattern="勝てないとうですね", replacement="勝てないそうですね", reason="サ行化け"),
            ReplacementRule(pattern="ロードライン", replacement="ロードナイン", reason="固有名詞"),
            ReplacementRule(pattern="と", replacement="そ", reason="危険な1文字置換"),
        ],
    )

    # Sanitize speaker_id
    assert prof.speaker_id == "val_channel_official"

    # Filter safe replacements (removes 1-char patterns)
    safe = prof.filter_safe_replacements(min_len=2)
    assert len(safe) == 2
    assert safe[0].pattern == "勝てないとうですね"
    assert safe[1].pattern == "ロードライン"

    # Convert to replace text format
    replace_txt = prof.to_replace_text()
    assert "勝てないとうですね\t勝てないそうですね" in replace_txt
    assert "ロードライン\tロードナイン" in replace_txt


def test_profile_exporter_crud_and_import_export():
    with tempfile.TemporaryDirectory() as tmpdir:
        prof = SpeakerProfile(
            speaker_id="streamer_a",
            display_name="配信者A",
            extracted_section=ExtractedSection(
                start_time="00:10:00",
                end_time="00:22:00",
                duration_sec=720.0,
            ),
            replacements=[
                ReplacementRule(pattern="テストですう", replacement="テストですよ", reason="語尾"),
            ],
        )

        # 1. Save
        json_path = save_profile(prof, storage_dir=tmpdir)
        assert os.path.isfile(json_path)
        txt_path = os.path.join(tmpdir, "streamer_a_replace.txt")
        assert os.path.isfile(txt_path)

        # 2. Load
        loaded = load_profile("streamer_a", storage_dir=tmpdir)
        assert loaded is not None
        assert loaded.speaker_id == "streamer_a"
        assert loaded.display_name == "配信者A"
        assert len(loaded.replacements) == 1
        assert loaded.replacements[0].pattern == "テストですう"

        # 3. List
        all_profs = list_profiles(storage_dir=tmpdir)
        assert len(all_profs) == 1
        assert all_profs[0].speaker_id == "streamer_a"

        # 4. Export JSON
        exported_str = export_profile_json(loaded)
        data = json.loads(exported_str)
        assert data["speaker_id"] == "streamer_a"

        # 5. Import JSON with new ID
        data["speaker_id"] = "streamer_b"
        data["display_name"] = "配信者B"
        imported = import_profile_json(json.dumps(data), storage_dir=tmpdir)
        assert imported.speaker_id == "streamer_b"

        assert len(list_profiles(storage_dir=tmpdir)) == 2

        # 6. Delete
        assert delete_profile("streamer_a", storage_dir=tmpdir) is True
        assert load_profile("streamer_a", storage_dir=tmpdir) is None
        assert len(list_profiles(storage_dir=tmpdir)) == 1


def test_vtt_parsing_and_timestamps():
    sample_vtt = """WEBVTT
Kind: captions
Language: ja

00:00:05.120 --> 00:00:08.450
<c>こんにちはー！</c>本日の配信を<c>始めます。</c>

00:00:10.000 --> 00:00:14.500
今日は<v Speaker>ロードナイン</v>をやっていきましょう。
"""
    segments = parse_vtt_content(sample_vtt)
    assert len(segments) == 2
    assert segments[0].start_sec == pytest.approx(5.12)
    assert segments[0].end_sec == pytest.approx(8.45)
    assert "こんにちはー！本日の配信を始めます。" in segments[0].text

    assert segments[1].start_sec == pytest.approx(10.0)
    assert segments[1].end_sec == pytest.approx(14.5)
    assert "今日はロードナインをやっていきましょう。" in segments[1].text

    assert format_seconds_to_timestamp(75.5) == "01:15"
    assert format_seconds_to_timestamp(3665.0) == "01:01:05"
    assert parse_vtt_timestamp("01:01:05.500") == pytest.approx(3665.5)


def test_find_best_speech_section():
    fetcher = YouTubeFetcher()
    # 2 hours video (7200 seconds)
    # Section 0 - 600s: Opening standby, few words
    # Section 1200 - 2400s: Dense fast-paced gaming speech (high density)
    # Section 3600 - 4200s: Long silence (away from keyboard)
    segments = [
        # Sparse opening
        SubtitleSegment(start_sec=60.0, end_sec=65.0, text="テストテスト"),
        SubtitleSegment(start_sec=180.0, end_sec=185.0, text="音量大丈夫かな"),
    ]

    # Dense section around 1500s - 2200s (every 5 seconds speech)
    for t in range(1300, 2100, 8):
        segments.append(
            SubtitleSegment(
                start_sec=float(t),
                end_sec=float(t + 6),
                text="勝てないですねこれどうやっていくのかな次のボスは強いです",
            )
        )

    best_start, best_end, score = fetcher.find_best_speech_section(
        segments=segments,
        video_duration_sec=7200.0,
        window_sec=720.0,  # 12 minutes
        step_sec=60.0,
    )

    # The best window should be in the dense area (~1300s to 1500s start)
    assert 1200.0 <= best_start <= 1500.0
    assert best_end == best_start + 720.0
    assert score > 0.5


def test_profile_merge_and_grow():
    """Verify profile incremental training / merging preserves rules and tracks history."""
    prof1 = SpeakerProfile(
        speaker_id="streamer_x",
        display_name="配信者X",
        source_video_url="https://youtube.com/watch?v=vid1",
        articulation_traits=["サ行が甘い"],
        replacements=[
            ReplacementRule(pattern="勝てないとう", replacement="勝てないそう", reason="動画1での発見"),
            ReplacementRule(pattern="ロードライン", replacement="ロードナイン", reason="ゲーム名A"),
        ],
        second_pass_hints="動画1の文脈",
    )

    prof2 = SpeakerProfile(
        speaker_id="streamer_x",
        display_name="配信者X",
        source_video_url="https://youtube.com/watch?v=vid2",
        articulation_traits=["語尾脱落", "サ行が甘い"],  # 重複あり
        replacements=[
            ReplacementRule(pattern="ロードライン", replacement="ロードナイン", reason="動画2でも多発"),
            ReplacementRule(pattern="ポーションだす", replacement="ポーションです", reason="動画2での新発見"),
        ],
        second_pass_hints="動画2の文脈",
    )

    prof1.merge_profile(prof2)

    # 1. Video URLs history tracked
    assert len(prof1.source_video_urls) == 2
    assert "https://youtube.com/watch?v=vid1" in prof1.source_video_urls
    assert "https://youtube.com/watch?v=vid2" in prof1.source_video_urls

    # 2. Articulation traits merged uniquely
    assert len(prof1.articulation_traits) == 2
    assert "サ行が甘い" in prof1.articulation_traits
    assert "語尾脱落" in prof1.articulation_traits

    # 3. Replacements merged (2 existing + 1 new = 3 total)
    assert len(prof1.replacements) == 3
    rule_map = {r.pattern: r for r in prof1.replacements}
    assert "勝てないとう" in rule_map
    assert "ロードライン" in rule_map
    assert "ポーションだす" in rule_map
    # Combined reason check
    assert "動画1での発見" in (rule_map["ロードライン"].reason or "") or "ゲーム名A" in (rule_map["ロードライン"].reason or "")
    assert "動画2でも多発" in (rule_map["ロードライン"].reason or "")

    # 4. Hints merged
    assert "動画1の文脈" in (prof1.second_pass_hints or "")
    assert "動画2の文脈" in (prof1.second_pass_hints or "")


def test_url_type_detection_and_video_id():
    """Verify URL classifier and Video ID extractor."""
    # Video ID extraction
    assert extract_video_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ"
    assert extract_video_id("https://youtu.be/dQw4w9WgXcQ?t=10") == "dQw4w9WgXcQ"
    assert extract_video_id("https://www.youtube.com/live/dQw4w9WgXcQ?feature=share") == "dQw4w9WgXcQ"
    assert extract_video_id("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ"
    assert extract_video_id("https://www.youtube.com/@ValChannel") is None

    # Channel URL classification
    assert is_channel_url("https://www.youtube.com/@ValChannel") is True
    assert is_channel_url("https://www.youtube.com/@ValChannel/streams") is True
    assert is_channel_url("https://www.youtube.com/@ValChannel/videos") is True
    assert is_channel_url("https://www.youtube.com/channel/UC1234567890abcdef") is True
    assert is_channel_url("https://www.youtube.com/c/SomeCreator") is True
    assert is_channel_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ") is False
    assert is_channel_url("https://youtu.be/dQw4w9WgXcQ") is False


def test_fetch_channel_videos_duplicate_prevention(monkeypatch):
    """Verify channel videos are sorted by view_count and duplicates are filtered out."""
    fetcher = YouTubeFetcher()

    fake_entries = [
        # Video 1: Popular but already trained
        {"id": "vid_already1", "title": "配信1 (既学習)", "view_count": 50000, "duration": 7200, "channel": "Ch"},
        # Video 2: Recent, 20k views
        {"id": "vid_new_pop", "title": "人気配信2", "view_count": 20000, "duration": 5400, "channel": "Ch"},
        # Video 3: Recent, 5k views
        {"id": "vid_new_norm", "title": "通常配信3", "view_count": 5000, "duration": 3600, "channel": "Ch"},
        # Video 4: Short video (< 3min, should be skipped)
        {"id": "vid_short", "title": "告知ショート", "view_count": 100000, "duration": 45, "channel": "Ch"},
        # Video 5: Recent, 30k views
        {"id": "vid_new_top", "title": "最高再生配信5", "view_count": 30000, "duration": 6000, "channel": "Ch"},
    ]

    import subprocess
    fake_jsonl = "\n".join([json.dumps(e) for e in fake_entries])

    class MockCompletedProcess:
        returncode = 0
        stdout = fake_jsonl
        stderr = ""

    monkeypatch.setattr(subprocess, "run", lambda *args, **kwargs: MockCompletedProcess())

    # Exclude vid_already1
    videos = fetcher.fetch_channel_videos(
        channel_url="https://www.youtube.com/@ValChannel",
        limit=2,
        candidate_pool=10,
        exclude_video_ids={"vid_already1"},
    )

    # vid_already1 must be excluded (duplicate prevention)
    # vid_short must be excluded (too short)
    # Remaining candidates: vid_new_top (30k), vid_new_pop (20k), vid_new_norm (5k)
    # Sorted by view_count descending, top 2
    assert len(videos) == 2
    assert videos[0]["id"] == "vid_new_top"
    assert videos[1]["id"] == "vid_new_pop"
    assert videos[0]["view_count"] == 30000
    assert videos[1]["view_count"] == 20000


