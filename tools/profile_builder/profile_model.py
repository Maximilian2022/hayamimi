# -*- coding: utf-8 -*-
"""Speaker Profile data model and serialization utilities for hayamimi."""

from __future__ import annotations

import datetime
import re
from typing import List, Optional
from pydantic import BaseModel, Field, field_validator


class ExtractedSection(BaseModel):
    """Information about the audio section extracted from YouTube."""
    start_time: str = Field(..., description="Start timestamp in HH:MM:SS or MM:SS format")
    end_time: str = Field(..., description="End timestamp in HH:MM:SS or MM:SS format")
    duration_sec: float = Field(..., description="Duration of extracted section in seconds")


class ReplacementRule(BaseModel):
    """Individual word/phrase replacement rule."""
    pattern: str = Field(..., description="Misrecognized phrase or word")
    replacement: str = Field(..., description="Correct intended phrase or word")
    reason: Optional[str] = Field(None, description="Reason for replacement (articulation habit, game term, etc.)")

    @field_validator("pattern", "replacement")
    @classmethod
    def strip_whitespace(cls, v: str) -> str:
        return v.strip()


class SpeakerProfile(BaseModel):
    """Complete speaker profile model."""
    schema_version: str = Field("1.0.0", description="Schema version")
    speaker_id: str = Field(..., description="Unique alphanumeric identifier (e.g. val_channel)")
    display_name: str = Field(..., description="Human-readable display name (e.g. ヴァル閣下)")
    created_at: str = Field(
        default_factory=lambda: datetime.datetime.now(datetime.timezone.utc).isoformat(),
        description="Creation timestamp (ISO 8601)",
    )
    updated_at: str = Field(
        default_factory=lambda: datetime.datetime.now(datetime.timezone.utc).isoformat(),
        description="Last update timestamp (ISO 8601)",
    )
    source_video_url: Optional[str] = Field(None, description="Source YouTube video URL")
    source_video_urls: List[str] = Field(
        default_factory=list,
        description="List of YouTube video URLs processed to train this profile",
    )
    extracted_section: Optional[ExtractedSection] = Field(None, description="Extracted section info")
    articulation_traits: List[str] = Field(
        default_factory=list,
        description="List of identified pronunciation traits (e.g. サ行が甘くタ行に化けやすい)",
    )
    replacements: List[ReplacementRule] = Field(
        default_factory=list,
        description="List of replacement rules",
    )
    second_pass_hints: Optional[str] = Field(
        None,
        description="Context hints for 2nd-pass refinement models",
    )

    def merge_profile(self, other: "SpeakerProfile") -> "SpeakerProfile":
        """Merge another profile's findings (from an additional YouTube video) into this profile.
        - Preserves existing rules and appends new unique rules.
        - Combines articulation traits without duplicates.
        - Keeps full training history of source video URLs.
        - Updates updated_at timestamp.
        """
        urls = list(self.source_video_urls)
        if self.source_video_url and self.source_video_url not in urls:
            urls.append(self.source_video_url)
        for u in other.source_video_urls:
            if u and u not in urls:
                urls.append(u)
        if other.source_video_url and other.source_video_url not in urls:
            urls.append(other.source_video_url)
        self.source_video_urls = urls
        if other.source_video_url:
            self.source_video_url = other.source_video_url

        existing_traits = list(self.articulation_traits)
        for t in other.articulation_traits:
            if t and t not in existing_traits:
                existing_traits.append(t)
        self.articulation_traits = existing_traits

        rule_map = {r.pattern: r for r in self.replacements}
        for new_r in other.replacements:
            if new_r.pattern in rule_map:
                cur = rule_map[new_r.pattern]
                if new_r.reason and new_r.reason not in (cur.reason or ""):
                    combined_reason = f"{cur.reason}; {new_r.reason}" if cur.reason else new_r.reason
                    rule_map[new_r.pattern] = ReplacementRule(
                        pattern=cur.pattern,
                        replacement=cur.replacement,
                        reason=combined_reason,
                    )
            else:
                rule_map[new_r.pattern] = new_r
        self.replacements = list(rule_map.values())

        hints = []
        if self.second_pass_hints:
            hints.append(self.second_pass_hints.strip())
        if other.second_pass_hints and other.second_pass_hints.strip() not in hints:
            hints.append(other.second_pass_hints.strip())
        self.second_pass_hints = "\n".join(hints) if hints else None

        self.updated_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        return self

    @field_validator("speaker_id")
    @classmethod
    def sanitize_speaker_id(cls, v: str) -> str:
        s = v.strip().lower()
        # Only allow alphanumeric, hyphen, underscore
        sanitized = re.sub(r"[^a-z0-9_-]", "_", s)
        sanitized = re.sub(r"_+", "_", sanitized).strip("_")
        if not sanitized:
            sanitized = "speaker_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        return sanitized

    def to_replace_text(self) -> str:
        """Convert replacements to hayamimi standard --replace compatible text.
        Format:
        # Speaker Profile: <display_name> (<speaker_id>)
        pattern\treplacement
        """
        lines = [
            f"# Speaker Profile: {self.display_name} ({self.speaker_id})",
            f"# Generated at: {self.created_at}",
            "",
        ]
        for rule in self.replacements:
            if rule.pattern and rule.replacement:
                # Tab-separated
                lines.append(f"{rule.pattern}\t{rule.replacement}")
        return "\n".join(lines) + "\n"

    def filter_safe_replacements(self, min_len: int = 2) -> List[ReplacementRule]:
        """Filter out potentially dangerous short replacements (e.g. 1 char words like 'と' -> 'そ')."""
        safe_rules = []
        for r in self.replacements:
            p = r.pattern.strip()
            # If pattern is too short or is a common punctuation/particle, skip
            if len(p) < min_len:
                continue
            safe_rules.append(r)
        return safe_rules
