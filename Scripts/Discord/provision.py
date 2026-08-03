#!/usr/bin/env python3
"""Provision the managed portion of the CloudNow Discord server.

The manifest is declarative and contains no secrets. Managed resources are matched
by stable state IDs or names. Authoritative access/onboarding removes unlisted
entries, while deletion of whole obsolete objects requires exact manifest IDs and
the explicit ``--cleanup-obsolete`` safeguard.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import datetime as dt
import fcntl
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


API_BASE = "https://discord.com/api/v10"
USER_AGENT = "DiscordBot (https://github.com/owenselles/CloudNow, 1.0)"
MAX_RATE_LIMIT_RETRIES = 5
DISCORD_EPOCH_MS = 1_420_070_400_000
PROVISIONER_ROLE_KEY = "cloudnow-provisioner"
PROVISIONER_ROLE_NAME = "CloudNow Provisioner"
PROVISIONER_ROLE_COLOR = 0x5865F2
CHANNEL_FLAG_REQUIRE_TAG = 1 << 4

CHANNEL_TYPES = {
    "text": 0,
    "voice": 2,
    "category": 4,
    "announcement": 5,
    "forum": 15,
}

AUTOMOD_TRIGGER_TYPES = {
    "keyword": 1,
    "spam": 3,
    "keyword_preset": 4,
    "mention_spam": 5,
}

AUTOMOD_ACTION_TYPES = {
    "block_message": 1,
    "send_alert": 2,
    "timeout": 3,
}

# https://discord.com/developers/docs/topics/permissions#permissions-bitwise-permission-flags
PERMISSIONS = {
    "CREATE_INSTANT_INVITE": 1 << 0,
    "KICK_MEMBERS": 1 << 1,
    "BAN_MEMBERS": 1 << 2,
    "ADMINISTRATOR": 1 << 3,
    "MANAGE_CHANNELS": 1 << 4,
    "MANAGE_GUILD": 1 << 5,
    "ADD_REACTIONS": 1 << 6,
    "VIEW_AUDIT_LOG": 1 << 7,
    "PRIORITY_SPEAKER": 1 << 8,
    "STREAM": 1 << 9,
    "VIEW_CHANNEL": 1 << 10,
    "SEND_MESSAGES": 1 << 11,
    "SEND_TTS_MESSAGES": 1 << 12,
    "MANAGE_MESSAGES": 1 << 13,
    "EMBED_LINKS": 1 << 14,
    "ATTACH_FILES": 1 << 15,
    "READ_MESSAGE_HISTORY": 1 << 16,
    "MENTION_EVERYONE": 1 << 17,
    "USE_EXTERNAL_EMOJIS": 1 << 18,
    "VIEW_GUILD_INSIGHTS": 1 << 19,
    "CONNECT": 1 << 20,
    "SPEAK": 1 << 21,
    "MUTE_MEMBERS": 1 << 22,
    "DEAFEN_MEMBERS": 1 << 23,
    "MOVE_MEMBERS": 1 << 24,
    "USE_VAD": 1 << 25,
    "CHANGE_NICKNAME": 1 << 26,
    "MANAGE_NICKNAMES": 1 << 27,
    "MANAGE_ROLES": 1 << 28,
    "MANAGE_WEBHOOKS": 1 << 29,
    "MANAGE_GUILD_EXPRESSIONS": 1 << 30,
    "USE_APPLICATION_COMMANDS": 1 << 31,
    "REQUEST_TO_SPEAK": 1 << 32,
    "MANAGE_EVENTS": 1 << 33,
    "MANAGE_THREADS": 1 << 34,
    "CREATE_PUBLIC_THREADS": 1 << 35,
    "CREATE_PRIVATE_THREADS": 1 << 36,
    "USE_EXTERNAL_STICKERS": 1 << 37,
    "SEND_MESSAGES_IN_THREADS": 1 << 38,
    "USE_EMBEDDED_ACTIVITIES": 1 << 39,
    "MODERATE_MEMBERS": 1 << 40,
    "VIEW_CREATOR_MONETIZATION_ANALYTICS": 1 << 41,
    "USE_SOUNDBOARD": 1 << 42,
    "CREATE_GUILD_EXPRESSIONS": 1 << 43,
    "CREATE_EVENTS": 1 << 44,
    "USE_EXTERNAL_SOUNDS": 1 << 45,
    "SEND_VOICE_MESSAGES": 1 << 46,
    "SET_VOICE_CHANNEL_STATUS": 1 << 48,
    "SEND_POLLS": 1 << 49,
    "USE_EXTERNAL_APPS": 1 << 50,
    "PIN_MESSAGES": 1 << 51,
    "BYPASS_SLOWMODE": 1 << 52,
}

BOT_CHANNEL_PERMISSION_NAMES = [
    "VIEW_CHANNEL",
    "SEND_MESSAGES",
    "EMBED_LINKS",
    "ATTACH_FILES",
    "READ_MESSAGE_HISTORY",
    "MANAGE_MESSAGES",
    "MANAGE_THREADS",
    "CREATE_PUBLIC_THREADS",
    "SEND_MESSAGES_IN_THREADS",
    "PIN_MESSAGES",
]
BOT_CHANNEL_PERMISSIONS = sum(
    PERMISSIONS[name] for name in BOT_CHANNEL_PERMISSION_NAMES
)

KEY_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
TEXT_CHANNEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


class ManifestError(ValueError):
    """The local manifest is invalid or internally inconsistent."""


class DiscordAPIError(RuntimeError):
    """A Discord REST operation failed."""

    def __init__(
        self,
        message: str,
        *,
        status: int | None = None,
        code: int | str | None = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


def _expect_dict(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ManifestError(f"{path} must be an object")
    return value


def _expect_list(value: Any, path: str) -> list[Any]:
    if not isinstance(value, list):
        raise ManifestError(f"{path} must be an array")
    return value


def _expect_string(
    value: Any,
    path: str,
    *,
    minimum: int = 1,
    maximum: int | None = None,
) -> str:
    if not isinstance(value, str):
        raise ManifestError(f"{path} must be a string")
    if len(value) < minimum:
        raise ManifestError(f"{path} must contain at least {minimum} character(s)")
    if maximum is not None and len(value) > maximum:
        raise ManifestError(f"{path} must contain at most {maximum} characters")
    return value


def _expect_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        raise ManifestError(f"{path} must be true or false")
    return value


def _expect_int(
    value: Any,
    path: str,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ManifestError(f"{path} must be an integer")
    if minimum is not None and value < minimum:
        raise ManifestError(f"{path} must be at least {minimum}")
    if maximum is not None and value > maximum:
        raise ManifestError(f"{path} must be at most {maximum}")
    return value


def _reject_unknown(
    value: Mapping[str, Any],
    allowed: Iterable[str],
    path: str,
) -> None:
    unknown = sorted(set(value) - set(allowed))
    if unknown:
        raise ManifestError(f"{path} contains unknown field(s): {', '.join(unknown)}")


def _require_fields(
    value: Mapping[str, Any],
    required: Iterable[str],
    path: str,
) -> None:
    missing = sorted(set(required) - set(value))
    if missing:
        raise ManifestError(f"{path} is missing field(s): {', '.join(missing)}")


def _validate_key(value: Any, path: str) -> str:
    key = _expect_string(value, path, maximum=64)
    if not KEY_PATTERN.fullmatch(key):
        raise ManifestError(
            f"{path} must use lowercase letters, digits, and single hyphens"
        )
    return key


def _validate_unique(values: Sequence[str], path: str) -> None:
    duplicates = sorted({value for value in values if values.count(value) > 1})
    if duplicates:
        raise ManifestError(f"{path} contains duplicates: {', '.join(duplicates)}")


def _validate_snowflake(value: Any, path: str) -> str:
    snowflake = _expect_string(value, path, maximum=20)
    if not re.fullmatch(r"\d{17,20}", snowflake):
        raise ManifestError(f"{path} must be a Discord snowflake")
    return snowflake


def permission_bits(names: Sequence[str], path: str = "permissions") -> int:
    """Convert readable Discord permission names to their integer bitset."""
    if not isinstance(names, list):
        raise ManifestError(f"{path} must be an array")
    _validate_unique(names, path)
    result = 0
    for index, name in enumerate(names):
        if not isinstance(name, str) or name not in PERMISSIONS:
            rendered = name if isinstance(name, str) else repr(name)
            raise ManifestError(f"{path}[{index}] has unknown permission {rendered}")
        result |= PERMISSIONS[name]
    return result


def permission_names(bits: int) -> list[str]:
    """Return known permission names present in a bit field."""
    return [name for name, value in PERMISSIONS.items() if bits & value]


def required_bot_permissions(manifest: Mapping[str, Any]) -> int:
    """Return the least-privilege union needed by both local Discord scripts."""
    bits = permission_bits(manifest["everyone_permissions"])
    for role in manifest["roles"]:
        bits |= permission_bits(role["permissions"])
    for resource in [*manifest["categories"], *manifest["channels"]]:
        for overwrite in resource["overwrites"]:
            bits |= permission_bits(overwrite["allow"])
            bits |= permission_bits(overwrite["deny"])
    return bits | BOT_CHANNEL_PERMISSIONS


def _validate_overwrites(
    overwrites: Any,
    path: str,
    role_keys: set[str],
) -> None:
    entries = _expect_list(overwrites, path)
    targets: list[str] = []
    for index, raw in enumerate(entries):
        item_path = f"{path}[{index}]"
        item = _expect_dict(raw, item_path)
        _reject_unknown(item, {"target", "allow", "deny"}, item_path)
        _require_fields(item, {"target", "allow", "deny"}, item_path)
        target = _expect_string(item["target"], f"{item_path}.target", maximum=64)
        if target != "@everyone" and target not in role_keys:
            raise ManifestError(f"{item_path}.target references unknown role {target}")
        allow = permission_bits(item["allow"], f"{item_path}.allow")
        deny = permission_bits(item["deny"], f"{item_path}.deny")
        if allow & deny:
            raise ManifestError(f"{item_path} allows and denies the same permission")
        targets.append(target)
    _validate_unique(targets, f"{path} targets")


def _validate_assignment_refs(
    value: Mapping[str, Any],
    path: str,
    channel_keys: set[str],
    role_keys: set[str],
) -> None:
    channels = _expect_list(value.get("channels", []), f"{path}.channels")
    roles = _expect_list(value.get("roles", []), f"{path}.roles")
    for index, channel in enumerate(channels):
        ref = _validate_key(channel, f"{path}.channels[{index}]")
        if ref not in channel_keys:
            raise ManifestError(f"{path}.channels references unknown channel {ref}")
    for index, role in enumerate(roles):
        ref = _validate_key(role, f"{path}.roles[{index}]")
        if ref not in role_keys:
            raise ManifestError(f"{path}.roles references unknown role {ref}")
    _validate_unique(channels, f"{path}.channels")
    _validate_unique(roles, f"{path}.roles")


def _everyone_channel_permissions(
    manifest: Mapping[str, Any],
    channel: Mapping[str, Any],
) -> int:
    permissions = permission_bits(manifest["everyone_permissions"])
    categories = {item["key"]: item for item in manifest["categories"]}

    def apply_overwrites(
        current: int,
        overwrites: Sequence[Mapping[str, Any]],
    ) -> int:
        for overwrite in overwrites:
            if overwrite["target"] == "@everyone":
                current &= ~permission_bits(overwrite["deny"])
                current |= permission_bits(overwrite["allow"])
        return current

    effective_overwrites = merge_manifest_overwrites(
        categories[channel["category"]].get("overwrites", []),
        channel.get("overwrites", []),
    )
    return apply_overwrites(permissions, effective_overwrites)


def validate_manifest(manifest: Any) -> dict[str, Any]:
    """Validate the full manifest, including cross-resource references."""
    root = _expect_dict(manifest, "manifest")
    _reject_unknown(
        root,
        {
            "manifest_version",
            "authoritative",
            "guild",
            "everyone_permissions",
            "roles",
            "categories",
            "channels",
            "onboarding",
            "automod_rules",
            "cleanup",
        },
        "manifest",
    )
    _require_fields(
        root,
        {
            "manifest_version",
            "guild",
            "everyone_permissions",
            "roles",
            "categories",
            "channels",
            "onboarding",
            "automod_rules",
        },
        "manifest",
    )
    if root["manifest_version"] not in {1, 2}:
        raise ManifestError("manifest.manifest_version must be 1 or 2")
    manifest_version = int(root["manifest_version"])
    if manifest_version == 1 and (
        "authoritative" in root or "cleanup" in root
    ):
        raise ManifestError(
            "manifest_version 2 is required for authoritative or cleanup"
        )
    _expect_bool(root.get("authoritative", False), "manifest.authoritative")

    guild = _expect_dict(root["guild"], "manifest.guild")
    _reject_unknown(
        guild,
        {
            "name",
            "description",
            "preferred_locale",
            "verification_level",
            "default_message_notifications",
            "explicit_content_filter",
            "system_channel_flags",
            "rules_channel",
            "public_updates_channel",
            "safety_alerts_channel",
            "system_channel",
        },
        "manifest.guild",
    )
    _require_fields(
        guild,
        {
            "name",
            "description",
            "preferred_locale",
            "verification_level",
            "default_message_notifications",
            "explicit_content_filter",
            "system_channel_flags",
            "rules_channel",
            "public_updates_channel",
            "safety_alerts_channel",
            "system_channel",
        },
        "manifest.guild",
    )
    _expect_string(guild["name"], "manifest.guild.name", maximum=100)
    _expect_string(
        guild["description"],
        "manifest.guild.description",
        maximum=120,
    )
    _expect_string(
        guild["preferred_locale"],
        "manifest.guild.preferred_locale",
        maximum=20,
    )
    _expect_int(
        guild["verification_level"],
        "manifest.guild.verification_level",
        minimum=2,
        maximum=4,
    )
    _expect_int(
        guild["default_message_notifications"],
        "manifest.guild.default_message_notifications",
        minimum=0,
        maximum=1,
    )
    _expect_int(
        guild["explicit_content_filter"],
        "manifest.guild.explicit_content_filter",
        minimum=2,
        maximum=2,
    )
    _expect_int(
        guild["system_channel_flags"],
        "manifest.guild.system_channel_flags",
        minimum=0,
    )

    everyone_bits = permission_bits(
        root["everyone_permissions"],
        "manifest.everyone_permissions",
    )
    if everyone_bits & PERMISSIONS["ADMINISTRATOR"]:
        raise ManifestError(
            "manifest.everyone_permissions may not grant ADMINISTRATOR"
        )

    roles = _expect_list(root["roles"], "manifest.roles")
    role_keys: list[str] = []
    role_names: list[str] = []
    for index, raw in enumerate(roles):
        path = f"manifest.roles[{index}]"
        role = _expect_dict(raw, path)
        _reject_unknown(
            role,
            {"key", "name", "permissions", "color", "hoist", "mentionable"},
            path,
        )
        _require_fields(
            role,
            {"key", "name", "permissions", "color", "hoist", "mentionable"},
            path,
        )
        role_keys.append(_validate_key(role["key"], f"{path}.key"))
        name = _expect_string(role["name"], f"{path}.name", maximum=100)
        if name == "@everyone":
            raise ManifestError(f"{path}.name may not be @everyone")
        role_names.append(name)
        role_permissions = permission_bits(
            role["permissions"],
            f"{path}.permissions",
        )
        if role_permissions & PERMISSIONS["ADMINISTRATOR"]:
            raise ManifestError(
                f"{path}.permissions may not grant ADMINISTRATOR"
            )
        _expect_int(role["color"], f"{path}.color", minimum=0, maximum=0xFFFFFF)
        _expect_bool(role["hoist"], f"{path}.hoist")
        _expect_bool(role["mentionable"], f"{path}.mentionable")
    _validate_unique(role_keys, "manifest role keys")
    _validate_unique(role_names, "manifest role names")
    if PROVISIONER_ROLE_KEY in role_keys:
        raise ManifestError(
            f"manifest role key {PROVISIONER_ROLE_KEY!r} is reserved"
        )
    if PROVISIONER_ROLE_NAME in role_names:
        raise ManifestError(
            f"manifest role name {PROVISIONER_ROLE_NAME!r} is reserved"
        )
    role_key_set = set(role_keys)
    role_by_key = {item["key"]: item for item in roles}

    categories = _expect_list(root["categories"], "manifest.categories")
    category_keys: list[str] = []
    category_names: list[str] = []
    for index, raw in enumerate(categories):
        path = f"manifest.categories[{index}]"
        category = _expect_dict(raw, path)
        _reject_unknown(category, {"key", "name", "overwrites"}, path)
        _require_fields(category, {"key", "name", "overwrites"}, path)
        category_keys.append(_validate_key(category["key"], f"{path}.key"))
        category_names.append(
            _expect_string(category["name"], f"{path}.name", maximum=100)
        )
        _validate_overwrites(
            category["overwrites"],
            f"{path}.overwrites",
            role_key_set,
        )
    _validate_unique(category_keys, "manifest category keys")
    _validate_unique(category_names, "manifest category names")
    category_key_set = set(category_keys)

    channels = _expect_list(root["channels"], "manifest.channels")
    channel_keys: list[str] = []
    channel_names: list[str] = []
    for index, raw in enumerate(channels):
        path = f"manifest.channels[{index}]"
        channel = _expect_dict(raw, path)
        _reject_unknown(
            channel,
            {
                "key",
                "name",
                "type",
                "category",
                "topic",
                "nsfw",
                "slowmode_seconds",
                "default_auto_archive_minutes",
                "default_thread_slowmode_seconds",
                "require_tag",
                "user_limit",
                "overwrites",
                "forum_tags",
            },
            path,
        )
        _require_fields(
            channel,
            {
                "key",
                "name",
                "type",
                "category",
                "topic",
                "nsfw",
                "slowmode_seconds",
                "overwrites",
            },
            path,
        )
        channel_keys.append(_validate_key(channel["key"], f"{path}.key"))
        name = _expect_string(channel["name"], f"{path}.name", maximum=100)
        channel_names.append(name)
        channel_type = _expect_string(channel["type"], f"{path}.type")
        if channel_type not in {"text", "announcement", "forum", "voice"}:
            raise ManifestError(f"{path}.type is unsupported: {channel_type}")
        if channel_type in {"text", "announcement", "forum"}:
            if not TEXT_CHANNEL_PATTERN.fullmatch(name):
                raise ManifestError(
                    f"{path}.name must be a Discord text-channel name"
                )
        category = _validate_key(channel["category"], f"{path}.category")
        if category not in category_key_set:
            raise ManifestError(f"{path}.category references unknown category")
        _expect_string(channel["topic"], f"{path}.topic", minimum=0, maximum=1024)
        _expect_bool(channel["nsfw"], f"{path}.nsfw")
        _expect_int(
            channel["slowmode_seconds"],
            f"{path}.slowmode_seconds",
            minimum=0,
            maximum=21600,
        )
        if "default_auto_archive_minutes" in channel:
            auto_archive = _expect_int(
                channel["default_auto_archive_minutes"],
                f"{path}.default_auto_archive_minutes",
            )
            if auto_archive not in {60, 1440, 4320, 10080}:
                raise ManifestError(
                    f"{path}.default_auto_archive_minutes is unsupported"
                )
        if "default_thread_slowmode_seconds" in channel:
            if manifest_version < 2:
                raise ManifestError(
                    f"{path}.default_thread_slowmode_seconds requires "
                    "manifest_version 2"
                )
            if channel_type not in {"text", "forum"}:
                raise ManifestError(
                    f"{path}.default_thread_slowmode_seconds is only valid "
                    "for text and forum channels"
                )
            _expect_int(
                channel["default_thread_slowmode_seconds"],
                f"{path}.default_thread_slowmode_seconds",
                minimum=0,
                maximum=21600,
            )
        if "require_tag" in channel:
            if manifest_version < 2:
                raise ManifestError(
                    f"{path}.require_tag requires manifest_version 2"
                )
            if channel_type != "forum":
                raise ManifestError(
                    f"{path}.require_tag is only valid for forums"
                )
            _expect_bool(channel["require_tag"], f"{path}.require_tag")
        if "user_limit" in channel:
            if manifest_version < 2:
                raise ManifestError(
                    f"{path}.user_limit requires manifest_version 2"
                )
            if channel_type != "voice":
                raise ManifestError(
                    f"{path}.user_limit is only valid for voice channels"
                )
            _expect_int(
                channel["user_limit"],
                f"{path}.user_limit",
                minimum=0,
                maximum=99,
            )
        _validate_overwrites(
            channel["overwrites"],
            f"{path}.overwrites",
            role_key_set,
        )
        tags = channel.get("forum_tags", [])
        if channel_type != "forum" and tags:
            raise ManifestError(f"{path}.forum_tags is only valid for forums")
        if channel_type == "forum":
            tag_items = _expect_list(tags, f"{path}.forum_tags")
            if len(tag_items) > 20:
                raise ManifestError(f"{path}.forum_tags may contain at most 20 tags")
            tag_names: list[str] = []
            for tag_index, raw_tag in enumerate(tag_items):
                tag_path = f"{path}.forum_tags[{tag_index}]"
                tag = _expect_dict(raw_tag, tag_path)
                _reject_unknown(tag, {"name", "moderated", "emoji"}, tag_path)
                _require_fields(tag, {"name", "moderated"}, tag_path)
                tag_names.append(
                    _expect_string(tag["name"], f"{tag_path}.name", maximum=20)
                )
                _expect_bool(tag["moderated"], f"{tag_path}.moderated")
                if "emoji" in tag:
                    _expect_string(
                        tag["emoji"],
                        f"{tag_path}.emoji",
                        maximum=32,
                    )
            _validate_unique(tag_names, f"{path}.forum_tags names")
    _validate_unique(channel_keys, "manifest channel keys")
    # Global uniqueness keeps guild settings and onboarding references unambiguous.
    _validate_unique(channel_names, "manifest channel names")
    channel_key_set = set(channel_keys)
    channel_by_key = {item["key"]: item for item in channels}

    for key in (
        "rules_channel",
        "public_updates_channel",
        "safety_alerts_channel",
        "system_channel",
    ):
        raw_ref = guild[key]
        if key == "system_channel" and raw_ref is None:
            continue
        ref = _validate_key(raw_ref, f"manifest.guild.{key}")
        if ref not in channel_key_set:
            raise ManifestError(f"manifest.guild.{key} references unknown channel")
        if channel_by_key[ref]["type"] != "text":
            raise ManifestError(
                f"manifest.guild.{key} must reference a text channel"
            )

    onboarding = _expect_dict(root["onboarding"], "manifest.onboarding")
    _reject_unknown(
        onboarding,
        {
            "enabled",
            "mode",
            "default_channels",
            "writable_default_channels",
            "prompts",
        },
        "manifest.onboarding",
    )
    _require_fields(
        onboarding,
        {
            "enabled",
            "mode",
            "default_channels",
            "writable_default_channels",
            "prompts",
        },
        "manifest.onboarding",
    )
    _expect_bool(onboarding["enabled"], "manifest.onboarding.enabled")
    mode = _expect_string(onboarding["mode"], "manifest.onboarding.mode")
    if mode not in {"default", "advanced"}:
        raise ManifestError("manifest.onboarding.mode must be default or advanced")
    default_channels = _expect_list(
        onboarding["default_channels"],
        "manifest.onboarding.default_channels",
    )
    writable_defaults = _expect_list(
        onboarding["writable_default_channels"],
        "manifest.onboarding.writable_default_channels",
    )
    if len(default_channels) < 7:
        raise ManifestError(
            "manifest.onboarding.default_channels must contain at least 7 channels"
        )
    if len(writable_defaults) < 5:
        raise ManifestError(
            "manifest.onboarding.writable_default_channels must contain at "
            "least 5 channels"
        )
    for index, ref in enumerate(default_channels):
        key = _validate_key(
            ref,
            f"manifest.onboarding.default_channels[{index}]",
        )
        if key not in channel_key_set:
            raise ManifestError(
                f"manifest.onboarding.default_channels references unknown channel {key}"
            )
    for index, ref in enumerate(writable_defaults):
        key = _validate_key(
            ref,
            f"manifest.onboarding.writable_default_channels[{index}]",
        )
        if key not in default_channels:
            raise ManifestError(
                "manifest.onboarding.writable_default_channels must be a subset "
                "of default_channels"
            )
    _validate_unique(default_channels, "manifest.onboarding.default_channels")
    _validate_unique(
        writable_defaults,
        "manifest.onboarding.writable_default_channels",
    )
    send_messages = PERMISSIONS["SEND_MESSAGES"]
    expected_writable = set(writable_defaults)
    for ref in default_channels:
        is_writable = bool(
            _everyone_channel_permissions(root, channel_by_key[ref]) & send_messages
        )
        if is_writable != (ref in expected_writable):
            state = "writable" if is_writable else "read-only"
            raise ManifestError(
                f"onboarding default {ref} is effectively {state}, contrary to "
                "writable_default_channels"
            )

    prompts = _expect_list(onboarding["prompts"], "manifest.onboarding.prompts")
    if len(prompts) > 5:
        raise ManifestError("manifest.onboarding.prompts may contain at most 5 prompts")
    prompt_titles: list[str] = []
    for prompt_index, raw_prompt in enumerate(prompts):
        path = f"manifest.onboarding.prompts[{prompt_index}]"
        prompt = _expect_dict(raw_prompt, path)
        _reject_unknown(
            prompt,
            {
                "title",
                "type",
                "single_select",
                "required",
                "in_onboarding",
                "options",
            },
            path,
        )
        _require_fields(
            prompt,
            {
                "title",
                "type",
                "single_select",
                "required",
                "in_onboarding",
                "options",
            },
            path,
        )
        prompt_titles.append(
            _expect_string(prompt["title"], f"{path}.title", maximum=100)
        )
        if prompt["type"] != "multiple_choice":
            raise ManifestError(f"{path}.type must be multiple_choice")
        _expect_bool(prompt["single_select"], f"{path}.single_select")
        _expect_bool(prompt["required"], f"{path}.required")
        _expect_bool(prompt["in_onboarding"], f"{path}.in_onboarding")
        options = _expect_list(prompt["options"], f"{path}.options")
        if not options or len(options) > 26:
            raise ManifestError(f"{path}.options must contain 1 through 26 options")
        option_titles: list[str] = []
        for option_index, raw_option in enumerate(options):
            option_path = f"{path}.options[{option_index}]"
            option = _expect_dict(raw_option, option_path)
            _reject_unknown(
                option,
                {"title", "description", "channels", "roles", "emoji"},
                option_path,
            )
            _require_fields(
                option,
                {"title", "description", "channels", "roles"},
                option_path,
            )
            option_titles.append(
                _expect_string(
                    option["title"],
                    f"{option_path}.title",
                    maximum=100,
                )
            )
            _expect_string(
                option["description"],
                f"{option_path}.description",
                minimum=0,
                maximum=100,
            )
            if "emoji" in option:
                _expect_string(
                    option["emoji"],
                    f"{option_path}.emoji",
                    maximum=32,
                )
            _validate_assignment_refs(
                option,
                option_path,
                channel_key_set,
                role_key_set,
            )
            privileged_assignments = [
                role_key
                for role_key in option["roles"]
                if permission_bits(
                    role_by_key[role_key]["permissions"],
                    f"manifest role {role_key!r} permissions",
                )
            ]
            if privileged_assignments:
                raise ManifestError(
                    f"{option_path} makes guild-permission role(s) "
                    "self-assignable: "
                    + ", ".join(privileged_assignments)
                )
            if not option["channels"] and not option["roles"]:
                raise ManifestError(
                    f"{option_path} must assign at least one channel or role"
                )
        _validate_unique(option_titles, f"{path} option titles")
    _validate_unique(prompt_titles, "manifest onboarding prompt titles")

    rules = _expect_list(root["automod_rules"], "manifest.automod_rules")
    rule_keys: list[str] = []
    rule_names: list[str] = []
    trigger_counts: dict[str, int] = {}
    for rule_index, raw_rule in enumerate(rules):
        path = f"manifest.automod_rules[{rule_index}]"
        rule = _expect_dict(raw_rule, path)
        _reject_unknown(
            rule,
            {
                "key",
                "name",
                "enabled",
                "trigger",
                "actions",
                "exempt_roles",
                "exempt_channels",
                "alert_only",
            },
            path,
        )
        _require_fields(
            rule,
            {
                "key",
                "name",
                "enabled",
                "trigger",
                "actions",
                "exempt_roles",
                "exempt_channels",
            },
            path,
        )
        rule_keys.append(_validate_key(rule["key"], f"{path}.key"))
        rule_names.append(_expect_string(rule["name"], f"{path}.name", maximum=100))
        _expect_bool(rule["enabled"], f"{path}.enabled")
        trigger = _expect_dict(rule["trigger"], f"{path}.trigger")
        _reject_unknown(
            trigger,
            {
                "type",
                "keywords",
                "regex_patterns",
                "allow_list",
                "presets",
                "mention_limit",
                "mention_raid_protection",
            },
            f"{path}.trigger",
        )
        _require_fields(trigger, {"type"}, f"{path}.trigger")
        trigger_type = _expect_string(trigger["type"], f"{path}.trigger.type")
        if trigger_type not in AUTOMOD_TRIGGER_TYPES:
            raise ManifestError(f"{path}.trigger.type is unsupported")
        trigger_fields = {
            "keyword": {"type", "keywords", "regex_patterns", "allow_list"},
            "keyword_preset": {"type", "presets", "allow_list"},
            "spam": {"type"},
            "mention_spam": {
                "type",
                "mention_limit",
                "mention_raid_protection",
            },
        }
        _reject_unknown(
            trigger,
            trigger_fields[trigger_type],
            f"{path}.trigger for type {trigger_type}",
        )
        trigger_counts[trigger_type] = trigger_counts.get(trigger_type, 0) + 1
        if trigger_type == "keyword":
            keywords = _expect_list(
                trigger.get("keywords", []),
                f"{path}.trigger.keywords",
            )
            regex_patterns = _expect_list(
                trigger.get("regex_patterns", []),
                f"{path}.trigger.regex_patterns",
            )
            if not keywords and not regex_patterns:
                raise ManifestError(
                    f"{path}.trigger needs keywords or regex_patterns"
                )
            if len(keywords) > 1000 or len(regex_patterns) > 10:
                raise ManifestError(f"{path}.trigger exceeds Discord limits")
            for index, keyword in enumerate(keywords):
                _expect_string(
                    keyword,
                    f"{path}.trigger.keywords[{index}]",
                    maximum=60,
                )
            for index, pattern in enumerate(regex_patterns):
                _expect_string(
                    pattern,
                    f"{path}.trigger.regex_patterns[{index}]",
                    maximum=260,
                )
        elif trigger_type == "keyword_preset":
            presets = _expect_list(
                trigger.get("presets", []),
                f"{path}.trigger.presets",
            )
            if not presets:
                raise ManifestError(f"{path}.trigger.presets may not be empty")
            for index, preset in enumerate(presets):
                if preset not in {"profanity", "sexual_content", "slurs"}:
                    raise ManifestError(
                        f"{path}.trigger.presets[{index}] is unsupported"
                    )
            _validate_unique(presets, f"{path}.trigger.presets")
        elif trigger_type == "mention_spam":
            _expect_int(
                trigger.get("mention_limit"),
                f"{path}.trigger.mention_limit",
                minimum=1,
                maximum=50,
            )
            _expect_bool(
                trigger.get("mention_raid_protection"),
                f"{path}.trigger.mention_raid_protection",
            )
        allow_list = _expect_list(
            trigger.get("allow_list", []),
            f"{path}.trigger.allow_list",
        )
        allow_list_limit = 1000 if trigger_type == "keyword_preset" else 100
        if len(allow_list) > allow_list_limit:
            raise ManifestError(f"{path}.trigger.allow_list exceeds Discord limits")
        for index, item in enumerate(allow_list):
            _expect_string(
                item,
                f"{path}.trigger.allow_list[{index}]",
                maximum=60,
            )

        actions = _expect_list(rule["actions"], f"{path}.actions")
        if not actions:
            raise ManifestError(f"{path}.actions may not be empty")
        action_types: list[str] = []
        for action_index, raw_action in enumerate(actions):
            action_path = f"{path}.actions[{action_index}]"
            action = _expect_dict(raw_action, action_path)
            _reject_unknown(
                action,
                {"type", "channel", "custom_message", "duration_seconds"},
                action_path,
            )
            _require_fields(action, {"type"}, action_path)
            action_type = _expect_string(action["type"], f"{action_path}.type")
            if action_type not in AUTOMOD_ACTION_TYPES:
                raise ManifestError(f"{action_path}.type is unsupported")
            action_fields = {
                "block_message": {"type", "custom_message"},
                "send_alert": {"type", "channel"},
                "timeout": {"type", "duration_seconds"},
            }
            _reject_unknown(
                action,
                action_fields[action_type],
                f"{action_path} for type {action_type}",
            )
            action_types.append(action_type)
            if action_type == "send_alert":
                channel_ref = _validate_key(
                    action.get("channel"),
                    f"{action_path}.channel",
                )
                if channel_ref not in channel_key_set:
                    raise ManifestError(
                        f"{action_path}.channel references unknown channel"
                    )
            elif action_type == "block_message" and "custom_message" in action:
                _expect_string(
                    action["custom_message"],
                    f"{action_path}.custom_message",
                    maximum=150,
                )
            elif action_type == "timeout":
                _expect_int(
                    action.get("duration_seconds"),
                    f"{action_path}.duration_seconds",
                    minimum=1,
                    maximum=2419200,
                )
        _validate_unique(action_types, f"{path} action types")
        if "timeout" in action_types and trigger_type not in {
            "keyword",
            "mention_spam",
        }:
            raise ManifestError(
                f"{path} may only use a timeout action with keyword or "
                "mention_spam triggers"
            )
        alert_only = rule.get("alert_only", False)
        _expect_bool(alert_only, f"{path}.alert_only")
        if alert_only and set(action_types) != {"send_alert"}:
            raise ManifestError(
                f"{path} is alert_only and may only use send_alert actions"
            )

        _validate_assignment_refs(
            {
                "channels": rule["exempt_channels"],
                "roles": rule["exempt_roles"],
            },
            path,
            channel_key_set,
            role_key_set,
        )
        if len(rule["exempt_roles"]) > 20:
            raise ManifestError(f"{path}.exempt_roles may contain at most 20 roles")
        if len(rule["exempt_channels"]) > 50:
            raise ManifestError(
                f"{path}.exempt_channels may contain at most 50 channels"
            )
    _validate_unique(rule_keys, "manifest AutoMod rule keys")
    _validate_unique(rule_names, "manifest AutoMod rule names")
    if trigger_counts.get("keyword", 0) > 6:
        raise ManifestError("manifest has more than 6 keyword AutoMod rules")
    for singleton in ("spam", "keyword_preset", "mention_spam"):
        if trigger_counts.get(singleton, 0) > 1:
            raise ManifestError(f"manifest has more than one {singleton} AutoMod rule")

    cleanup = root.get(
        "cleanup",
        {"roles": [], "channels": [], "categories": []},
    )
    cleanup = _expect_dict(cleanup, "manifest.cleanup")
    _reject_unknown(cleanup, {"roles", "channels", "categories"}, "manifest.cleanup")
    _require_fields(cleanup, {"roles", "channels", "categories"}, "manifest.cleanup")
    cleanup_ids: list[str] = []
    cleanup_names: dict[str, list[str]] = {
        "roles": [],
        "channels": [],
        "categories": [],
    }
    cleanup_roles = _expect_list(cleanup["roles"], "manifest.cleanup.roles")
    for index, raw_cleanup_role in enumerate(cleanup_roles):
        path = f"manifest.cleanup.roles[{index}]"
        cleanup_role = _expect_dict(raw_cleanup_role, path)
        _reject_unknown(cleanup_role, {"id", "name", "migrate_to"}, path)
        _require_fields(cleanup_role, {"id", "name"}, path)
        cleanup_ids.append(_validate_snowflake(cleanup_role["id"], f"{path}.id"))
        cleanup_names["roles"].append(
            _expect_string(cleanup_role["name"], f"{path}.name", maximum=100)
        )
        if (
            "migrate_to" in cleanup_role
            and cleanup_role["migrate_to"] is not None
        ):
            target = _validate_key(cleanup_role["migrate_to"], f"{path}.migrate_to")
            if target not in role_key_set:
                raise ManifestError(
                    f"{path}.migrate_to references unknown managed role {target!r}"
                )
    cleanup_channels = _expect_list(
        cleanup["channels"],
        "manifest.cleanup.channels",
    )
    for index, raw_cleanup_channel in enumerate(cleanup_channels):
        path = f"manifest.cleanup.channels[{index}]"
        cleanup_channel = _expect_dict(raw_cleanup_channel, path)
        _reject_unknown(cleanup_channel, {"id", "name", "type"}, path)
        _require_fields(cleanup_channel, {"id", "name", "type"}, path)
        cleanup_ids.append(_validate_snowflake(cleanup_channel["id"], f"{path}.id"))
        cleanup_names["channels"].append(
            _expect_string(cleanup_channel["name"], f"{path}.name", maximum=100)
        )
        cleanup_type = _expect_string(cleanup_channel["type"], f"{path}.type")
        if cleanup_type not in {"text", "voice", "announcement", "forum"}:
            raise ManifestError(f"{path}.type is unsupported: {cleanup_type}")
    cleanup_categories = _expect_list(
        cleanup["categories"],
        "manifest.cleanup.categories",
    )
    for index, raw_cleanup_category in enumerate(cleanup_categories):
        path = f"manifest.cleanup.categories[{index}]"
        cleanup_category = _expect_dict(raw_cleanup_category, path)
        _reject_unknown(cleanup_category, {"id", "name"}, path)
        _require_fields(cleanup_category, {"id", "name"}, path)
        cleanup_ids.append(
            _validate_snowflake(cleanup_category["id"], f"{path}.id")
        )
        cleanup_names["categories"].append(
            _expect_string(
                cleanup_category["name"],
                f"{path}.name",
                maximum=100,
            )
        )
    _validate_unique(cleanup_ids, "manifest cleanup IDs")
    for kind, names in cleanup_names.items():
        _validate_unique(names, f"manifest.cleanup.{kind} names")
    managed_names = {
        "roles": set(role_names) | {PROVISIONER_ROLE_NAME, "@everyone"},
        "channels": set(channel_names),
        "categories": set(category_names),
    }
    for kind, names in cleanup_names.items():
        overlap = sorted(set(names) & managed_names[kind])
        if overlap:
            raise ManifestError(
                f"manifest.cleanup.{kind} targets managed name(s): "
                + ", ".join(overlap)
            )

    return root


def _json_object_without_duplicates(
    pairs: Sequence[tuple[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            raw = json.load(
                handle,
                object_pairs_hook=_json_object_without_duplicates,
            )
    except OSError as error:
        raise ManifestError(f"cannot read manifest {path}: {error.strerror}") from error
    except json.JSONDecodeError as error:
        raise ManifestError(
            f"invalid JSON in {path} at line {error.lineno}, column {error.colno}"
        ) from error
    return validate_manifest(raw)


def load_state(path: Path, guild_id: str) -> dict[str, Any]:
    """Load non-secret managed Discord IDs, if a prior apply wrote them."""
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            state = json.load(
                handle,
                object_pairs_hook=_json_object_without_duplicates,
            )
    except OSError as error:
        raise ManifestError(f"cannot read state {path}: {error.strerror}") from error
    except json.JSONDecodeError as error:
        raise ManifestError(
            f"invalid JSON in {path} at line {error.lineno}, column {error.colno}"
        ) from error
    if not isinstance(state, dict) or state.get("state_version") != 1:
        raise ManifestError(f"{path} is not a supported Discord state file")
    state_guild = str(state.get("guild_id", ""))
    if state_guild != guild_id:
        raise ManifestError(
            f"{path} belongs to guild {state_guild or '<missing>'}, not "
            f"DISCORD_GUILD_ID"
        )
    resources = state.get("resources")
    if not isinstance(resources, dict):
        raise ManifestError(f"{path} has malformed resources")
    expected_groups = {"roles", "categories", "channels", "automod_rules"}
    unknown_groups = sorted(set(resources) - expected_groups)
    if unknown_groups:
        raise ManifestError(
            f"{path} has unknown resource group(s): {', '.join(unknown_groups)}"
        )
    for group_name, group in resources.items():
        if not isinstance(group, dict):
            raise ManifestError(f"{path} has malformed {group_name} resources")
        ids: list[str] = []
        for key, item in group.items():
            _validate_key(key, f"{path} {group_name} key")
            if not isinstance(item, dict) or set(item) != {"id", "name"}:
                raise ManifestError(
                    f"{path} has malformed {group_name} resource {key!r}"
                )
            resource_id = str(item["id"])
            if not re.fullmatch(r"\d{17,20}", resource_id):
                raise ManifestError(
                    f"{path} has invalid Discord ID for {group_name} {key!r}"
                )
            _expect_string(
                item["name"],
                f"{path} {group_name} {key}.name",
                maximum=100,
            )
            ids.append(resource_id)
        if len(ids) != len(set(ids)):
            raise ManifestError(f"{path} has duplicate IDs in {group_name}")
    return state


def _fsync_directory(path: Path) -> None:
    directory_fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _write_private_json(path: Path, value: Any) -> None:
    """Atomically write a local state artifact with owner-only permissions."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_path = handle.name
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            os.fchmod(handle.fileno(), 0o600)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
        _fsync_directory(path.parent)
    except OSError as error:
        if temporary_path:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass
        raise DiscordAPIError(
            f"could not write local Discord artifact {path}: {error.strerror}"
        ) from error


def _normalized(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _normalized(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        items = [_normalized(item) for item in value]
        if items and all(isinstance(item, (str, int)) for item in items):
            return sorted(items, key=str)
        if items and all(isinstance(item, dict) for item in items):
            for discriminator in ("id", "name", "title", "type"):
                if all(discriminator in item for item in items):
                    return sorted(
                        items,
                        key=lambda item: str(item[discriminator]),
                    )
        return items
    return value


def _contains_desired(current: Mapping[str, Any], desired: Mapping[str, Any]) -> bool:
    current_subset = {key: current.get(key) for key in desired}
    return _normalized(current_subset) == _normalized(desired)


def merge_permission_overwrites(
    existing: Sequence[Mapping[str, Any]],
    desired: Sequence[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    """Merge managed target IDs while retaining every unmanaged overwrite."""
    result = [dict(item) for item in existing]
    positions: dict[tuple[str, str], int] = {}
    for index, item in enumerate(result):
        identity = (str(item.get("type")), str(item.get("id")))
        if identity in positions:
            raise DiscordAPIError(
                f"Discord returned duplicate permission overwrite for {identity[1]}"
            )
        positions[identity] = index
    for raw in desired:
        item = dict(raw)
        identity = (str(item["type"]), str(item["id"]))
        if identity in positions:
            result[positions[identity]] = item
        else:
            positions[identity] = len(result)
            result.append(item)
    return result


def merge_manifest_overwrites(
    inherited: Sequence[Mapping[str, Any]],
    channel_specific: Sequence[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    """Resolve manifest inheritance, with channel entries replacing parent targets."""
    result = [dict(item) for item in inherited]
    positions = {str(item["target"]): index for index, item in enumerate(result)}
    for raw in channel_specific:
        item = dict(raw)
        target = str(item["target"])
        if target in positions:
            result[positions[target]] = item
        else:
            positions[target] = len(result)
            result.append(item)
    return result


def merge_forum_tags(
    existing: Sequence[Mapping[str, Any]],
    desired: Sequence[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    """Update desired tags by stable name and retain unmanaged tags."""
    result = [dict(item) for item in existing]
    positions: dict[str, int] = {}
    for index, item in enumerate(result):
        name = str(item.get("name", ""))
        if name in positions:
            raise DiscordAPIError(f"forum has duplicate tag name {name!r}")
        positions[name] = index
    for raw in desired:
        item = dict(raw)
        name = str(item["name"])
        if name in positions:
            prior = result[positions[name]]
            if prior.get("id"):
                item["id"] = prior["id"]
            result[positions[name]] = item
        else:
            positions[name] = len(result)
            result.append(item)
    return result


class DiscordClient:
    """Small Discord REST v10 client with explicit rate-limit handling."""

    def __init__(
        self,
        token: str,
        *,
        opener: Callable[..., Any] = urllib.request.urlopen,
        sleeper: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._token = token
        self._opener = opener
        self._sleep = sleeper
        self._clock = clock
        self._blocked_until = 0.0

    def _wait_for_bucket(self) -> None:
        delay = self._blocked_until - self._clock()
        if delay > 0:
            self._sleep(delay)
        self._blocked_until = 0.0

    def request(
        self,
        method: str,
        path: str,
        payload: Any = None,
        *,
        reason: str | None = None,
    ) -> Any:
        encoded = None
        headers = {
            "Authorization": f"Bot {self._token}",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        }
        if payload is not None:
            encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if reason:
            headers["X-Audit-Log-Reason"] = urllib.parse.quote(reason[:512], safe="")

        for attempt in range(MAX_RATE_LIMIT_RETRIES + 1):
            self._wait_for_bucket()
            request = urllib.request.Request(
                f"{API_BASE}{path}",
                data=encoded,
                headers=headers,
                method=method,
            )
            try:
                with self._opener(request, timeout=30) as response:
                    status = getattr(response, "status", response.getcode())
                    body = response.read()
                    response_headers = response.headers
            except urllib.error.HTTPError as error:
                status = error.code
                body = error.read()
                response_headers = error.headers
            except urllib.error.URLError as error:
                reason_text = str(getattr(error, "reason", "network failure"))
                reason_text = reason_text.replace(self._token, "[REDACTED]")
                raise DiscordAPIError(
                    f"Discord API {method} {path} could not connect: {reason_text}"
                ) from error

            parsed: Any = None
            if body:
                try:
                    parsed = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    parsed = None

            if status == 429:
                if attempt == MAX_RATE_LIMIT_RETRIES:
                    raise DiscordAPIError(
                        "Discord rate limit persisted after "
                        f"{MAX_RATE_LIMIT_RETRIES} retries"
                    )
                retry_after = 1.0
                if isinstance(parsed, dict):
                    try:
                        retry_after = max(float(parsed.get("retry_after", 1.0)), 0.0)
                    except (TypeError, ValueError):
                        retry_after = 1.0
                self._sleep(retry_after)
                continue

            if not 200 <= status < 300:
                detail = "request failed"
                api_code: int | str | None = None
                if isinstance(parsed, dict):
                    api_code = parsed.get("code")
                    message = parsed.get("message")
                    detail = (
                        f"{api_code}: {message}"
                        if api_code is not None
                        else str(message)
                    )
                detail = detail.replace(self._token, "[REDACTED]")
                raise DiscordAPIError(
                    f"Discord API {method} {path} failed ({status}): {detail}",
                    status=status,
                    code=api_code,
                )

            if response_headers.get("X-RateLimit-Remaining") == "0":
                try:
                    delay = max(
                        float(response_headers.get("X-RateLimit-Reset-After", "0")),
                        0.0,
                    )
                except ValueError:
                    delay = 0.0
                self._blocked_until = max(
                    self._blocked_until,
                    self._clock() + delay,
                )
            return parsed

        raise AssertionError("unreachable")


class Provisioner:
    """Reconcile managed Discord objects without pruning anything else."""

    def __init__(
        self,
        client: DiscordClient,
        guild_id: str,
        manifest: Mapping[str, Any],
        *,
        apply: bool,
        audit_reason: str,
        state: Mapping[str, Any] | None = None,
        state_path: Path | None = None,
        rollback_dir: Path | None = None,
        bootstrap_from_administrator: bool = False,
        cleanup_obsolete: bool = False,
        output: Callable[[str], None] = print,
    ) -> None:
        self.client = client
        self.guild_id = guild_id
        self.manifest = manifest
        self.apply = apply
        self.audit_reason = audit_reason
        self.state = dict(state or {})
        self.state_path = state_path
        self.rollback_dir = rollback_dir
        self.bootstrap_from_administrator = bootstrap_from_administrator
        self.cleanup_obsolete = cleanup_obsolete
        self.output = output
        self.actions: list[str] = []
        self.roles: dict[str, dict[str, Any]] = {}
        self.categories: dict[str, dict[str, Any]] = {}
        self.channels: dict[str, dict[str, Any]] = {}
        self.automod_rules: dict[str, dict[str, Any]] = {}
        self.bot_user_id: str | None = None
        self.bot_role_ids: set[str] = set()
        self.bot_has_administrator = False
        self.highest_bot_role_position = 0
        self.cleanup_plan: dict[str, list[dict[str, Any]]] = {
            "roles": [],
            "channels": [],
            "categories": [],
        }
        self._temporary_snowflake_base = max(
            (int(time.time() * 1000) - DISCORD_EPOCH_MS) << 22,
            1,
        )
        self._temporary_snowflake_count = 0

    def _record(self, message: str) -> None:
        self.actions.append(message)
        prefix = "APPLY" if self.apply else "PLAN"
        self.output(f"{prefix}: {message}")

    def _reason(self, operation: str) -> str:
        return f"{self.audit_reason}: {operation}"[:512]

    def _new_temporary_snowflake(self) -> str:
        self._temporary_snowflake_count += 1
        return str(
            self._temporary_snowflake_base + self._temporary_snowflake_count
        )

    def _preflight_bot(
        self,
        existing_roles: Sequence[Mapping[str, Any]],
    ) -> None:
        current_user = self.client.request("GET", "/users/@me")
        if (
            not isinstance(current_user, dict)
            or not current_user.get("bot")
            or not current_user.get("id")
        ):
            raise DiscordAPIError("DISCORD_BOT_TOKEN is not a valid bot token")
        self.bot_user_id = str(current_user["id"])
        member = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/members/{self.bot_user_id}",
        )
        if not isinstance(member, dict) or not isinstance(member.get("roles"), list):
            raise DiscordAPIError("Discord returned a malformed bot guild member")

        assigned_ids = {self.guild_id, *(str(value) for value in member["roles"])}
        self.bot_role_ids = assigned_ids
        assigned_roles = [
            role
            for role in existing_roles
            if str(role.get("id")) in assigned_ids
        ]
        try:
            bot_permissions = 0
            for role in assigned_roles:
                bot_permissions |= int(str(role.get("permissions", "0")))
        except ValueError as error:
            raise DiscordAPIError(
                "Discord returned malformed bot role permissions"
            ) from error
        self.bot_has_administrator = bool(
            bot_permissions & PERMISSIONS["ADMINISTRATOR"]
        )
        if self.bot_has_administrator and not self.bootstrap_from_administrator:
            raise DiscordAPIError(
                "the provisioning bot has ADMINISTRATOR; remove it and grant "
                "the documented least-privilege permission set, or explicitly "
                "re-run with --bootstrap-from-administrator"
            )
        missing = required_bot_permissions(self.manifest) & ~bot_permissions
        if missing and not self.bot_has_administrator:
            raise DiscordAPIError(
                "the provisioning bot is missing required permissions: "
                + ", ".join(permission_names(missing))
            )

        try:
            positioned = [
                int(role["position"])
                for role in assigned_roles
                if role.get("position") is not None
            ]
        except (TypeError, ValueError) as error:
            raise DiscordAPIError(
                "Discord returned malformed bot role positions"
            ) from error
        if not positioned:
            raise DiscordAPIError("the provisioning bot has no positioned guild role")
        highest_bot_position = max(positioned)
        self.highest_bot_role_position = highest_bot_position
        if self.bootstrap_from_administrator:
            provisioner = self._find_by_state_or_name(
                existing_roles,
                kind="roles",
                key=PROVISIONER_ROLE_KEY,
                name=PROVISIONER_ROLE_NAME,
                description="role",
            )
            if (
                provisioner is not None
                and str(provisioner.get("id")) not in assigned_ids
                and provisioner.get("position") is not None
                and int(provisioner["position"]) >= highest_bot_position
            ):
                raise DiscordAPIError(
                    f"existing role {PROVISIONER_ROLE_NAME!r} is not below "
                    "the bot's highest role"
                )
        for definition in self.manifest["roles"]:
            found = self._find_by_state_or_name(
                existing_roles,
                kind="roles",
                key=definition["key"],
                name=definition["name"],
                description="role",
            )
            if (
                found is not None
                and found.get("position") is not None
                and int(found["position"]) >= highest_bot_position
            ):
                raise DiscordAPIError(
                    f"move the bot role above managed role {definition['name']!r}"
                )

    def _provisioner_role_payload(self) -> dict[str, Any]:
        return {
            "name": PROVISIONER_ROLE_NAME,
            "permissions": str(required_bot_permissions(self.manifest)),
            "color": PROVISIONER_ROLE_COLOR,
            "hoist": False,
            "mentionable": False,
        }

    def _reconcile_provisioner_role(
        self,
        existing: list[dict[str, Any]],
    ) -> None:
        if not self.bootstrap_from_administrator:
            return
        if self.bot_user_id is None:
            raise DiscordAPIError("bot identity is unavailable during bootstrap")

        found = self._find_by_state_or_name(
            existing,
            kind="roles",
            key=PROVISIONER_ROLE_KEY,
            name=PROVISIONER_ROLE_NAME,
            description="role",
        )
        if found is not None and found.get("managed"):
            raise DiscordAPIError(
                f"role name {PROVISIONER_ROLE_NAME!r} belongs to an "
                "integration-managed role"
            )
        payload = self._provisioner_role_payload()
        if found is None:
            self._record(f"create role {PROVISIONER_ROLE_NAME!r}")
            if self.apply:
                created = self.client.request(
                    "POST",
                    f"/guilds/{self.guild_id}/roles",
                    payload,
                    reason=self._reason(
                        f"create role {PROVISIONER_ROLE_NAME}"
                    ),
                )
                if not isinstance(created, dict) or not created.get("id"):
                    raise DiscordAPIError(
                        "Discord returned malformed provisioner role"
                    )
                found = created
                existing.append(created)
            else:
                found = {
                    "id": f"planned-role:{PROVISIONER_ROLE_KEY}",
                    "position": max(self.highest_bot_role_position - 1, 1),
                    **payload,
                }
        elif not _contains_desired(found, payload):
            self._record(f"update role {PROVISIONER_ROLE_NAME!r}")
            if self.apply:
                updated = self.client.request(
                    "PATCH",
                    f"/guilds/{self.guild_id}/roles/{found['id']}",
                    payload,
                    reason=self._reason(
                        f"update role {PROVISIONER_ROLE_NAME}"
                    ),
                )
                if not isinstance(updated, dict) or not updated.get("id"):
                    raise DiscordAPIError(
                        "Discord returned malformed provisioner role"
                    )
                found = updated

        provisioner_id = str(found["id"])
        if self.apply:
            refreshed = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/roles",
            )
            if not isinstance(refreshed, list):
                raise DiscordAPIError(
                    "Discord returned malformed roles during bootstrap"
                )
            by_id = {str(role.get("id")): role for role in refreshed}
            if provisioner_id not in by_id:
                raise DiscordAPIError(
                    f"role {PROVISIONER_ROLE_NAME!r} disappeared during bootstrap"
                )
            found = by_id[provisioner_id]
            existing[:] = [dict(role) for role in refreshed]

        if provisioner_id not in self.bot_role_ids:
            self._record(
                f"assign role {PROVISIONER_ROLE_NAME!r} to provisioning bot"
            )
            if self.apply:
                self.client.request(
                    "PUT",
                    f"/guilds/{self.guild_id}/members/"
                    f"{self.bot_user_id}/roles/{provisioner_id}",
                    reason=self._reason(
                        f"assign role {PROVISIONER_ROLE_NAME}"
                    ),
                )
            self.bot_role_ids.add(provisioner_id)
        self.roles[PROVISIONER_ROLE_KEY] = dict(found)

    def _preflight_onboarding_capacity(
        self,
        onboarding: Mapping[str, Any],
    ) -> None:
        current = onboarding.get("prompts", [])
        if not isinstance(current, list):
            raise DiscordAPIError("Discord returned malformed onboarding prompts")
        prompts: dict[str, set[str]] = {}
        for prompt in current:
            if not isinstance(prompt, dict):
                raise DiscordAPIError("Discord returned a malformed onboarding prompt")
            title = str(prompt.get("title", ""))
            if title in prompts:
                raise DiscordAPIError(
                    f"Discord onboarding has duplicate prompt title {title!r}"
                )
            options = prompt.get("options", [])
            if not isinstance(options, list):
                raise DiscordAPIError(
                    f"Discord onboarding prompt {title!r} has malformed options"
                )
            if any(not isinstance(option, dict) for option in options):
                raise DiscordAPIError(
                    f"Discord onboarding prompt {title!r} has malformed options"
                )
            option_titles = [str(option.get("title", "")) for option in options]
            if len(option_titles) != len(set(option_titles)):
                raise DiscordAPIError(
                    f"Discord onboarding prompt {title!r} has duplicate options"
                )
            prompts[title] = set(option_titles)
        if self.manifest.get("authoritative", False):
            return
        for desired in self.manifest["onboarding"]["prompts"]:
            titles = prompts.setdefault(desired["title"], set())
            titles.update(option["title"] for option in desired["options"])
            if len(titles) > 26:
                raise DiscordAPIError(
                    f"onboarding prompt {desired['title']!r} would exceed "
                    "Discord's 26-option limit"
                )
        if len(prompts) > 5:
            raise DiscordAPIError(
                "managed and unmanaged onboarding prompts would exceed "
                "Discord's 5-prompt limit"
            )

    def _preflight_automod_capacity(
        self,
        existing: Sequence[Mapping[str, Any]],
    ) -> None:
        limits = {1: 6, 3: 1, 4: 1, 5: 1}
        counts: dict[int, int] = {}
        try:
            for rule in existing:
                if not isinstance(rule, dict):
                    raise TypeError
                trigger_type = int(rule.get("trigger_type", 0))
                counts[trigger_type] = counts.get(trigger_type, 0) + 1
        except (TypeError, ValueError) as error:
            raise DiscordAPIError("Discord returned malformed AutoMod rules") from error
        for definition in self.manifest["automod_rules"]:
            desired_type = AUTOMOD_TRIGGER_TYPES[definition["trigger"]["type"]]
            found = self._find_automod_rule(existing, definition)
            if found is not None:
                if int(found.get("trigger_type", 0)) != desired_type:
                    raise DiscordAPIError(
                        f"AutoMod rule {definition['name']!r} has immutable "
                        "trigger_type mismatch"
                    )
                continue
            counts[desired_type] = counts.get(desired_type, 0) + 1
            if counts[desired_type] > limits[desired_type]:
                raise DiscordAPIError(
                    f"creating AutoMod rule {definition['name']!r} would exceed "
                    "Discord's trigger-type limit"
                )

    def _find_automod_rule(
        self,
        existing: Sequence[Mapping[str, Any]],
        definition: Mapping[str, Any],
    ) -> Mapping[str, Any] | None:
        found = self._find_by_state_or_name(
            existing,
            kind="automod_rules",
            key=definition["key"],
            name=definition["name"],
            description="AutoMod rule",
        )
        if found is not None:
            return found

        desired_type = AUTOMOD_TRIGGER_TYPES[definition["trigger"]["type"]]
        if desired_type not in {
            AUTOMOD_TRIGGER_TYPES["spam"],
            AUTOMOD_TRIGGER_TYPES["keyword_preset"],
            AUTOMOD_TRIGGER_TYPES["mention_spam"],
        }:
            return None
        try:
            matches = [
                rule
                for rule in existing
                if int(rule.get("trigger_type", 0)) == desired_type
            ]
        except (AttributeError, TypeError, ValueError) as error:
            raise DiscordAPIError(
                "Discord returned malformed AutoMod rules"
            ) from error
        if len(matches) > 1:
            raise DiscordAPIError(
                f"Discord returned multiple singleton AutoMod rules with "
                f"trigger type {desired_type}"
            )
        return matches[0] if matches else None

    def _fetch_all_members(self) -> list[dict[str, Any]]:
        members: list[dict[str, Any]] = []
        after: str | None = None
        seen_ids: set[str] = set()
        while True:
            query = "?limit=1000"
            if after is not None:
                query += "&after=" + urllib.parse.quote(after, safe="")
            page = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/members{query}",
            )
            if not isinstance(page, list):
                raise DiscordAPIError(
                    "Discord returned malformed guild member pagination"
                )
            for raw_member in page:
                if (
                    not isinstance(raw_member, dict)
                    or not isinstance(raw_member.get("user"), dict)
                    or not raw_member["user"].get("id")
                    or not isinstance(raw_member.get("roles"), list)
                ):
                    raise DiscordAPIError(
                        "Discord returned a malformed guild member"
                    )
                member_id = str(raw_member["user"]["id"])
                if member_id in seen_ids:
                    raise DiscordAPIError(
                        "Discord member pagination returned a duplicate member"
                    )
                seen_ids.add(member_id)
                members.append(copy.deepcopy(raw_member))
            if len(page) < 1000:
                return members
            next_after = str(page[-1]["user"]["id"])
            if next_after == after:
                raise DiscordAPIError("Discord member pagination did not advance")
            after = next_after

    @staticmethod
    def _objects_by_id(
        objects: Sequence[Mapping[str, Any]],
        description: str,
    ) -> dict[str, Mapping[str, Any]]:
        result: dict[str, Mapping[str, Any]] = {}
        for item in objects:
            item_id = str(item.get("id"))
            if item_id in result:
                raise DiscordAPIError(
                    f"Discord returned duplicate {description} ID {item_id}"
                )
            result[item_id] = item
        return result

    def _managed_existing_ids(
        self,
        objects: Sequence[Mapping[str, Any]],
        *,
        kind: str,
        definitions: Sequence[Mapping[str, Any]],
        description: str,
    ) -> set[str]:
        result: set[str] = set()
        for definition in definitions:
            found = self._find_by_state_or_name(
                objects,
                kind=kind,
                key=definition["key"],
                name=definition["name"],
                description=description,
            )
            if found is not None:
                result.add(str(found["id"]))
            saved_id = self._state_id(kind, definition["key"])
            if saved_id is not None:
                result.add(saved_id)
        return result

    def _prepare_cleanup(
        self,
        guild: Mapping[str, Any],
        existing_roles: Sequence[Mapping[str, Any]],
        existing_channels: Sequence[Mapping[str, Any]],
        automod_rules: Sequence[Mapping[str, Any]],
    ) -> None:
        cleanup = self.manifest.get("cleanup")
        if not isinstance(cleanup, dict):
            return
        declared_count = sum(
            len(cleanup.get(kind, []))
            for kind in ("roles", "channels", "categories")
        )
        if not declared_count:
            return
        if not self.cleanup_obsolete:
            self.output(
                f"CLEANUP AVAILABLE: {declared_count} exact obsolete target(s); "
                "use --cleanup-obsolete to include them."
            )
            return

        roles_by_id = self._objects_by_id(existing_roles, "role")
        channels_by_id = self._objects_by_id(existing_channels, "channel")
        category_definitions = self.manifest["categories"]
        channel_definitions = self.manifest["channels"]
        managed_role_ids = self._managed_existing_ids(
            existing_roles,
            kind="roles",
            definitions=self.manifest["roles"],
            description="role",
        )
        provisioner = self._find_by_state_or_name(
            existing_roles,
            kind="roles",
            key=PROVISIONER_ROLE_KEY,
            name=PROVISIONER_ROLE_NAME,
            description="role",
        )
        if provisioner is not None:
            managed_role_ids.add(str(provisioner["id"]))
        managed_category_ids = self._managed_existing_ids(
            existing_channels,
            kind="categories",
            definitions=category_definitions,
            description="category",
        )
        managed_channel_ids = self._managed_existing_ids(
            existing_channels,
            kind="channels",
            definitions=channel_definitions,
            description="channel",
        )
        cleanup_channel_ids = {
            str(item["id"]) for item in cleanup["channels"]
        }
        cleanup_role_ids = {str(item["id"]) for item in cleanup["roles"]}
        if self.guild_id in cleanup_role_ids:
            raise DiscordAPIError("cleanup may not target @everyone")

        desired_ref_ids: dict[str, str] = {}
        for setting_field, manifest_field in (
            ("rules_channel_id", "rules_channel"),
            ("public_updates_channel_id", "public_updates_channel"),
            ("safety_alerts_channel_id", "safety_alerts_channel"),
            ("system_channel_id", "system_channel"),
        ):
            manifest_ref = self.manifest["guild"][manifest_field]
            if manifest_ref is None:
                continue
            definition = next(
                item
                for item in channel_definitions
                if item["key"] == manifest_ref
            )
            found = self._find_by_state_or_name(
                existing_channels,
                kind="channels",
                key=definition["key"],
                name=definition["name"],
                description="channel",
            )
            if (
                str(guild.get(setting_field)) in cleanup_channel_ids
                and found is None
            ):
                raise DiscordAPIError(
                    f"cannot preflight cleanup of active {setting_field}: "
                    "its managed replacement does not exist yet"
                )
            if found is not None:
                desired_ref_ids[setting_field] = str(found["id"])

        for definition in cleanup["channels"]:
            target_id = str(definition["id"])
            found = channels_by_id.get(target_id)
            if found is None:
                continue
            expected_type = CHANNEL_TYPES[definition["type"]]
            if (
                found.get("name") != definition["name"]
                or int(found.get("type", -1)) != expected_type
            ):
                raise DiscordAPIError(
                    f"obsolete channel ID {target_id} no longer matches "
                    f"{definition['type']} channel {definition['name']!r}"
                )
            if target_id in managed_channel_ids:
                raise DiscordAPIError(
                    f"cleanup channel {definition['name']!r} is managed"
                )
            for field, desired_id in desired_ref_ids.items():
                if target_id == desired_id:
                    raise DiscordAPIError(
                        f"cleanup channel {definition['name']!r} is the "
                        f"desired guild {field}"
                    )
            self.cleanup_plan["channels"].append(
                {
                    "definition": copy.deepcopy(definition),
                    "object": copy.deepcopy(dict(found)),
                }
            )

        managed_automod_ids = {
            str(found["id"])
            for definition in self.manifest["automod_rules"]
            for found in [self._find_automod_rule(automod_rules, definition)]
            if found is not None
        }
        for rule in automod_rules:
            if str(rule.get("id")) in managed_automod_ids:
                continue
            referenced = {
                str(value) for value in rule.get("exempt_channels", [])
            }
            for action in rule.get("actions", []):
                if not isinstance(action, dict):
                    raise DiscordAPIError(
                        "Discord returned malformed unmanaged AutoMod rule"
                    )
                metadata = action.get("metadata", {})
                if isinstance(metadata, dict) and metadata.get("channel_id"):
                    referenced.add(str(metadata["channel_id"]))
            conflict = referenced & cleanup_channel_ids
            if conflict:
                raise DiscordAPIError(
                    f"unmanaged AutoMod rule {rule.get('name')!r} references "
                    "a declared obsolete channel"
                )

        allowed_category_children = cleanup_channel_ids | managed_channel_ids
        for definition in cleanup["categories"]:
            target_id = str(definition["id"])
            found = channels_by_id.get(target_id)
            if found is None:
                continue
            if (
                found.get("name") != definition["name"]
                or int(found.get("type", -1))
                != CHANNEL_TYPES["category"]
            ):
                raise DiscordAPIError(
                    f"obsolete category ID {target_id} no longer matches "
                    f"category {definition['name']!r}"
                )
            if target_id in managed_category_ids:
                raise DiscordAPIError(
                    f"cleanup category {definition['name']!r} is managed"
                )
            unknown_children = [
                str(channel.get("id"))
                for channel in existing_channels
                if str(channel.get("parent_id")) == target_id
                and str(channel.get("id")) not in allowed_category_children
            ]
            if unknown_children:
                raise DiscordAPIError(
                    f"obsolete category {definition['name']!r} contains "
                    "unmanaged channels not declared for cleanup: "
                    + ", ".join(unknown_children)
                )
            self.cleanup_plan["categories"].append(
                {
                    "definition": copy.deepcopy(definition),
                    "object": copy.deepcopy(dict(found)),
                }
            )

        active_cleanup_roles: list[tuple[Mapping[str, Any], Mapping[str, Any]]] = []
        for definition in cleanup["roles"]:
            target_id = str(definition["id"])
            found = roles_by_id.get(target_id)
            if found is None:
                continue
            if found.get("name") != definition["name"]:
                raise DiscordAPIError(
                    f"obsolete role ID {target_id} no longer matches role "
                    f"{definition['name']!r}"
                )
            if found.get("managed") or target_id in managed_role_ids:
                raise DiscordAPIError(
                    f"cleanup role {definition['name']!r} is managed"
                )
            if (
                found.get("position") is None
                or int(found["position"]) >= self.highest_bot_role_position
            ):
                raise DiscordAPIError(
                    f"cleanup role {definition['name']!r} is at or above "
                    "the bot's highest role"
                )
            active_cleanup_roles.append((definition, found))

        members = self._fetch_all_members() if active_cleanup_roles else []
        for definition, found in active_cleanup_roles:
            target_role: Mapping[str, Any] | None = None
            target_key = definition.get("migrate_to")
            if target_key is not None:
                target_definition = next(
                    item
                    for item in self.manifest["roles"]
                    if item["key"] == target_key
                )
                target_role = self._find_by_state_or_name(
                    existing_roles,
                    kind="roles",
                    key=target_definition["key"],
                    name=target_definition["name"],
                    description="role",
                )
                if target_role is None:
                    raise DiscordAPIError(
                        f"cleanup migration target {target_definition['name']!r} "
                        "does not exist; apply configuration without cleanup first"
                    )
            assigned = [
                member
                for member in members
                if str(found["id"]) in {
                    str(role_id) for role_id in member["roles"]
                }
            ]
            self.cleanup_plan["roles"].append(
                {
                    "definition": copy.deepcopy(definition),
                    "object": copy.deepcopy(dict(found)),
                    "target_role": (
                        copy.deepcopy(dict(target_role))
                        if target_role is not None
                        else None
                    ),
                    "members": copy.deepcopy(assigned),
                    "member_ids": [
                        str(member["user"]["id"]) for member in assigned
                    ],
                }
            )
        self._validate_cleanup_role_assignments(
            guild,
            existing_roles,
            self.cleanup_plan["roles"],
            self.highest_bot_role_position,
        )

    def _validate_cleanup_role_assignments(
        self,
        guild: Mapping[str, Any],
        roles: Sequence[Mapping[str, Any]],
        cleanup_roles: Sequence[Mapping[str, Any]],
        highest_bot_position: int,
    ) -> None:
        if not cleanup_roles:
            return
        owner_id = guild.get("owner_id")
        if owner_id is None:
            raise DiscordAPIError(
                "Discord omitted guild owner_id during cleanup preflight"
            )
        roles_by_id = self._objects_by_id(roles, "role")
        for item in cleanup_roles:
            definition = item["definition"]
            target_role = item.get("target_role")
            if (
                target_role is not None
                and (
                    target_role.get("position") is None
                    or int(target_role["position"]) >= highest_bot_position
                )
            ):
                raise DiscordAPIError(
                    f"cleanup migration target {target_role.get('name')!r} "
                    "is not assignable by the provisioning bot"
                )
            for member in item.get("members", []):
                member_id = str(member["user"]["id"])
                if member_id == str(owner_id):
                    raise DiscordAPIError(
                        f"guild owner has obsolete role "
                        f"{definition['name']!r}; refusing automated mutation"
                    )
                member_positions: list[int] = []
                for role_id in member["roles"]:
                    role = roles_by_id.get(str(role_id))
                    if role is None or role.get("position") is None:
                        raise DiscordAPIError(
                            f"member {member_id} has an unknown positioned role"
                        )
                    member_positions.append(int(role["position"]))
                if (
                    member_positions
                    and max(member_positions) >= highest_bot_position
                ):
                    raise DiscordAPIError(
                        f"member {member_id} with obsolete role "
                        f"{definition['name']!r} is at or above the bot's "
                        "highest role"
                    )

    def _record_cleanup(self, message: str) -> None:
        self.actions.append(message)
        operation = "apply" if self.apply else "plan"
        self.output(f"CLEANUP: {operation} {message}")

    def _verify_cleanup_ready(
        self,
    ) -> tuple[Mapping[str, Any], list[dict[str, Any]]]:
        if not self.apply:
            return {}, []
        current_guild: Mapping[str, Any] = {}
        current_channels: list[dict[str, Any]] = []
        if any(self.cleanup_plan.values()):
            guild = self.client.request("GET", f"/guilds/{self.guild_id}")
            if not isinstance(guild, dict):
                raise DiscordAPIError(
                    "Discord returned malformed guild before cleanup"
                )
            current_guild = guild
        if self.cleanup_plan["channels"] or self.cleanup_plan["categories"]:
            channels = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/channels",
            )
            if not isinstance(channels, list):
                raise DiscordAPIError(
                    "Discord returned malformed channels before cleanup"
                )
            current_channels = channels
            by_id = self._objects_by_id(channels, "channel")
            for item in self.cleanup_plan["channels"]:
                definition = item["definition"]
                found = by_id.get(str(definition["id"]))
                if (
                    found is None
                    or found.get("name") != definition["name"]
                    or int(found.get("type", -1))
                    != CHANNEL_TYPES[definition["type"]]
                ):
                    raise DiscordAPIError(
                        f"obsolete channel {definition['name']!r} changed "
                        "after cleanup preflight"
                    )
                item["object"] = copy.deepcopy(dict(found))
            cleanup_channel_ids = {
                str(item["definition"]["id"])
                for item in self.cleanup_plan["channels"]
            }
            for item in self.cleanup_plan["categories"]:
                definition = item["definition"]
                target_id = str(definition["id"])
                found = by_id.get(target_id)
                if (
                    found is None
                    or found.get("name") != definition["name"]
                    or int(found.get("type", -1))
                    != CHANNEL_TYPES["category"]
                ):
                    raise DiscordAPIError(
                        f"obsolete category {definition['name']!r} changed "
                        "after cleanup preflight"
                    )
                unknown_children = [
                    str(channel.get("id"))
                    for channel in channels
                    if str(channel.get("parent_id")) == target_id
                    and str(channel.get("id")) not in cleanup_channel_ids
                ]
                if unknown_children:
                    raise DiscordAPIError(
                        f"obsolete category {definition['name']!r} is not "
                        "ready for cleanup; unexpected children: "
                        + ", ".join(unknown_children)
                    )
                item["object"] = copy.deepcopy(dict(found))
        if self.cleanup_plan["roles"]:
            roles = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/roles",
            )
            if not isinstance(roles, list):
                raise DiscordAPIError(
                    "Discord returned malformed roles before cleanup"
                )
            by_id = self._objects_by_id(roles, "role")
            anchor_positions = [
                int(role["position"])
                for role in roles
                if str(role.get("id")) in self.bot_role_ids
                and role.get("position") is not None
            ]
            if not anchor_positions:
                anchor_positions = [self.highest_bot_role_position]
            highest_bot_position = max(anchor_positions)
            members = self._fetch_all_members()
            for item in self.cleanup_plan["roles"]:
                definition = item["definition"]
                old_role_id = str(definition["id"])
                found = by_id.get(old_role_id)
                if (
                    found is None
                    or found.get("name") != definition["name"]
                    or found.get("managed")
                    or found.get("position") is None
                    or int(found["position"]) >= highest_bot_position
                ):
                    raise DiscordAPIError(
                        f"obsolete role {definition['name']!r} changed or "
                        "became unmanageable after cleanup preflight"
                    )
                item["object"] = copy.deepcopy(dict(found))
                target_role = item.get("target_role")
                if target_role is not None:
                    current_target = by_id.get(str(target_role["id"]))
                    if (
                        current_target is None
                        or current_target.get("name")
                        != target_role.get("name")
                    ):
                        raise DiscordAPIError(
                            f"cleanup migration target "
                            f"{target_role.get('name')!r} changed after preflight"
                        )
                    item["target_role"] = copy.deepcopy(dict(current_target))
                assigned = [
                    member
                    for member in members
                    if old_role_id in {
                        str(role_id) for role_id in member["roles"]
                    }
                ]
                item["members"] = copy.deepcopy(assigned)
                item["member_ids"] = [
                    str(member["user"]["id"]) for member in assigned
                ]
            self._validate_cleanup_role_assignments(
                current_guild,
                roles,
                self.cleanup_plan["roles"],
                highest_bot_position,
            )
        return current_guild, current_channels

    @staticmethod
    def _cleanup_object_matches_snapshot(
        current: Mapping[str, Any],
        snapshot: Mapping[str, Any],
    ) -> bool:
        stable_snapshot = {
            key: value
            for key, value in snapshot.items()
            if key != "position"
        }
        return _contains_desired(current, stable_snapshot)

    def _write_cleanup_deletion_snapshot(
        self,
        guild: Mapping[str, Any],
    ) -> None:
        if not any(self.cleanup_plan.values()):
            return
        if self.rollback_dir is None:
            raise DiscordAPIError(
                "cleanup requires a private rollback directory for the final "
                "pre-delete snapshot"
            )
        snapshot = {
            "snapshot_version": 1,
            "snapshot_kind": "pre-delete",
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "note": (
                "Final state captured immediately before destructive cleanup. "
                "Channel objects contain settings only: messages, threads, and "
                "attachments/files are not captured, and deletion is irreversible."
            ),
            "guild": copy.deepcopy(dict(guild)),
            "cleanup": {
                "roles": [
                    {
                        "definition": copy.deepcopy(item["definition"]),
                        "object": copy.deepcopy(item["object"]),
                        "member_ids": list(item.get("member_ids", [])),
                        "migrate_to": (
                            copy.deepcopy(item["target_role"])
                            if item.get("target_role") is not None
                            else None
                        ),
                    }
                    for item in self.cleanup_plan["roles"]
                ],
                "channels": [
                    {
                        "definition": copy.deepcopy(item["definition"]),
                        "object": copy.deepcopy(item["object"]),
                    }
                    for item in self.cleanup_plan["channels"]
                ],
                "categories": [
                    {
                        "definition": copy.deepcopy(item["definition"]),
                        "object": copy.deepcopy(item["object"]),
                    }
                    for item in self.cleanup_plan["categories"]
                ],
            },
        }
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = self.rollback_dir / f"pre-delete-{timestamp}.json"
        _write_private_json(path, self._redact_snapshot(snapshot))
        self.output(f"SNAPSHOT: wrote final cleanup state to {path}")

    def _resolve_cleanup_role_for_delete(
        self,
        item: Mapping[str, Any],
    ) -> Mapping[str, Any] | None:
        roles = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/roles",
        )
        if not isinstance(roles, list):
            raise DiscordAPIError(
                "Discord returned malformed roles immediately before deletion"
            )
        definition = item["definition"]
        role_id = str(definition["id"])
        current = self._objects_by_id(roles, "role").get(role_id)
        if current is None:
            return None
        anchor_positions = [
            int(role["position"])
            for role in roles
            if str(role.get("id")) in self.bot_role_ids
            and role.get("position") is not None
        ]
        highest_bot_position = (
            max(anchor_positions)
            if anchor_positions
            else self.highest_bot_role_position
        )
        if (
            current.get("name") != definition["name"]
            or current.get("managed")
            or current.get("position") is None
            or int(current["position"]) >= highest_bot_position
        ):
            raise DiscordAPIError(
                f"obsolete role {definition['name']!r} changed or became "
                "unmanageable immediately before deletion"
            )
        if not self._cleanup_object_matches_snapshot(
            current,
            item["object"],
        ):
            raise DiscordAPIError(
                f"obsolete role {definition['name']!r} settings changed after "
                "the final cleanup snapshot"
            )
        managed_role_ids = {
            str(role["id"]) for role in self.roles.values()
        }
        if role_id in managed_role_ids:
            raise DiscordAPIError(
                f"obsolete role {definition['name']!r} became managed before "
                "deletion"
            )
        return current

    def _resolve_cleanup_channel_for_delete(
        self,
        item: Mapping[str, Any],
        *,
        category: bool,
    ) -> Mapping[str, Any] | None:
        definition = item["definition"]
        channel_id = str(definition["id"])
        try:
            current = self.client.request("GET", f"/channels/{channel_id}")
        except DiscordAPIError as error:
            if error.status == 404:
                return None
            raise
        description = "category" if category else "channel"
        if not isinstance(current, dict):
            raise DiscordAPIError(
                f"Discord returned malformed {description} immediately "
                "before deletion"
            )
        expected_type = (
            CHANNEL_TYPES["category"]
            if category
            else CHANNEL_TYPES[definition["type"]]
        )
        if (
            str(current.get("id")) != channel_id
            or current.get("name") != definition["name"]
            or int(current.get("type", -1)) != expected_type
        ):
            raise DiscordAPIError(
                f"obsolete {description} {definition['name']!r} changed "
                "immediately before deletion"
            )
        if not self._cleanup_object_matches_snapshot(
            current,
            item["object"],
        ):
            raise DiscordAPIError(
                f"obsolete {description} {definition['name']!r} settings "
                "changed after the final cleanup snapshot"
            )
        managed = self.categories if category else self.channels
        if channel_id in {str(channel["id"]) for channel in managed.values()}:
            raise DiscordAPIError(
                f"obsolete {description} {definition['name']!r} became "
                "managed before deletion"
            )
        return current

    def _execute_cleanup(self) -> None:
        if not self.cleanup_obsolete:
            return
        current_guild, _ = self._verify_cleanup_ready()
        if self.apply:
            self._write_cleanup_deletion_snapshot(current_guild)

        # Migrate and verify roles before deleting channels with message history.
        for item in self.cleanup_plan["roles"]:
            definition = item["definition"]
            old_role_id = str(definition["id"])
            target_role = item["target_role"]
            target_role_id = (
                str(target_role["id"]) if target_role is not None else None
            )
            members = item["members"]
            if members:
                if target_role is None:
                    message = (
                        f"remove obsolete role {definition['name']!r} from "
                        f"{len(members)} member(s)"
                    )
                else:
                    message = (
                        f"migrate {len(members)} member(s) from "
                        f"{definition['name']!r} to "
                        f"{target_role.get('name')!r}"
                    )
                self._record_cleanup(message)
            if self.apply:
                for member in members:
                    member_id = str(member["user"]["id"])
                    assigned_ids = {
                        str(role_id) for role_id in member["roles"]
                    }
                    if (
                        target_role_id is not None
                        and target_role_id not in assigned_ids
                    ):
                        self.client.request(
                            "PUT",
                            f"/guilds/{self.guild_id}/members/{member_id}/roles/"
                            f"{target_role_id}",
                            reason=self._reason(
                                f"migrate obsolete role {definition['name']}"
                            ),
                        )
                    self.client.request(
                        "DELETE",
                        f"/guilds/{self.guild_id}/members/{member_id}/roles/"
                        f"{old_role_id}",
                        reason=self._reason(
                            f"remove obsolete role {definition['name']}"
                        ),
                    )
                remaining = [
                    member
                    for member in self._fetch_all_members()
                    if old_role_id in {
                        str(role_id) for role_id in member["roles"]
                    }
                ]
                if remaining:
                    raise DiscordAPIError(
                        f"refusing to delete obsolete role "
                        f"{definition['name']!r}; {len(remaining)} assignment(s) "
                        "remain"
                    )
                if self._resolve_cleanup_role_for_delete(item) is None:
                    continue
            self._record_cleanup(
                f"delete obsolete role {definition['name']!r} ({old_role_id})"
            )
            if self.apply:
                self.client.request(
                    "DELETE",
                    f"/guilds/{self.guild_id}/roles/{old_role_id}",
                    reason=self._reason(
                        f"delete obsolete role {definition['name']}"
                    ),
                )

        for item in self.cleanup_plan["channels"]:
            definition = item["definition"]
            target_id = str(definition["id"])
            if self.apply:
                if self._resolve_cleanup_channel_for_delete(
                    item,
                    category=False,
                ) is None:
                    continue
                refreshed_guild = self.client.request(
                    "GET",
                    f"/guilds/{self.guild_id}",
                )
                if not isinstance(refreshed_guild, dict):
                    raise DiscordAPIError(
                        "Discord returned malformed guild immediately before "
                        "channel deletion"
                    )
                guild_reference_ids = {
                    str(refreshed_guild.get(field))
                    for field in (
                        "rules_channel_id",
                        "public_updates_channel_id",
                        "safety_alerts_channel_id",
                        "system_channel_id",
                    )
                    if refreshed_guild.get(field) is not None
                }
                if target_id in guild_reference_ids:
                    raise DiscordAPIError(
                        f"refusing to delete obsolete channel "
                        f"{definition['name']!r} while it is a guild reference"
                    )
            self._record_cleanup(
                f"delete obsolete {definition['type']} channel "
                f"{definition['name']!r} ({target_id})"
            )
            if self.apply:
                self.client.request(
                    "DELETE",
                    f"/channels/{target_id}",
                    reason=self._reason(
                        f"delete obsolete channel {definition['name']}"
                    ),
                )

        for item in self.cleanup_plan["categories"]:
            definition = item["definition"]
            target_id = str(definition["id"])
            if self.apply:
                if self._resolve_cleanup_channel_for_delete(
                    item,
                    category=True,
                ) is None:
                    continue
                refreshed_channels = self.client.request(
                    "GET",
                    f"/guilds/{self.guild_id}/channels",
                )
                if not isinstance(refreshed_channels, list):
                    raise DiscordAPIError(
                        "Discord returned malformed channels immediately "
                        "before category deletion"
                    )
                children = [
                    channel
                    for channel in refreshed_channels
                    if str(channel.get("parent_id")) == target_id
                ]
                if children:
                    raise DiscordAPIError(
                        f"refusing to delete non-empty obsolete category "
                        f"{definition['name']!r}"
                    )
            self._record_cleanup(
                f"delete empty obsolete category "
                f"{definition['name']!r} ({target_id})"
            )
            if self.apply:
                self.client.request(
                    "DELETE",
                    f"/channels/{target_id}",
                    reason=self._reason(
                        f"delete obsolete category {definition['name']}"
                    ),
                )

    def run(self) -> list[str]:
        guild = self.client.request("GET", f"/guilds/{self.guild_id}")
        if not isinstance(guild, dict) or str(guild.get("id")) != self.guild_id:
            raise DiscordAPIError("Discord returned an unexpected guild")
        community_enabled = "COMMUNITY" in guild.get("features", [])

        existing_roles = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/roles",
        )
        existing_channels = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/channels",
        )
        if not isinstance(existing_roles, list) or not isinstance(
            existing_channels,
            list,
        ):
            raise DiscordAPIError("Discord returned malformed guild resources")
        self._preflight_bot(existing_roles)
        if (
            not community_enabled
            and not (
                self.bootstrap_from_administrator
                and self.bot_has_administrator
            )
        ):
            raise DiscordAPIError(
                "Community must already be enabled in Discord, or an "
                "Administrator bot must explicitly use "
                "--bootstrap-from-administrator"
            )

        if community_enabled:
            onboarding = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/onboarding",
            )
            automod_rules = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/auto-moderation/rules",
            )
        else:
            onboarding = {
                "prompts": [],
                "default_channel_ids": [],
                "enabled": False,
                "mode": 0,
            }
            automod_rules = []
        if not isinstance(onboarding, dict) or not isinstance(automod_rules, list):
            raise DiscordAPIError("Discord returned malformed Community resources")
        self._preflight_onboarding_capacity(onboarding)
        self._preflight_automod_capacity(automod_rules)
        self._prepare_cleanup(
            guild,
            existing_roles,
            existing_channels,
            automod_rules,
        )

        if self.apply:
            self._write_rollback_snapshot(
                guild,
                existing_roles,
                existing_channels,
                onboarding,
                automod_rules,
            )

        self._reconcile_provisioner_role(existing_roles)
        self._reconcile_roles(existing_roles)
        self._reconcile_categories(existing_channels)
        if not community_enabled:
            settings = self.manifest["guild"]
            self._reconcile_channels(
                existing_channels,
                only_keys={
                    settings["rules_channel"],
                    settings["public_updates_channel"],
                },
            )
            guild = self._enable_community(guild)
            if self.apply:
                onboarding = self.client.request(
                    "GET",
                    f"/guilds/{self.guild_id}/onboarding",
                )
                automod_rules = self.client.request(
                    "GET",
                    f"/guilds/{self.guild_id}/auto-moderation/rules",
                )
                if not isinstance(onboarding, dict) or not isinstance(
                    automod_rules,
                    list,
                ):
                    raise DiscordAPIError(
                        "Discord returned malformed Community resources "
                        "after enablement"
                    )
                self._preflight_onboarding_capacity(onboarding)
                self._preflight_automod_capacity(automod_rules)
        self._reconcile_channels(existing_channels)
        self._reconcile_channel_order()
        self._reconcile_guild(guild)
        self._reconcile_onboarding(onboarding)
        self._reconcile_automod(automod_rules)
        self._execute_cleanup()
        if self.apply:
            self._write_state()
        return self.actions

    def _state_id(self, kind: str, key: str) -> str | None:
        resources = self.state.get("resources", {})
        if not isinstance(resources, dict):
            return None
        group = resources.get(kind, {})
        if not isinstance(group, dict):
            return None
        item = group.get(key)
        if not isinstance(item, dict):
            return None
        value = item.get("id")
        return str(value) if value is not None else None

    def _find_by_state_or_name(
        self,
        objects: Sequence[Mapping[str, Any]],
        *,
        kind: str,
        key: str,
        name: str,
        description: str,
    ) -> Mapping[str, Any] | None:
        named = [item for item in objects if item.get("name") == name]
        if len(named) > 1:
            raise DiscordAPIError(
                f"ambiguous {description} name {name!r} in Discord"
            )
        saved_id = self._state_id(kind, key)
        if saved_id is not None:
            identified = [
                item for item in objects if str(item.get("id")) == saved_id
            ]
            if len(identified) > 1:
                raise DiscordAPIError(
                    f"Discord returned duplicate {description} ID {saved_id}"
                )
            if identified:
                if named and str(named[0].get("id")) != saved_id:
                    raise DiscordAPIError(
                        f"cannot rename managed {description} {key!r} to {name!r}: "
                        "that name is already used by another object"
                    )
                return identified[0]
        return named[0] if named else None

    @staticmethod
    def _redact_snapshot(value: Any) -> Any:
        if isinstance(value, dict):
            result = {}
            for key, item in value.items():
                normalized = str(key).lower()
                if any(
                    marker in normalized
                    for marker in (
                        "authorization",
                        "password",
                        "secret",
                        "token",
                        "webhook_url",
                    )
                ):
                    result[key] = "[REDACTED]"
                else:
                    result[key] = Provisioner._redact_snapshot(item)
            return result
        if isinstance(value, list):
            return [Provisioner._redact_snapshot(item) for item in value]
        return value

    def _managed_snapshot_objects(
        self,
        objects: Sequence[Mapping[str, Any]],
        kind: str,
        definitions: Sequence[Mapping[str, Any]],
    ) -> list[dict[str, Any]]:
        selected: dict[str, dict[str, Any]] = {}
        for definition in definitions:
            saved_id = self._state_id(kind, definition["key"])
            for item in objects:
                if (
                    (saved_id and str(item.get("id")) == saved_id)
                    or item.get("name") == definition["name"]
                ):
                    selected[str(item.get("id"))] = copy.deepcopy(dict(item))
        return list(selected.values())

    def _managed_automod_snapshot_objects(
        self,
        objects: Sequence[Mapping[str, Any]],
    ) -> list[dict[str, Any]]:
        selected: dict[str, dict[str, Any]] = {}
        for definition in self.manifest["automod_rules"]:
            found = self._find_automod_rule(objects, definition)
            if found is not None:
                selected[str(found.get("id"))] = copy.deepcopy(dict(found))
        return list(selected.values())

    def _write_rollback_snapshot(
        self,
        guild: Mapping[str, Any],
        roles: Sequence[Mapping[str, Any]],
        channels: Sequence[Mapping[str, Any]],
        onboarding: Mapping[str, Any],
        automod_rules: Sequence[Mapping[str, Any]],
    ) -> None:
        if self.rollback_dir is None:
            return
        self.rollback_dir.mkdir(parents=True, exist_ok=True)
        guild_fields = {
            key: copy.deepcopy(guild.get(key))
            for key in (
                "id",
                "name",
                "description",
                "preferred_locale",
                "verification_level",
                "default_message_notifications",
                "explicit_content_filter",
                "system_channel_flags",
                "rules_channel_id",
                "public_updates_channel_id",
                "safety_alerts_channel_id",
                "system_channel_id",
                "features",
            )
        }
        category_objects = [
            item
            for item in channels
            if item.get("type") == CHANNEL_TYPES["category"]
        ]
        channel_objects = [
            item
            for item in channels
            if item.get("type") != CHANNEL_TYPES["category"]
        ]
        role_definitions = list(self.manifest["roles"])
        if self.bootstrap_from_administrator:
            role_definitions.insert(
                0,
                {
                    "key": PROVISIONER_ROLE_KEY,
                    "name": PROVISIONER_ROLE_NAME,
                },
            )
        everyone = [
            copy.deepcopy(dict(item))
            for item in roles
            if str(item.get("id")) == self.guild_id
        ]
        snapshot = {
            "snapshot_version": 1,
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "note": (
                "Pre-apply safety snapshot. It is intentionally not an "
                "automatically executable rollback plan. Cleanup channel "
                "snapshots contain settings only: messages, threads, and "
                "attachments/files are not captured, and deletion is "
                "irreversible."
            ),
            "guild": guild_fields,
            "roles": everyone
            + self._managed_snapshot_objects(
                roles,
                "roles",
                role_definitions,
            ),
            "categories": self._managed_snapshot_objects(
                category_objects,
                "categories",
                self.manifest["categories"],
            ),
            "channels": self._managed_snapshot_objects(
                channel_objects,
                "channels",
                self.manifest["channels"],
            ),
            "onboarding": copy.deepcopy(dict(onboarding)),
            "automod_rules": self._managed_automod_snapshot_objects(
                automod_rules,
            ),
            "cleanup": {
                "roles": [
                    {
                        "object": copy.deepcopy(item["object"]),
                        "member_ids": list(item.get("member_ids", [])),
                        "migrate_to": (
                            copy.deepcopy(item["target_role"])
                            if item.get("target_role") is not None
                            else None
                        ),
                    }
                    for item in self.cleanup_plan["roles"]
                ],
                "channels": [
                    copy.deepcopy(item["object"])
                    for item in self.cleanup_plan["channels"]
                ],
                "categories": [
                    copy.deepcopy(item["object"])
                    for item in self.cleanup_plan["categories"]
                ],
            },
        }
        snapshot = self._redact_snapshot(snapshot)
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = self.rollback_dir / f"pre-apply-{timestamp}.json"
        _write_private_json(path, snapshot)
        self.output(f"SNAPSHOT: wrote redacted pre-apply state to {path}")

    def _write_state(self) -> None:
        if self.state_path is None:
            return

        def records(values: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
            return {
                key: {
                    "id": str(item["id"]),
                    "name": item["name"],
                }
                for key, item in values.items()
            }

        state = {
            "state_version": 1,
            "guild_id": self.guild_id,
            "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "resources": {
                "roles": records(self.roles),
                "categories": records(self.categories),
                "channels": records(self.channels),
                "automod_rules": records(self.automod_rules),
            },
        }
        _write_private_json(self.state_path, state)
        self.output(f"STATE: wrote managed IDs to {self.state_path}")

    @staticmethod
    def _unique_named(
        objects: Sequence[Mapping[str, Any]],
        name: str,
        kind: str,
    ) -> Mapping[str, Any] | None:
        matches = [item for item in objects if item.get("name") == name]
        if len(matches) > 1:
            raise DiscordAPIError(f"ambiguous {kind} name {name!r} in Discord")
        return matches[0] if matches else None

    def _role_payload(self, role: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "name": role["name"],
            "permissions": str(permission_bits(role["permissions"])),
            "color": role["color"],
            "hoist": role["hoist"],
            "mentionable": role["mentionable"],
        }

    def _reconcile_roles(self, existing: list[dict[str, Any]]) -> None:
        everyone_matches = [
            role
            for role in existing
            if str(role.get("id")) == self.guild_id or role.get("name") == "@everyone"
        ]
        unique_everyone = {
            str(role.get("id")): role for role in everyone_matches
        }
        if len(unique_everyone) != 1:
            raise DiscordAPIError("could not identify the unique @everyone role")
        everyone = next(iter(unique_everyone.values()))
        everyone_payload = {
            "permissions": str(
                permission_bits(self.manifest["everyone_permissions"])
            )
        }
        if not _contains_desired(everyone, everyone_payload):
            self._record("update @everyone base permissions")
            if self.apply:
                everyone = self.client.request(
                    "PATCH",
                    f"/guilds/{self.guild_id}/roles/{everyone['id']}",
                    everyone_payload,
                    reason=self._reason("update @everyone permissions"),
                )

        for role in self.manifest["roles"]:
            found = self._find_by_state_or_name(
                existing,
                kind="roles",
                key=role["key"],
                name=role["name"],
                description="role",
            )
            payload = self._role_payload(role)
            if found is not None and found.get("managed"):
                raise DiscordAPIError(
                    f"role name {role['name']!r} belongs to an integration-managed role"
                )
            if found is None:
                self._record(f"create role {role['name']!r}")
                if self.apply:
                    found = self.client.request(
                        "POST",
                        f"/guilds/{self.guild_id}/roles",
                        payload,
                        reason=self._reason(f"create role {role['name']}"),
                    )
                    existing.append(found)
                else:
                    found = {"id": f"planned-role:{role['key']}", **payload}
            elif not _contains_desired(found, payload):
                self._record(f"update role {role['name']!r}")
                if self.apply:
                    found = self.client.request(
                        "PATCH",
                        f"/guilds/{self.guild_id}/roles/{found['id']}",
                        payload,
                        reason=self._reason(f"update role {role['name']}"),
                    )
            self.roles[role["key"]] = dict(found)
        if self.apply:
            refreshed = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/roles",
            )
            if not isinstance(refreshed, list):
                raise DiscordAPIError("Discord returned malformed refreshed roles")
            by_id = {str(role.get("id")): role for role in refreshed}
            for key, role in self.roles.items():
                role_id = str(role["id"])
                if role_id not in by_id:
                    raise DiscordAPIError(
                        f"managed role {role.get('name')!r} disappeared"
                    )
                self.roles[key] = dict(by_id[role_id])
            existing[:] = [dict(role) for role in refreshed]

        provisioner = self._find_by_state_or_name(
            existing,
            kind="roles",
            key=PROVISIONER_ROLE_KEY,
            name=PROVISIONER_ROLE_NAME,
            description="role",
        )
        if (
            provisioner is not None
            and str(provisioner.get("id")) in self.bot_role_ids
        ):
            self.roles[PROVISIONER_ROLE_KEY] = dict(provisioner)
        self._reconcile_role_order(existing)

    def _role_order_target_positions(
        self,
        desired_keys: Sequence[str],
    ) -> list[int] | None:
        if any(self.roles[key].get("position") is None for key in desired_keys):
            return None
        positions = [
            int(self.roles[key]["position"]) for key in desired_keys
        ]
        if len(set(positions)) != len(positions):
            raise DiscordAPIError(
                "managed roles do not have unique hierarchy positions"
            )
        return sorted(positions, reverse=True)

    @staticmethod
    def _has_desired_role_order(positions: Sequence[int]) -> bool:
        return all(
            higher > lower
            for higher, lower in zip(positions, positions[1:])
        )

    def _assert_role_order(
        self,
        refreshed: Sequence[Mapping[str, Any]],
        desired_keys: Sequence[str],
    ) -> None:
        by_id = {str(role.get("id")): role for role in refreshed}
        actual_positions: list[int] = []
        for key in desired_keys:
            role_id = str(self.roles[key]["id"])
            role = by_id.get(role_id)
            if role is None or role.get("position") is None:
                raise DiscordAPIError(
                    f"managed role {self.roles[key].get('name')!r} disappeared "
                    "while ordering"
                )
            actual_positions.append(int(role["position"]))
            self.roles[key] = dict(role)
        if not self._has_desired_role_order(actual_positions):
            raise DiscordAPIError(
                "Discord did not apply the requested managed role hierarchy"
            )
        if desired_keys[0] == PROVISIONER_ROLE_KEY:
            if any(
                actual_positions[0] <= managed_position
                for managed_position in actual_positions[1:]
            ):
                raise DiscordAPIError(
                    f"{PROVISIONER_ROLE_NAME!r} is not above all managed roles"
                )

    def _reconcile_role_order(
        self,
        existing: list[dict[str, Any]],
    ) -> None:
        desired_keys = [role["key"] for role in self.manifest["roles"]]
        if PROVISIONER_ROLE_KEY in self.roles:
            desired_keys.insert(0, PROVISIONER_ROLE_KEY)
        elif self.bootstrap_from_administrator:
            raise DiscordAPIError(
                f"{PROVISIONER_ROLE_NAME!r} is unavailable during bootstrap"
            )
        target_positions = self._role_order_target_positions(desired_keys)
        current_positions = (
            [int(self.roles[key]["position"]) for key in desired_keys]
            if target_positions is not None
            else []
        )
        if (
            target_positions is not None
            and self._has_desired_role_order(current_positions)
        ):
            return
        self._record(
            "order CloudNow Provisioner and managed roles by relative hierarchy"
        )
        if not self.apply:
            return
        if target_positions is None:
            raise DiscordAPIError(
                "Discord omitted a managed role sorting position"
            )
        payload = [
            {
                "id": str(self.roles[key]["id"]),
                "position": target_positions[index],
            }
            for index, key in enumerate(desired_keys)
        ]
        updated = self.client.request(
            "PATCH",
            f"/guilds/{self.guild_id}/roles",
            payload,
            reason=self._reason("order provisioner and managed roles"),
        )
        if not isinstance(updated, list):
            raise DiscordAPIError("Discord returned malformed reordered roles")
        refreshed = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/roles",
        )
        if not isinstance(refreshed, list):
            raise DiscordAPIError("Discord returned malformed reordered roles")
        self._assert_role_order(refreshed, desired_keys)
        existing[:] = [dict(role) for role in refreshed]

    def _resolved_overwrites(
        self,
        overwrites: Sequence[Mapping[str, Any]],
    ) -> list[dict[str, Any]]:
        result = []
        for overwrite in overwrites:
            target = overwrite["target"]
            target_id = (
                self.guild_id
                if target == "@everyone"
                else str(self.roles[target]["id"])
            )
            result.append(
                {
                    "id": target_id,
                    "type": 0,
                    "allow": str(permission_bits(overwrite["allow"])),
                    "deny": str(permission_bits(overwrite["deny"])),
                }
            )
        everyone_deny = next(
            (
                int(item["deny"])
                for item in result
                if item["id"] == self.guild_id and item["type"] == 0
            ),
            0,
        )
        if self.bot_user_id and everyone_deny:
            result.append(
                {
                    "id": self.bot_user_id,
                    "type": 1,
                    "allow": str(BOT_CHANNEL_PERMISSIONS),
                    "deny": "0",
                }
            )
        return result

    def _verify_channel_write(
        self,
        response: Any,
        desired: Mapping[str, Any],
        *,
        description: str,
        expected_id: str | None = None,
    ) -> dict[str, Any]:
        if not isinstance(response, dict) or not response.get("id"):
            raise DiscordAPIError(
                f"Discord returned malformed {description} after write"
            )
        channel_id = str(response["id"])
        if expected_id is not None and channel_id != expected_id:
            raise DiscordAPIError(
                f"Discord returned the wrong {description} after write"
            )
        if not _contains_desired(response, desired):
            raise DiscordAPIError(
                f"Discord did not confirm all requested {description} settings"
            )
        refreshed = self.client.request("GET", f"/channels/{channel_id}")
        if (
            not isinstance(refreshed, dict)
            or str(refreshed.get("id")) != channel_id
            or not _contains_desired(refreshed, desired)
        ):
            raise DiscordAPIError(
                f"Discord did not persist all requested {description} settings"
            )
        return dict(refreshed)

    def _reconcile_categories(self, existing: list[dict[str, Any]]) -> None:
        existing_categories = [
            channel
            for channel in existing
            if channel.get("type") == CHANNEL_TYPES["category"]
        ]
        for category in self.manifest["categories"]:
            found = self._find_by_state_or_name(
                existing_categories,
                kind="categories",
                key=category["key"],
                name=category["name"],
                description="category",
            )
            desired_overwrites = self._resolved_overwrites(category["overwrites"])
            if found is None:
                payload = {
                    "name": category["name"],
                    "type": CHANNEL_TYPES["category"],
                    "permission_overwrites": desired_overwrites,
                }
                self._record(f"create category {category['name']!r}")
                if self.apply:
                    created = self.client.request(
                        "POST",
                        f"/guilds/{self.guild_id}/channels",
                        payload,
                        reason=self._reason(f"create category {category['name']}"),
                    )
                    found = self._verify_channel_write(
                        created,
                        payload,
                        description=f"category {category['name']!r}",
                    )
                    existing.append(found)
                    existing_categories.append(found)
                else:
                    found = {
                        "id": f"planned-category:{category['key']}",
                        **payload,
                    }
            else:
                merged = desired_overwrites
                if not self.manifest.get("authoritative", False):
                    merged = merge_permission_overwrites(
                        found.get("permission_overwrites", []),
                        desired_overwrites,
                    )
                patch = {"permission_overwrites": merged}
                if found.get("name") != category["name"]:
                    patch["name"] = category["name"]
                if not _contains_desired(found, patch):
                    self._record(f"update category {category['name']!r}")
                    if self.apply:
                        category_id = str(found["id"])
                        updated = self.client.request(
                            "PATCH",
                            f"/channels/{category_id}",
                            patch,
                            reason=self._reason(
                                f"update category {category['name']}"
                            ),
                        )
                        found = self._verify_channel_write(
                            updated,
                            {
                                "name": category["name"],
                                "type": CHANNEL_TYPES["category"],
                                "permission_overwrites": merged,
                            },
                            description=f"category {category['name']!r}",
                            expected_id=category_id,
                        )
            self.categories[category["key"]] = dict(found)

    def _desired_forum_tags(
        self,
        tags: Sequence[Mapping[str, Any]],
    ) -> list[dict[str, Any]]:
        result = []
        for tag in tags:
            item: dict[str, Any] = {
                "name": tag["name"],
                "moderated": tag["moderated"],
                "emoji_id": None,
                "emoji_name": tag.get("emoji"),
            }
            result.append(item)
        return result

    def _channel_payload(
        self,
        channel: Mapping[str, Any],
        existing: Mapping[str, Any] | None,
    ) -> dict[str, Any]:
        category = next(
            item
            for item in self.manifest["categories"]
            if item["key"] == channel["category"]
        )
        desired_overwrites = self._resolved_overwrites(
            merge_manifest_overwrites(
                category["overwrites"],
                channel["overwrites"],
            )
        )
        overwrites = desired_overwrites
        if (
            existing is not None
            and not self.manifest.get("authoritative", False)
        ):
            overwrites = merge_permission_overwrites(
                existing.get("permission_overwrites", []),
                desired_overwrites,
            )
        payload: dict[str, Any] = {
            "name": channel["name"],
            "type": CHANNEL_TYPES[channel["type"]],
            "parent_id": str(self.categories[channel["category"]]["id"]),
            "permission_overwrites": overwrites,
        }
        if channel["type"] in {"text", "announcement", "forum"}:
            payload["topic"] = channel["topic"]
        if channel["type"] in {"text", "voice", "announcement", "forum"}:
            payload["nsfw"] = channel["nsfw"]
        if channel["type"] in {"text", "voice", "forum"}:
            payload["rate_limit_per_user"] = channel["slowmode_seconds"]
        if channel["type"] in {
            "text",
            "announcement",
            "forum",
        } and "default_auto_archive_minutes" in channel:
            payload["default_auto_archive_duration"] = channel[
                "default_auto_archive_minutes"
            ]
        if "default_thread_slowmode_seconds" in channel:
            payload["default_thread_rate_limit_per_user"] = channel[
                "default_thread_slowmode_seconds"
            ]
        if channel["type"] == "voice" and "user_limit" in channel:
            payload["user_limit"] = channel["user_limit"]
        if channel["type"] == "forum":
            desired_tags = self._desired_forum_tags(channel.get("forum_tags", []))
            merged_tags = (
                desired_tags
                if existing is None
                else merge_forum_tags(
                    existing.get("available_tags", []),
                    desired_tags,
                )
            )
            if self.manifest.get("authoritative", False):
                desired_names = {str(item["name"]) for item in desired_tags}
                merged_tags = [
                    item
                    for item in merged_tags
                    if str(item.get("name")) in desired_names
                ]
            if len(merged_tags) > 20:
                raise DiscordAPIError(
                    f"forum {channel['name']!r} would exceed Discord's 20-tag "
                    "limit after preserving unmanaged tags"
                )
            payload["available_tags"] = merged_tags
            if "require_tag" in channel:
                flags = int(existing.get("flags", 0)) if existing else 0
                if channel["require_tag"]:
                    flags |= CHANNEL_FLAG_REQUIRE_TAG
                else:
                    flags &= ~CHANNEL_FLAG_REQUIRE_TAG
                payload["flags"] = flags
        return payload

    def _reconcile_channels(
        self,
        existing: list[dict[str, Any]],
        *,
        only_keys: set[str] | None = None,
    ) -> None:
        existing_channels = [
            item
            for item in existing
            if item.get("type") != CHANNEL_TYPES["category"]
        ]
        for channel in self.manifest["channels"]:
            if channel["key"] in self.channels:
                continue
            if only_keys is not None and channel["key"] not in only_keys:
                continue
            found = self._find_by_state_or_name(
                existing_channels,
                kind="channels",
                key=channel["key"],
                name=channel["name"],
                description="channel",
            )
            expected_type = CHANNEL_TYPES[channel["type"]]
            if found is not None and found.get("type") != expected_type:
                raise DiscordAPIError(
                    f"channel {channel['name']!r} has Discord type "
                    f"{found.get('type')}, expected {expected_type}; refusing replacement"
                )
            payload = self._channel_payload(channel, found)
            if found is None:
                self._record(
                    f"create {channel['type']} channel {channel['name']!r}"
                )
                if self.apply:
                    created = self.client.request(
                        "POST",
                        f"/guilds/{self.guild_id}/channels",
                        payload,
                        reason=self._reason(f"create channel {channel['name']}"),
                    )
                    if not isinstance(created, dict) or not created.get("id"):
                        raise DiscordAPIError(
                            f"Discord returned malformed channel "
                            f"{channel['name']!r} after write"
                        )
                    confirmed_payload = self._channel_payload(channel, created)
                    found = self._verify_channel_write(
                        created,
                        confirmed_payload,
                        description=f"channel {channel['name']!r}",
                    )
                    existing.append(found)
                    existing_channels.append(found)
                else:
                    found = {
                        "id": f"planned-channel:{channel['key']}",
                        **payload,
                    }
            else:
                patch = dict(payload)
                patch.pop("type", None)
                if not _contains_desired(found, patch):
                    self._record(
                        f"update {channel['type']} channel {channel['name']!r}"
                    )
                    if self.apply:
                        channel_id = str(found["id"])
                        updated = self.client.request(
                            "PATCH",
                            f"/channels/{channel_id}",
                            patch,
                            reason=self._reason(f"update channel {channel['name']}"),
                        )
                        if not isinstance(updated, dict) or not updated.get("id"):
                            raise DiscordAPIError(
                                f"Discord returned malformed channel "
                                f"{channel['name']!r} after write"
                            )
                        confirmed_payload = self._channel_payload(channel, updated)
                        found = self._verify_channel_write(
                            updated,
                            confirmed_payload,
                            description=f"channel {channel['name']!r}",
                            expected_id=channel_id,
                        )
            self.channels[channel["key"]] = dict(found)

    def _enable_community(
        self,
        guild: Mapping[str, Any],
    ) -> dict[str, Any]:
        if "COMMUNITY" in guild.get("features", []):
            return dict(guild)
        if not (
            self.bootstrap_from_administrator
            and self.bot_has_administrator
        ):
            raise DiscordAPIError(
                "enabling Community requires explicit Administrator bootstrap"
            )
        settings = self.manifest["guild"]
        features = {
            str(feature) for feature in guild.get("features", [])
        }
        features.add("COMMUNITY")
        payload = {
            "features": sorted(features),
            "verification_level": settings["verification_level"],
            "default_message_notifications": settings[
                "default_message_notifications"
            ],
            "explicit_content_filter": settings["explicit_content_filter"],
            "rules_channel_id": str(
                self.channels[settings["rules_channel"]]["id"]
            ),
            "public_updates_channel_id": str(
                self.channels[settings["public_updates_channel"]]["id"]
            ),
        }
        self._record("enable Community with managed rules and updates channels")
        if not self.apply:
            return {**dict(guild), **payload}
        updated = self.client.request(
            "PATCH",
            f"/guilds/{self.guild_id}",
            payload,
            reason=self._reason("enable Community"),
        )
        if (
            not isinstance(updated, dict)
            or "COMMUNITY" not in updated.get("features", [])
        ):
            raise DiscordAPIError(
                "Discord did not confirm Community enablement"
            )
        return updated

    def _reconcile_channel_order(self) -> None:
        if self.apply:
            refreshed = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/channels",
            )
            if not isinstance(refreshed, list):
                raise DiscordAPIError("Discord returned malformed refreshed channels")
            by_id = self._objects_by_id(refreshed, "channel")
            for resources in (self.categories, self.channels):
                for key, channel in resources.items():
                    channel_id = str(channel["id"])
                    if channel_id not in by_id:
                        raise DiscordAPIError(
                            f"managed channel {channel.get('name')!r} disappeared"
                        )
                    resources[key] = dict(by_id[channel_id])

        groups: list[
            tuple[list[str], dict[str, dict[str, Any]], str | None]
        ] = [
            (
                [category["key"] for category in self.manifest["categories"]],
                self.categories,
                None,
            )
        ]
        for category in self.manifest["categories"]:
            keys = [
                channel["key"]
                for channel in self.manifest["channels"]
                if channel["category"] == category["key"]
            ]
            groups.append(
                (
                    keys,
                    self.channels,
                    str(self.categories[category["key"]]["id"]),
                )
            )

        payload: list[dict[str, Any]] = []
        expected: list[
            tuple[list[str], dict[str, dict[str, Any]], str | None]
        ] = []

        def ordering_key(channel: Mapping[str, Any]) -> tuple[int, int]:
            try:
                return (
                    int(channel["position"]),
                    int(str(channel["id"])),
                )
            except (KeyError, TypeError, ValueError) as error:
                raise DiscordAPIError(
                    "Discord returned malformed managed channel ordering data"
                ) from error

        drifted = False
        for desired_keys, resources, parent_id in groups:
            if not desired_keys:
                continue
            expected.append((desired_keys, resources, parent_id))
            if parent_id is not None:
                for key in desired_keys:
                    if str(resources[key].get("parent_id")) != parent_id:
                        raise DiscordAPIError(
                            f"managed channel "
                            f"{resources[key].get('name')!r} does not have "
                            "its configured parent; refusing bulk ordering"
                        )
            if any(resources[key].get("position") is None for key in desired_keys):
                if self.apply:
                    raise DiscordAPIError(
                        "Discord omitted a managed channel sorting position"
                    )
                drifted = True
                continue
            current_positions = [
                int(resources[key]["position"]) for key in desired_keys
            ]
            current_order = [
                ordering_key(resources[key]) for key in desired_keys
            ]
            group_drifted = any(
                left >= right
                for left, right in zip(
                    current_order,
                    current_order[1:],
                )
            )
            if not group_drifted:
                continue
            drifted = True
            target_positions: list[int] = []
            for current_position in sorted(current_positions):
                if target_positions:
                    current_position = max(
                        current_position,
                        target_positions[-1] + 1,
                    )
                target_positions.append(current_position)
            payload.extend(
                {
                    "id": str(resources[key]["id"]),
                    "position": target_positions[index],
                }
                for index, key in enumerate(desired_keys)
            )
        if not drifted:
            return
        self._record("order managed categories and channels")
        if not self.apply:
            return
        if not payload:
            raise DiscordAPIError(
                "Discord omitted a managed channel sorting position"
            )
        self.client.request(
            "PATCH",
            f"/guilds/{self.guild_id}/channels",
            payload,
            reason=self._reason("order managed categories and channels"),
        )
        refreshed = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/channels",
        )
        if not isinstance(refreshed, list):
            raise DiscordAPIError("Discord returned malformed reordered channels")
        by_id = self._objects_by_id(refreshed, "channel")
        for desired_keys, resources, parent_id in expected:
            actual_order: list[tuple[int, int]] = []
            for key in desired_keys:
                channel_id = str(resources[key]["id"])
                channel = by_id.get(channel_id)
                if channel is None or channel.get("position") is None:
                    raise DiscordAPIError(
                        f"managed channel {resources[key].get('name')!r} "
                        "disappeared while ordering"
                    )
                if (
                    parent_id is not None
                    and str(channel.get("parent_id")) != parent_id
                ):
                    raise DiscordAPIError(
                        f"Discord did not retain the parent category for "
                        f"{channel.get('name')!r}"
                    )
                actual_order.append(ordering_key(channel))
                resources[key] = dict(channel)
            if any(
                left >= right
                for left, right in zip(
                    actual_order,
                    actual_order[1:],
                )
            ):
                raise DiscordAPIError(
                    "Discord did not apply the requested strict relative "
                    "managed category/channel ordering"
                )

    def _reconcile_guild(self, guild: Mapping[str, Any]) -> None:
        settings = self.manifest["guild"]
        current = dict(guild)
        scalar_payload = {
            "name": settings["name"],
            "description": settings["description"],
            "preferred_locale": settings["preferred_locale"],
            "verification_level": settings["verification_level"],
            "default_message_notifications": settings[
                "default_message_notifications"
            ],
            "explicit_content_filter": settings["explicit_content_filter"],
            "system_channel_flags": settings["system_channel_flags"],
        }

        def apply_and_verify(
            payload: Mapping[str, Any],
            operation: str,
        ) -> dict[str, Any]:
            updated = self.client.request(
                "PATCH",
                f"/guilds/{self.guild_id}",
                dict(payload),
                reason=self._reason(operation),
            )
            fields = ", ".join(payload)
            if (
                not isinstance(updated, dict)
                or str(updated.get("id")) != self.guild_id
                or not _contains_desired(updated, payload)
            ):
                raise DiscordAPIError(
                    f"Discord did not confirm requested guild field(s): "
                    f"{fields}"
                )
            refreshed = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}",
            )
            if (
                not isinstance(refreshed, dict)
                or str(refreshed.get("id")) != self.guild_id
                or not _contains_desired(refreshed, payload)
            ):
                raise DiscordAPIError(
                    f"Discord did not persist requested guild field(s): "
                    f"{fields}"
                )
            return dict(refreshed)

        if not _contains_desired(current, scalar_payload):
            self._record("update guild safety settings")
            if self.apply:
                current = apply_and_verify(
                    scalar_payload,
                    "update guild safety settings",
                )
            else:
                current.update(scalar_payload)

        reference_payload = {
            "rules_channel_id": str(
                self.channels[settings["rules_channel"]]["id"]
            ),
            "public_updates_channel_id": str(
                self.channels[settings["public_updates_channel"]]["id"]
            ),
            "safety_alerts_channel_id": str(
                self.channels[settings["safety_alerts_channel"]]["id"]
            ),
            "system_channel_id": (
                None
                if settings["system_channel"] is None
                else str(self.channels[settings["system_channel"]]["id"])
            ),
        }
        for field, desired in reference_payload.items():
            if current.get(field) == desired:
                continue
            self._record(f"update guild reference {field!r}")
            payload = {field: desired}
            if self.apply:
                current = apply_and_verify(
                    payload,
                    f"update guild reference {field}",
                )
            else:
                current[field] = desired

    def _onboarding_option_from_api(
        self,
        option: Mapping[str, Any],
    ) -> dict[str, Any]:
        if not option.get("id"):
            raise DiscordAPIError("Discord onboarding option is missing its ID")
        result = {
            "id": str(option["id"]),
            "title": option.get("title", ""),
            "description": option.get("description", ""),
            "channel_ids": [
                str(value) for value in option.get("channel_ids", [])
            ],
            "role_ids": [str(value) for value in option.get("role_ids", [])],
        }
        emoji = option.get("emoji")
        if isinstance(emoji, dict):
            result["emoji_id"] = emoji.get("id")
            result["emoji_name"] = emoji.get("name")
            result["emoji_animated"] = bool(emoji.get("animated", False))
        else:
            result["emoji_id"] = option.get("emoji_id")
            result["emoji_name"] = option.get("emoji_name")
            result["emoji_animated"] = bool(
                option.get("emoji_animated", False)
            )
        return result

    def _onboarding_prompt_from_api(
        self,
        prompt: Mapping[str, Any],
    ) -> dict[str, Any]:
        if not prompt.get("id"):
            raise DiscordAPIError("Discord onboarding prompt is missing its ID")
        options = prompt.get("options", [])
        if not isinstance(options, list):
            raise DiscordAPIError("Discord onboarding prompt has malformed options")
        return {
            "id": str(prompt["id"]),
            "title": str(prompt.get("title", "")),
            "type": int(prompt.get("type", 0)),
            "single_select": bool(prompt.get("single_select", False)),
            "required": bool(prompt.get("required", False)),
            "in_onboarding": bool(prompt.get("in_onboarding", True)),
            "options": [
                self._onboarding_option_from_api(option) for option in options
            ],
        }

    def _desired_onboarding_option(
        self,
        option: Mapping[str, Any],
        existing: Mapping[str, Any] | None,
    ) -> dict[str, Any]:
        result: dict[str, Any] = {
            "id": (
                str(existing["id"])
                if existing and existing.get("id")
                else self._new_temporary_snowflake()
            ),
            "title": option["title"],
            "description": option["description"],
            "channel_ids": [
                str(self.channels[key]["id"]) for key in option["channels"]
            ],
            "role_ids": [str(self.roles[key]["id"]) for key in option["roles"]],
            "emoji_id": None,
            "emoji_name": option.get("emoji"),
            "emoji_animated": False,
        }
        return result

    def _merge_onboarding_prompts(
        self,
        existing: Sequence[Mapping[str, Any]],
    ) -> list[dict[str, Any]]:
        existing_by_title: dict[str, dict[str, Any]] = {}
        for prompt in existing:
            title = str(prompt.get("title", ""))
            if title in existing_by_title:
                raise DiscordAPIError(
                    f"Discord onboarding has duplicate prompt title {title!r}"
                )
            existing_by_title[title] = self._onboarding_prompt_from_api(prompt)

        authoritative = bool(self.manifest.get("authoritative", False))
        result: list[dict[str, Any]] = (
            [] if authoritative else list(existing_by_title.values())
        )
        prompt_positions = {
            str(prompt["title"]): index
            for index, prompt in enumerate(result)
        }

        for desired_prompt in self.manifest["onboarding"]["prompts"]:
            title = desired_prompt["title"]
            prior = (
                existing_by_title.get(title)
                if authoritative
                else (
                    result[prompt_positions[title]]
                    if title in prompt_positions
                    else None
                )
            )
            if prior is not None and not isinstance(prior, dict):
                prior = None
            prior_options = prior.get("options", []) if prior else []
            prior_options_by_title: dict[str, dict[str, Any]] = {}
            for option in prior_options:
                option_title = str(option.get("title", ""))
                if option_title in prior_options_by_title:
                    raise DiscordAPIError(
                        f"Discord onboarding prompt {title!r} has duplicate "
                        f"option {option_title!r}"
                    )
                prior_options_by_title[option_title] = dict(option)
            option_positions: dict[str, int] = {}
            merged_options: list[dict[str, Any]] = (
                []
                if authoritative
                else [dict(option) for option in prior_options]
            )
            if not authoritative:
                option_positions = {
                    str(option["title"]): index
                    for index, option in enumerate(merged_options)
                }
            for desired_option in desired_prompt["options"]:
                option_title = desired_option["title"]
                prior_option = prior_options_by_title.get(option_title)
                resolved = self._desired_onboarding_option(
                    desired_option,
                    prior_option,
                )
                if authoritative:
                    option_positions[option_title] = len(merged_options)
                    merged_options.append(resolved)
                elif option_title in option_positions:
                    merged_options[option_positions[option_title]] = resolved
                else:
                    option_positions[option_title] = len(merged_options)
                    merged_options.append(resolved)
            merged_prompt: dict[str, Any] = {
                "id": (
                    str(prior["id"])
                    if prior and prior.get("id")
                    else self._new_temporary_snowflake()
                ),
                "title": title,
                "type": 0,
                "single_select": desired_prompt["single_select"],
                "required": desired_prompt["required"],
                "in_onboarding": desired_prompt["in_onboarding"],
                "options": merged_options,
            }
            if title in prompt_positions:
                result[prompt_positions[title]] = merged_prompt
            else:
                prompt_positions[title] = len(result)
                result.append(merged_prompt)
        if len(result) > 5:
            raise DiscordAPIError(
                "managed and unmanaged onboarding prompts would exceed "
                "Discord's 5-prompt limit"
            )
        for prompt in result:
            if len(prompt.get("options", [])) > 26:
                raise DiscordAPIError(
                    f"onboarding prompt {prompt.get('title')!r} would exceed "
                    "Discord's 26-option limit"
                )
        return result

    def _onboarding_state_from_api(
        self,
        value: Mapping[str, Any],
    ) -> dict[str, Any]:
        prompts = value.get("prompts", [])
        default_channel_ids = value.get("default_channel_ids", [])
        if not isinstance(prompts, list) or not isinstance(
            default_channel_ids,
            list,
        ):
            raise DiscordAPIError("Discord returned malformed Community Onboarding")
        if not all(isinstance(prompt, dict) for prompt in prompts):
            raise DiscordAPIError(
                "Discord returned malformed Community Onboarding prompts"
            )
        return {
            "prompts": [
                self._onboarding_prompt_from_api(prompt)
                for prompt in prompts
            ],
            "default_channel_ids": [
                str(channel_id) for channel_id in default_channel_ids
            ],
            "enabled": bool(value.get("enabled", False)),
            "mode": int(value.get("mode", 0)),
        }

    def _onboarding_comparison_state(
        self,
        value: Mapping[str, Any],
        *,
        include_resource_ids: bool,
    ) -> dict[str, Any]:
        """Normalize unordered IDs while retaining prompt and option order."""
        state = self._onboarding_state_from_api(value)
        state["default_channel_ids"] = sorted(state["default_channel_ids"])
        resource_ids: list[str] = []
        for prompt in state["prompts"]:
            resource_ids.append(str(prompt["id"]))
            for option in prompt["options"]:
                option["channel_ids"] = sorted(option["channel_ids"])
                option["role_ids"] = sorted(option["role_ids"])
                resource_ids.append(str(option["id"]))
        if len(resource_ids) != len(set(resource_ids)):
            raise DiscordAPIError(
                "Discord onboarding returned duplicate prompt or option IDs"
            )
        if not include_resource_ids:
            for prompt in state["prompts"]:
                prompt.pop("id")
                for option in prompt["options"]:
                    option.pop("id")
        return state

    def _reconcile_onboarding(self, current: Mapping[str, Any]) -> None:
        desired_default_ids = [
            str(self.channels[key]["id"])
            for key in self.manifest["onboarding"]["default_channels"]
        ]
        if self.manifest.get("authoritative", False):
            default_ids = desired_default_ids
        else:
            default_ids = [
                str(value) for value in current.get("default_channel_ids", [])
            ]
            for channel_id in desired_default_ids:
                if channel_id not in default_ids:
                    default_ids.append(channel_id)
        payload = {
            "prompts": self._merge_onboarding_prompts(current.get("prompts", [])),
            "default_channel_ids": default_ids,
            "enabled": self.manifest["onboarding"]["enabled"],
            "mode": 0
            if self.manifest["onboarding"]["mode"] == "default"
            else 1,
        }
        semantic_payload = self._onboarding_comparison_state(
            payload,
            include_resource_ids=False,
        )
        if (
            self._onboarding_comparison_state(
                current,
                include_resource_ids=False,
            )
            != semantic_payload
        ):
            self._record("update Community Onboarding")
            if self.apply:
                updated = self.client.request(
                    "PUT",
                    f"/guilds/{self.guild_id}/onboarding",
                    payload,
                    reason=self._reason("update Community Onboarding"),
                )
                if not isinstance(updated, dict):
                    raise DiscordAPIError(
                        "Discord did not confirm exact Community Onboarding order "
                        "and settings"
                    )
                confirmed_semantic = self._onboarding_comparison_state(
                    updated,
                    include_resource_ids=False,
                )
                if confirmed_semantic != semantic_payload:
                    raise DiscordAPIError(
                        "Discord did not confirm exact Community Onboarding order "
                        "and settings"
                    )
                confirmed_state = self._onboarding_comparison_state(
                    updated,
                    include_resource_ids=True,
                )
                refreshed = self.client.request(
                    "GET",
                    f"/guilds/{self.guild_id}/onboarding",
                )
                if (
                    not isinstance(refreshed, dict)
                    or self._onboarding_comparison_state(
                        refreshed,
                        include_resource_ids=True,
                    )
                    != confirmed_state
                ):
                    raise DiscordAPIError(
                        "Discord did not persist exact Community Onboarding order "
                        "and settings"
                    )

    def _automod_trigger_payload(
        self,
        trigger: Mapping[str, Any],
    ) -> tuple[int, dict[str, Any]]:
        trigger_type = AUTOMOD_TRIGGER_TYPES[trigger["type"]]
        metadata: dict[str, Any] = {}
        if trigger["type"] == "keyword":
            metadata = {
                "keyword_filter": trigger.get("keywords", []),
                "regex_patterns": trigger.get("regex_patterns", []),
                "allow_list": trigger.get("allow_list", []),
            }
        elif trigger["type"] == "keyword_preset":
            presets = {
                "profanity": 1,
                "sexual_content": 2,
                "slurs": 3,
            }
            metadata = {
                "presets": [presets[item] for item in trigger["presets"]],
                "allow_list": trigger.get("allow_list", []),
            }
        elif trigger["type"] == "mention_spam":
            metadata = {
                "mention_total_limit": trigger["mention_limit"],
                "mention_raid_protection_enabled": trigger[
                    "mention_raid_protection"
                ],
            }
        return trigger_type, metadata

    def _automod_action_payload(
        self,
        action: Mapping[str, Any],
    ) -> dict[str, Any]:
        action_type = AUTOMOD_ACTION_TYPES[action["type"]]
        metadata: dict[str, Any] = {}
        if action["type"] == "send_alert":
            metadata["channel_id"] = str(self.channels[action["channel"]]["id"])
        elif action["type"] == "block_message" and action.get("custom_message"):
            metadata["custom_message"] = action["custom_message"]
        elif action["type"] == "timeout":
            metadata["duration_seconds"] = action["duration_seconds"]
        return {"type": action_type, "metadata": metadata}

    def _automod_payload(self, rule: Mapping[str, Any]) -> dict[str, Any]:
        trigger_type, trigger_metadata = self._automod_trigger_payload(
            rule["trigger"]
        )
        return {
            "name": rule["name"],
            "event_type": 1,
            "trigger_type": trigger_type,
            "trigger_metadata": trigger_metadata,
            "actions": [
                self._automod_action_payload(action) for action in rule["actions"]
            ],
            "enabled": rule["enabled"],
            "exempt_roles": [
                str(self.roles[key]["id"]) for key in rule["exempt_roles"]
            ],
            "exempt_channels": [
                str(self.channels[key]["id"]) for key in rule["exempt_channels"]
            ],
        }

    def _reconcile_automod(self, existing: list[dict[str, Any]]) -> None:
        for rule in self.manifest["automod_rules"]:
            state_key = rule["key"]
            found = self._find_automod_rule(existing, rule)
            payload = self._automod_payload(rule)
            if found is None:
                self._record(f"create AutoMod rule {rule['name']!r}")
                if self.apply:
                    created = self.client.request(
                        "POST",
                        f"/guilds/{self.guild_id}/auto-moderation/rules",
                        payload,
                        reason=self._reason(
                            f"create AutoMod rule {rule['name']}"
                        ),
                    )
                    existing.append(created)
                    found = created
            elif not _contains_desired(found, payload):
                if int(found.get("trigger_type", 0)) != payload["trigger_type"]:
                    raise DiscordAPIError(
                        f"AutoMod rule {rule['name']!r} has immutable "
                        "trigger_type mismatch"
                    )
                self._record(f"update AutoMod rule {rule['name']!r}")
                if self.apply:
                    update_payload = dict(payload)
                    update_payload.pop("trigger_type")
                    found = self.client.request(
                        "PATCH",
                        f"/guilds/{self.guild_id}/auto-moderation/rules/"
                        f"{found['id']}",
                        update_payload,
                        reason=self._reason(
                            f"update AutoMod rule {rule['name']}"
                        ),
                    )
            if found is None:
                found = {
                    "id": f"planned-automod:{state_key}",
                    **payload,
                }
            self.automod_rules[state_key] = dict(found)


def inspect_current_server(
    client: DiscordClient,
    guild_id: str,
    manifest: Mapping[str, Any] | None = None,
    state: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Read a safe structural summary without mutating Discord."""
    guild = client.request("GET", f"/guilds/{guild_id}")
    roles = client.request("GET", f"/guilds/{guild_id}/roles")
    channels = client.request("GET", f"/guilds/{guild_id}/channels")
    automod = client.request(
        "GET",
        f"/guilds/{guild_id}/auto-moderation/rules",
    )
    if (
        not isinstance(guild, dict)
        or str(guild.get("id")) != guild_id
        or not isinstance(roles, list)
        or not isinstance(channels, list)
        or not isinstance(automod, list)
    ):
        raise DiscordAPIError("Discord returned malformed inspection data")

    channel_type_names = {value: key for key, value in CHANNEL_TYPES.items()}
    category_names = {
        str(channel.get("id")): str(channel.get("name", ""))
        for channel in channels
        if channel.get("type") == CHANNEL_TYPES["category"]
    }
    channel_names = {
        str(channel.get("id")): str(channel.get("name", ""))
        for channel in channels
    }
    state_resources = (
        state.get("resources", {})
        if isinstance(state, dict)
        and isinstance(state.get("resources", {}), dict)
        else {}
    )

    def management_status(
        kind: str,
        item: Mapping[str, Any],
    ) -> str:
        item_id = str(item.get("id"))
        item_name = str(item.get("name", ""))
        saved = state_resources.get(kind, {})
        if not isinstance(saved, dict):
            saved = {}
        saved_ids = {
            str(record.get("id"))
            for record in saved.values()
            if isinstance(record, dict) and record.get("id") is not None
        }
        if item_id in saved_ids:
            return "managed"
        if manifest is None:
            return "unmanaged"
        definitions: Sequence[Mapping[str, Any]]
        if kind == "roles":
            definitions = manifest["roles"]
            managed_names = {
                "@everyone",
                PROVISIONER_ROLE_NAME,
                *(str(definition["name"]) for definition in definitions),
            }
        else:
            definitions = manifest[kind]
            managed_names = {
                str(definition["name"]) for definition in definitions
            }
        if item_name in managed_names:
            return "managed"
        cleanup = manifest.get("cleanup", {})
        cleanup_definitions = (
            cleanup.get(kind, []) if isinstance(cleanup, dict) else []
        )
        if any(
            str(definition.get("id")) == item_id
            for definition in cleanup_definitions
            if isinstance(definition, dict)
        ):
            return "declared-obsolete"
        return "unmanaged"

    summary: dict[str, Any] = {
        "guild": {
            key: guild.get(key)
            for key in (
                "id",
                "name",
                "description",
                "features",
                "verification_level",
                "default_message_notifications",
                "explicit_content_filter",
                "mfa_level",
                "rules_channel_id",
                "public_updates_channel_id",
                "safety_alerts_channel_id",
            )
        },
        "roles": [
            {
                "id": str(role.get("id")),
                "name": role.get("name"),
                "position": role.get("position"),
                "managed": bool(role.get("managed", False)),
                "management": management_status("roles", role),
                "permissions": permission_names(
                    int(str(role.get("permissions", "0")))
                ),
            }
            for role in sorted(
                roles,
                key=lambda item: int(item.get("position", 0)),
                reverse=True,
            )
        ],
        "channels": [
            {
                "id": str(channel.get("id")),
                "name": channel.get("name"),
                "type": channel_type_names.get(
                    int(channel.get("type", -1)),
                    f"unknown:{channel.get('type')}",
                ),
                "category": category_names.get(str(channel.get("parent_id"))),
                "position": channel.get("position"),
                "management": management_status(
                    (
                        "categories"
                        if int(channel.get("type", -1))
                        == CHANNEL_TYPES["category"]
                        else "channels"
                    ),
                    channel,
                ),
            }
            for channel in sorted(
                channels,
                key=lambda item: (
                    int(item.get("position", 0)),
                    str(item.get("id", "")),
                ),
            )
        ],
        "automod_rules": [
            {
                "id": str(rule.get("id")),
                "name": rule.get("name"),
                "trigger_type": rule.get("trigger_type"),
                "enabled": bool(rule.get("enabled", False)),
            }
            for rule in automod
        ],
    }
    if "COMMUNITY" in guild.get("features", []):
        onboarding = client.request("GET", f"/guilds/{guild_id}/onboarding")
        if not isinstance(onboarding, dict):
            raise DiscordAPIError("Discord returned malformed onboarding data")
        summary["onboarding"] = {
            "enabled": bool(onboarding.get("enabled", False)),
            "mode": onboarding.get("mode"),
            "default_channels": [
                channel_names.get(str(channel_id), str(channel_id))
                for channel_id in onboarding.get("default_channel_ids", [])
            ],
            "prompts": [
                {
                    "title": prompt.get("title"),
                    "required": bool(prompt.get("required", False)),
                    "options": [
                        option.get("title")
                        for option in prompt.get("options", [])
                    ],
                }
                for prompt in onboarding.get("prompts", [])
            ],
        }
    else:
        summary["onboarding"] = {
            "enabled": False,
            "note": "Community is not enabled, so onboarding was not queried.",
        }
    return summary


def _default_manifest_path() -> Path:
    return (
        Path(__file__).resolve().parents[2]
        / "docs"
        / "community"
        / "discord"
        / "server.json"
    )


def _default_state_path() -> Path:
    return Path(__file__).resolve().parent / ".discord-state.json"


def _default_rollback_dir() -> Path:
    return Path(__file__).resolve().parent / ".discord-rollbacks"


@contextlib.contextmanager
def _exclusive_apply_lock(state_path: Path) -> Iterable[Path]:
    resolved_state_path = state_path.expanduser().resolve()
    lock_path = resolved_state_path.with_name(f"{resolved_state_path.name}.lock")
    descriptor: int | None = None
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(lock_path, flags, 0o600)
        os.fchmod(descriptor, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(descriptor)
            descriptor = None
            raise DiscordAPIError(
                f"another Discord apply is already using state {resolved_state_path}"
            ) from error
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        raise DiscordAPIError(
            f"could not lock Discord state {resolved_state_path}: "
            f"{error.strerror}"
        ) from error
    try:
        yield lock_path
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plan or apply CloudNow Discord server configuration. "
            "Dry-run is the default."
        )
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=_default_manifest_path(),
        help="manifest path (default: docs/community/discord/server.json)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform mutations; without this flag only a plan is printed",
    )
    parser.add_argument(
        "--bootstrap-from-administrator",
        action="store_true",
        help=(
            "explicitly allow temporary Administrator and create/assign the "
            "least-privilege CloudNow Provisioner role"
        ),
    )
    parser.add_argument(
        "--cleanup-obsolete",
        action="store_true",
        help=(
            "include exact ID/name/type obsolete targets declared by the "
            "manifest; deletion still requires --apply"
        ),
    )
    parser.add_argument(
        "--print-required-permissions",
        action="store_true",
        help="print the bot permission integer and exit; no credentials required",
    )
    parser.add_argument(
        "--invite-url",
        metavar="APPLICATION_ID",
        help="print a server-install URL for the Discord application and exit",
    )
    parser.add_argument(
        "--inspect",
        action="store_true",
        help="print the current server structure using GET requests only",
    )
    parser.add_argument(
        "--reason",
        default="CloudNow manifest provisioning",
        help="prefix recorded in the Discord audit log",
    )
    parser.add_argument(
        "--state",
        type=Path,
        default=_default_state_path(),
        help="local managed-ID state path",
    )
    parser.add_argument(
        "--rollback-dir",
        type=Path,
        default=_default_rollback_dir(),
        help="directory for redacted pre-apply snapshots",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    token = os.environ.get("DISCORD_BOT_TOKEN", "")
    guild_id = os.environ.get("DISCORD_GUILD_ID", "")
    try:
        manifest = load_manifest(args.manifest)
        required_permissions = required_bot_permissions(manifest)
        if args.print_required_permissions:
            print(required_permissions)
            print(", ".join(permission_names(required_permissions)))
            return 0
        if args.invite_url:
            if not re.fullmatch(r"\d{17,20}", args.invite_url):
                raise ManifestError("APPLICATION_ID must be a Discord snowflake")
            query = urllib.parse.urlencode(
                {
                    "client_id": args.invite_url,
                    "scope": "bot",
                    "permissions": str(required_permissions),
                    "integration_type": "0",
                }
            )
            print(f"https://discord.com/oauth2/authorize?{query}")
            return 0
        if not guild_id:
            raise ManifestError("DISCORD_GUILD_ID is required")
        if not re.fullmatch(r"\d{17,20}", guild_id):
            raise ManifestError("DISCORD_GUILD_ID must be a Discord snowflake")
        if not token:
            raise ManifestError("DISCORD_BOT_TOKEN is required")
        if args.inspect:
            if args.apply:
                raise ManifestError("--inspect and --apply cannot be combined")
            if args.cleanup_obsolete:
                raise ManifestError(
                    "--inspect and --cleanup-obsolete cannot be combined"
                )
        client = DiscordClient(token)

        def execute() -> int:
            state = load_state(args.state, guild_id)
            if args.inspect:
                print(
                    json.dumps(
                        inspect_current_server(
                            client,
                            guild_id,
                            manifest,
                            state,
                        ),
                        indent=2,
                    )
                )
                return 0
            provisioner = Provisioner(
                client,
                guild_id,
                manifest,
                apply=args.apply,
                audit_reason=args.reason,
                state=state,
                state_path=args.state,
                rollback_dir=args.rollback_dir,
                bootstrap_from_administrator=args.bootstrap_from_administrator,
                cleanup_obsolete=args.cleanup_obsolete,
            )
            actions = provisioner.run()
            if actions:
                if args.apply:
                    print(f"Applied {len(actions)} managed change(s).")
                else:
                    print(
                        f"Dry run complete: {len(actions)} change(s) planned. "
                        "Re-run with --apply to mutate Discord."
                    )
            else:
                print("Discord managed configuration is already current.")
            return 0

        if args.apply:
            with _exclusive_apply_lock(args.state):
                return execute()
        return execute()
    except (ManifestError, DiscordAPIError) as error:
        message = str(error)
        if token:
            message = message.replace(token, "[REDACTED]")
            message = message.replace(
                urllib.parse.quote(token, safe=""),
                "[REDACTED]",
            )
        print(f"error: {message}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
