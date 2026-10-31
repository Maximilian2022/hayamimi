# -*- coding: utf-8 -*-
"""Profile storage, persistence, export and import utilities for hayamimi."""

from __future__ import annotations

import json
import logging
import os
import re
from typing import List, Optional

from tools.profile_builder.profile_model import SpeakerProfile

logger = logging.getLogger("hayamimi.profile_exporter")

DEFAULT_PROFILES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "config",
    "profiles",
)

_SAFE_ID_PATTERN = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")


def is_safe_speaker_id(speaker_id: str) -> bool:
    """Validate that speaker_id is alphanumeric with underscores/hyphens and within length limits."""
    if not isinstance(speaker_id, str):
        return False
    return bool(_SAFE_ID_PATTERN.fullmatch(speaker_id))


def _get_safe_profile_path(speaker_id: str, suffix: str, storage_dir: str) -> str:
    """Build and verify that the target path does not escape storage_dir."""
    if not is_safe_speaker_id(speaker_id):
        raise ValueError(f"Invalid speaker_id format: {speaker_id!r}")
    real_storage = os.path.realpath(storage_dir)
    target = os.path.realpath(os.path.join(real_storage, f"{speaker_id}{suffix}"))
    # Ensure target is strictly inside real_storage
    if os.path.commonpath([real_storage, target]) != real_storage:
        raise ValueError(f"Path traversal detected for speaker_id: {speaker_id!r}")
    return target


def ensure_profiles_dir(directory: str = DEFAULT_PROFILES_DIR) -> str:
    """Ensure the profiles directory exists."""
    os.makedirs(directory, exist_ok=True)
    return directory


def save_profile(profile: SpeakerProfile, storage_dir: str = DEFAULT_PROFILES_DIR) -> str:
    """Save profile as both <speaker_id>.json and <speaker_id>_replace.txt."""
    ensure_profiles_dir(storage_dir)

    # 1. Save JSON
    json_path = _get_safe_profile_path(profile.speaker_id, ".json", storage_dir)
    with open(json_path, "w", encoding="utf-8") as f:
        f.write(profile.model_dump_json(indent=2))

    # 2. Save replace.txt for direct hayamimi --replace compatibility
    txt_path = _get_safe_profile_path(profile.speaker_id, "_replace.txt", storage_dir)
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write(profile.to_replace_text())

    logger.info("Saved speaker profile '%s' to %s", profile.speaker_id, json_path)
    return json_path


def load_profile(speaker_id: str, storage_dir: str = DEFAULT_PROFILES_DIR) -> Optional[SpeakerProfile]:
    """Load a single speaker profile by ID."""
    try:
        json_path = _get_safe_profile_path(speaker_id, ".json", storage_dir)
    except ValueError as ve:
        logger.warning("Rejected invalid speaker_id '%s': %s", speaker_id, ve)
        return None

    if not os.path.isfile(json_path):
        return None
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        prof = SpeakerProfile.model_validate(data)
        prof.migrate_from_legacy()
        return prof
    except Exception as e:
        logger.error("Failed to load profile %s: %s", json_path, e)
        return None


def list_profiles(storage_dir: str = DEFAULT_PROFILES_DIR) -> List[SpeakerProfile]:
    """List all available speaker profiles in storage directory."""
    if not os.path.isdir(storage_dir):
        return []

    profiles: List[SpeakerProfile] = []
    for fname in os.listdir(storage_dir):
        if fname.endswith(".json"):
            sid = fname[:-5]
            if not is_safe_speaker_id(sid):
                continue
            prof = load_profile(sid, storage_dir)
            if prof is not None:
                profiles.append(prof)

    # Sort by display name or speaker_id
    profiles.sort(key=lambda p: p.display_name or p.speaker_id)
    return profiles


def delete_profile(speaker_id: str, storage_dir: str = DEFAULT_PROFILES_DIR) -> bool:
    """Delete profile files."""
    try:
        json_path = _get_safe_profile_path(speaker_id, ".json", storage_dir)
        txt_path = _get_safe_profile_path(speaker_id, "_replace.txt", storage_dir)
    except ValueError as ve:
        logger.warning("Rejected delete for invalid speaker_id '%s': %s", speaker_id, ve)
        return False

    deleted = False
    if os.path.isfile(json_path):
        try:
            os.remove(json_path)
            deleted = True
        except Exception as e:
            logger.error("Failed to remove %s: %s", json_path, e)

    if os.path.isfile(txt_path):
        try:
            os.remove(txt_path)
            deleted = True
        except Exception as e:
            logger.error("Failed to remove %s: %s", txt_path, e)

    return deleted


def export_profile_json(profile: SpeakerProfile) -> str:
    """Export profile as formatted JSON string."""
    return profile.model_dump_json(indent=2)


def import_profile_json(
    json_content: str,
    storage_dir: str = DEFAULT_PROFILES_DIR,
    overwrite: bool = True,
) -> SpeakerProfile:
    """Validate and import a profile from JSON string."""
    data = json.loads(json_content)
    profile = SpeakerProfile.model_validate(data)

    if not is_safe_speaker_id(profile.speaker_id):
        raise ValueError(f"Invalid speaker_id in imported profile: {profile.speaker_id!r}")

    existing = load_profile(profile.speaker_id, storage_dir)
    if existing and not overwrite:
        # Create a non-conflicting ID
        candidate_id = f"{profile.speaker_id}_imported"
        if not is_safe_speaker_id(candidate_id):
            candidate_id = "imported_profile"
        profile.speaker_id = candidate_id

    save_profile(profile, storage_dir)
    return profile
