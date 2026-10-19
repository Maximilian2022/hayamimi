# -*- coding: utf-8 -*-
"""Integration tests for subtitle_server profile and key API endpoints."""

import json
import urllib.request
import urllib.error
import pytest

from scripts.subtitle_server import SubtitleServer
from tools.profile_builder.profile_model import ReplacementRule, SpeakerProfile


@pytest.fixture
def running_server(tmp_path, monkeypatch):
    """Start an in-process SubtitleServer on an ephemeral port."""
    monkeypatch.setenv("PYTEST_CURRENT_TEST", "1")
    # Redirect storage dir to temp
    monkeypatch.setattr("scripts.subtitle_server._get_storage_dir", lambda: str(tmp_path))

    server = SubtitleServer(port=0, host="127.0.0.1")
    # Attach a mock ASR engine
    class MockASR:
        def __init__(self):
            self._replacements = []
        def set_replacements(self, mapping: dict):
            self._replacements = list(mapping.items())

    server.asr = MockASR()
    server.start()
    port = server._httpd.server_address[1]
    base_url = f"http://127.0.0.1:{port}"

    yield base_url, server

    if server._httpd is not None:
        server._httpd.shutdown()


def test_profile_page_served(running_server):
    base_url, _ = running_server
    req = urllib.request.Request(f"{base_url}/profile")
    with urllib.request.urlopen(req) as res:
        assert res.status == 200
        html = res.read().decode("utf-8")
        assert "話者特化プロファイル管理" in html


def test_gemini_key_api(running_server):
    base_url, _ = running_server
    # 1. Initial check (unconfigured)
    with urllib.request.urlopen(f"{base_url}/api/gemini-key") as res:
        data = json.loads(res.read().decode("utf-8"))
        assert data["configured"] is False

    # 2. Save key
    payload = json.dumps({"key": "AIzaSyTestKey1234567890"}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/api/gemini-key",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as res:
        assert res.status == 200

    # 3. Verify masked key
    with urllib.request.urlopen(f"{base_url}/api/gemini-key") as res:
        data = json.loads(res.read().decode("utf-8"))
        assert data["configured"] is True
        assert "AIzaSy" in data["masked"]
        assert "****" in data["masked"] or "7890" in data["masked"]

    # 4. Delete key
    del_payload = json.dumps({"key": ""}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/api/gemini-key",
        data=del_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as res:
        assert res.status == 200

    with urllib.request.urlopen(f"{base_url}/api/gemini-key") as res:
        data = json.loads(res.read().decode("utf-8"))
        assert data["configured"] is False


def test_profiles_crud_api(running_server):
    base_url, server = running_server

    # 1. Initially empty
    with urllib.request.urlopen(f"{base_url}/api/profiles") as res:
        data = json.loads(res.read().decode("utf-8"))
        assert data == []

    # 2. Import profile
    prof = SpeakerProfile(
        speaker_id="test_speaker",
        display_name="テスト話者",
        replacements=[
            ReplacementRule(pattern="かてないですね", replacement="勝てないですね", reason="テスト"),
        ],
    )
    import_payload = json.dumps({"json_content": prof.model_dump_json()}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/api/profiles/import",
        data=import_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as res:
        assert res.status == 200
        imported = json.loads(res.read().decode("utf-8"))
        assert imported["speaker_id"] == "test_speaker"

    # 3. List profiles
    with urllib.request.urlopen(f"{base_url}/api/profiles") as res:
        data = json.loads(res.read().decode("utf-8"))
        assert len(data) == 1
        assert data[0]["display_name"] == "テスト話者"

    # 4. Apply profile
    apply_payload = json.dumps({"speaker_id": "test_speaker"}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/api/profiles/apply",
        data=apply_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as res:
        assert res.status == 200
        res_data = json.loads(res.read().decode("utf-8"))
        assert res_data["ok"] is True
        assert res_data["rules_count"] == 1

    # Verify ASR engine received replacements
    assert ("かてないですね", "勝てないですね") in server.asr._replacements

    # 5. Export profile
    with urllib.request.urlopen(f"{base_url}/api/profiles/test_speaker/export") as res:
        assert res.status == 200
        exported = json.loads(res.read().decode("utf-8"))
        assert exported["speaker_id"] == "test_speaker"

    # 6. Delete profile
    del_payload = json.dumps({"speaker_id": "test_speaker"}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/api/profiles/delete",
        data=del_payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as res:
        assert res.status == 200
        del_res = json.loads(res.read().decode("utf-8"))
        assert del_res["ok"] is True

    # Confirm list is empty
    with urllib.request.urlopen(f"{base_url}/api/profiles") as res:
        data = json.loads(res.read().decode("utf-8"))
        assert data == []


def test_generate_api_with_grow_mode(running_server, monkeypatch):
    base_url, _ = running_server

    captured_call = {}

    class MockPipeline:
        def __init__(self, api_key=None):
            captured_call["api_key"] = api_key
        def run(self, **kwargs):
            captured_call.update(kwargs)
            return SpeakerProfile(
                speaker_id=kwargs.get("speaker_id") or "test_grown",
                display_name="テスト話者",
            )

    monkeypatch.setattr("tools.profile_builder.pipeline.ProfileBuilderPipeline", MockPipeline)

    payload = json.dumps({
        "url": "https://www.youtube.com/watch?v=grow_test",
        "existing_profile_id": "test_speaker",
        "display_name": "テスト話者",
    }).encode("utf-8")

    req = urllib.request.Request(
        f"{base_url}/api/profiles/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as res:
        assert res.status == 202

    # Give thread a moment
    import time
    time.sleep(0.3)

    assert captured_call.get("youtube_url") == "https://www.youtube.com/watch?v=grow_test"
    assert captured_call.get("existing_profile_id") == "test_speaker"

