# -*- coding: utf-8 -*-
"""Profile storage, persistence, export and import utilities for hayamimi."""

from __future__ import annotations

import json
import logging
import os
from typing import List, Optional

from tools.profile_builder.profile_model import SpeakerProfile

logger = logging.getLogger("hayamimi.profile_exporter")

DEFAULT_PROFILES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "config",
    "profiles",
)


def ensure_profiles_dir(directory: str = DEFAULT_PROFILES_DIR) -> str:
    """Ensure the profiles directory exists."""
    os.makedirs(directory, exist_ok=True)
    return directory


def save_profile(profile: SpeakerProfile, storage_dir: str = DEFAULT_PROFILES_DIR) -> str:
    """Save profile as both <speaker_id>.json and <speaker_id>_replace.txt."""
    ensure_profiles_dir(storage_dir)

    # 1. Save JSON
    json_path = os.path.join(storage_dir, f"{profile.speaker_id}.json")
    with open(json_path, "w", encoding="utf-8") as f:
        f.write(profile.model_dump_json(indent=2))

    # 2. Save replace.txt for direct hayamimi --replace compatibility
    txt_path = os.path.join(storage_dir, f"{profile.speaker_id}_replace.txt")
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write(profile.to_replace_text())

    logger.info("Saved speaker profile '%s' to %s", profile.speaker_id, json_path)
    return json_path


def load_profile(speaker_id: str, storage_dir: str = DEFAULT_PROFILES_DIR) -> Optional[SpeakerProfile]:
    """Load a single speaker profile by ID."""
    json_path = os.path.join(storage_dir, f"{speaker_id}.json")
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
            prof = load_profile(sid, storage_dir)
            if prof is not None:
                profiles.append(prof)

    # Sort by display name or updated_at
    profiles.sort(key=lambda p: p.display_name or p.speaker_id)
    return profiles


def delete_profile(speaker_id: str, storage_dir: str = DEFAULT_PROFILES_DIR) -> bool:
    """Delete profile files."""
    deleted = False
    json_path = os.path.join(storage_dir, f"{speaker_id}.json")
    txt_path = os.path.join(storage_dir, f"{speaker_id}_replace.txt")

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

    existing = load_profile(profile.speaker_id, storage_dir)
    if existing and not overwrite:
        # Create a non-conflicting ID
        profile.speaker_id = f"{profile.speaker_id}_imported"

    save_profile(profile, storage_dir)
    return profile
