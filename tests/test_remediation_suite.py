# -*- coding: utf-8 -*-
import json
import pytest
import os
import sys

# Ensure scripts dir is on sys.path for itn_cjk
scripts_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
if scripts_dir not in sys.path:
    sys.path.insert(0, scripts_dir)

from scripts.subtitle_server import SubtitleServer, _deep_merge_dict, _sanitize_overlay_style
from tools.profile_builder.profile_exporter import (
    is_safe_speaker_id,
    save_profile,
    load_profile,
    delete_profile,
    _get_safe_profile_path,
)
from tools.profile_builder.profile_model import SpeakerProfile, ReplacementRule
from tools.profile_builder.youtube_fetcher import validate_youtube_url


def test_b4_empty_replacement_protection():
    """Verify that empty or whitespace pattern does not trigger character insertion."""
    from scripts.asr_engine import RoutedASR
    # Test dictionary sanitizer directly
    asr = RoutedASR.__new__(RoutedASR)
    asr._stats_lock = pytest.importorskip("threading").Lock()
    asr._rule_hit_counts = {}
    asr._rule_last_hit = {}
    asr._replacements = ()

    # Set replacements containing empty string and valid pattern
    asr.set_replacements({
        "": "BAD",
        "  ": "BAD",
        "草": "笑",
    })
    assert asr._replacements == (("草", "笑"),)

    # _replace execution
    res = asr._replace("大草原不可避")
    assert res == "大笑原不可避"
    assert asr._rule_hit_counts.get("草") == 1
    assert "BAD" not in res


def test_s2_speaker_id_traversal_validation():
    """Verify path traversal prevention in speaker profiles."""
    assert is_safe_speaker_id("valid_speaker-123") is True
    assert is_safe_speaker_id("../evil") is False
    assert is_safe_speaker_id("speaker/hack") is False
    assert is_safe_speaker_id("speaker\\hack") is False
    assert is_safe_speaker_id("speaker*bad") is False
    assert is_safe_speaker_id("") is False

    # Calling _get_safe_profile_path with invalid id should raise ValueError
    with pytest.raises(ValueError, match="Invalid speaker_id"):
        _get_safe_profile_path("../traversal_test", ".json", "config/profiles")

    # Calling load_profile or delete_profile with unsafe ID safely rejects
    assert load_profile("../traversal_test") is None
    assert delete_profile("../traversal_test") is False


def test_s3_youtube_url_validation():
    """Verify that CLI injection and non-YouTube URLs are rejected."""
    assert validate_youtube_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    assert validate_youtube_url("https://youtu.be/dQw4w9WgXcQ")
    assert validate_youtube_url("https://m.youtube.com/@ChannelName")

    with pytest.raises(ValueError, match="cannot start with a dash"):
        validate_youtube_url("--version")

    with pytest.raises(ValueError, match="not a recognized YouTube domain"):
        validate_youtube_url("https://malicious-site.com/exploit")

    with pytest.raises(ValueError, match="only http and https allowed"):
        validate_youtube_url("file:///etc/passwd")


def test_s7_style_sanitizer():
    """Verify that overlay style properties are safely clamped."""
    raw = {
        "size": 9999,
        "strokeWidth": -50,
        "mode": "invalid_mode",
        "main": {
            "size": 5, # too small
            "strokeWidth": 100, # too large
        }
    }
    sanitized = _sanitize_overlay_style(raw)
    assert sanitized["size"] == 200
    assert sanitized["strokeWidth"] == 0.0
    assert sanitized["mode"] == "unified"
    assert sanitized["main"]["size"] == 8
    assert sanitized["main"]["strokeWidth"] == 30.0


def test_b6_deep_merge_style():
    """Verify deep merge preserves sub-dictionaries."""
    base = {
        "mode": "split",
        "main": {"font": "Zen", "size": 42, "color": "#ffffff"},
        "trans": {"font": "Zen", "size": 32, "color": "#ffd166"},
    }
    update = {
        "main": {"size": 48},
    }
    merged = _deep_merge_dict(base, update)
    assert merged["main"]["size"] == 48
    assert merged["main"]["font"] == "Zen"
    assert merged["main"]["color"] == "#ffffff"
    assert merged["trans"]["color"] == "#ffd166"
