#!/usr/bin/env python3
"""Provision the managed portion of the CloudNow Discord server.

The manifest is intentionally declarative and contains no Discord IDs or secrets.
Resources are matched by their stable names. The provisioner never deletes objects
and preserves permission overwrites, forum tags, onboarding prompts/options, and
AutoMod rules that are not represented in the manifest.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
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

KEY_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
TEXT_CHANNEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


class ManifestError(ValueError):
    """The local manifest is invalid or internally inconsistent."""


class DiscordAPIError(RuntimeError):
    """A Discord REST operation failed."""


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
    return bits


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

    permissions = apply_overwrites(
        permissions,
        categories[channel["category"]].get("overwrites", []),
    )
    return apply_overwrites(permissions, channel.get("overwrites", []))


def validate_manifest(manifest: Any) -> dict[str, Any]:
    """Validate the full manifest, including cross-resource references."""
    root = _expect_dict(manifest, "manifest")
    _reject_unknown(
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
    if root["manifest_version"] != 1:
        raise ManifestError("manifest.manifest_version must be 1")

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
    role_key_set = set(role_keys)

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
        ref = _validate_key(guild[key], f"manifest.guild.{key}")
        if ref not in channel_key_set:
            raise ManifestError(f"manifest.guild.{key} references unknown channel")

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
    if len(default_channels) != 7:
        raise ManifestError("manifest.onboarding.default_channels must contain 7 channels")
    if len(writable_defaults) != 5:
        raise ManifestError(
            "manifest.onboarding.writable_default_channels must contain 5 channels"
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
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
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
                if isinstance(parsed, dict):
                    code = parsed.get("code")
                    message = parsed.get("message")
                    detail = f"{code}: {message}" if code is not None else str(message)
                detail = detail.replace(self._token, "[REDACTED]")
                raise DiscordAPIError(
                    f"Discord API {method} {path} failed ({status}): {detail}"
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
        self.output = output
        self.actions: list[str] = []
        self.roles: dict[str, dict[str, Any]] = {}
        self.categories: dict[str, dict[str, Any]] = {}
        self.channels: dict[str, dict[str, Any]] = {}
        self.automod_rules: dict[str, dict[str, Any]] = {}
        self.bot_user_id: str | None = None
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
        if bot_permissions & PERMISSIONS["ADMINISTRATOR"]:
            raise DiscordAPIError(
                "the provisioning bot has ADMINISTRATOR; remove it and grant "
                "the documented least-privilege permission set"
            )
        missing = required_bot_permissions(self.manifest) & ~bot_permissions
        if missing:
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
            found = self._find_by_state_or_name(
                existing,
                kind="automod_rules",
                key=definition["key"],
                name=definition["name"],
                description="AutoMod rule",
            )
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

    def run(self) -> list[str]:
        guild = self.client.request("GET", f"/guilds/{self.guild_id}")
        if not isinstance(guild, dict) or str(guild.get("id")) != self.guild_id:
            raise DiscordAPIError("Discord returned an unexpected guild")
        if "COMMUNITY" not in guild.get("features", []):
            raise DiscordAPIError(
                "Community must already be enabled in Discord before provisioning"
            )

        existing_roles = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/roles",
        )
        existing_channels = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/channels",
        )
        onboarding = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/onboarding",
        )
        automod_rules = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/auto-moderation/rules",
        )
        if not isinstance(existing_roles, list) or not isinstance(
            existing_channels,
            list,
        ):
            raise DiscordAPIError("Discord returned malformed guild resources")
        if not isinstance(onboarding, dict) or not isinstance(automod_rules, list):
            raise DiscordAPIError("Discord returned malformed Community resources")
        self._preflight_bot(existing_roles)
        self._preflight_onboarding_capacity(onboarding)
        self._preflight_automod_capacity(automod_rules)

        if self.apply:
            self._write_rollback_snapshot(
                guild,
                existing_roles,
                existing_channels,
                onboarding,
                automod_rules,
            )

        self._reconcile_roles(existing_roles)
        self._reconcile_categories(existing_channels)
        self._reconcile_channels(existing_channels)
        self._reconcile_channel_order()
        self._reconcile_guild(guild)
        self._reconcile_onboarding(onboarding)
        self._reconcile_automod(automod_rules)
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
                "automatically executable rollback plan."
            ),
            "guild": guild_fields,
            "roles": everyone
            + self._managed_snapshot_objects(
                roles,
                "roles",
                self.manifest["roles"],
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
            "automod_rules": self._managed_snapshot_objects(
                automod_rules,
                "automod_rules",
                [
                    {"key": item["key"], "name": item["name"]}
                    for item in self.manifest["automod_rules"]
                ],
            ),
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
        self._reconcile_role_order()

    def _reconcile_role_order(self) -> None:
        desired_keys = [role["key"] for role in self.manifest["roles"]]
        if any("position" not in self.roles[key] for key in desired_keys):
            self._record("order managed roles from Server Admin through notifications")
            return
        current_keys = sorted(
            desired_keys,
            key=lambda key: (
                int(self.roles[key]["position"]),
                int(str(self.roles[key]["id"])),
            ),
            reverse=True,
        )
        if current_keys == desired_keys:
            return
        self._record("order managed roles from Server Admin through notifications")
        if not self.apply:
            return
        target_positions = sorted(
            (int(self.roles[key]["position"]) for key in desired_keys),
            reverse=True,
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
            reason=self._reason("order managed roles"),
        )
        if not isinstance(updated, list):
            raise DiscordAPIError("Discord returned malformed reordered roles")
        by_id = {str(role.get("id")): role for role in updated}
        for key in desired_keys:
            role_id = str(self.roles[key]["id"])
            if role_id in by_id:
                self.roles[key] = dict(by_id[role_id])

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
        if self.bot_user_id and everyone_deny & PERMISSIONS["VIEW_CHANNEL"]:
            result.append(
                {
                    "id": self.bot_user_id,
                    "type": 1,
                    "allow": str(PERMISSIONS["VIEW_CHANNEL"]),
                    "deny": "0",
                }
            )
        return result

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
                    found = self.client.request(
                        "POST",
                        f"/guilds/{self.guild_id}/channels",
                        payload,
                        reason=self._reason(f"create category {category['name']}"),
                    )
                    existing.append(found)
                    existing_categories.append(found)
                else:
                    found = {
                        "id": f"planned-category:{category['key']}",
                        **payload,
                    }
            else:
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
                        found = self.client.request(
                            "PATCH",
                            f"/channels/{found['id']}",
                            patch,
                            reason=self._reason(
                                f"update category {category['name']}"
                            ),
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
        if existing is not None:
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
            if len(merged_tags) > 20:
                raise DiscordAPIError(
                    f"forum {channel['name']!r} would exceed Discord's 20-tag "
                    "limit after preserving unmanaged tags"
                )
            payload["available_tags"] = merged_tags
        return payload

    def _reconcile_channels(self, existing: list[dict[str, Any]]) -> None:
        existing_channels = [
            item
            for item in existing
            if item.get("type") != CHANNEL_TYPES["category"]
        ]
        for channel in self.manifest["channels"]:
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
                    found = self.client.request(
                        "POST",
                        f"/guilds/{self.guild_id}/channels",
                        payload,
                        reason=self._reason(f"create channel {channel['name']}"),
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
                        found = self.client.request(
                            "PATCH",
                            f"/channels/{found['id']}",
                            patch,
                            reason=self._reason(f"update channel {channel['name']}"),
                        )
            self.channels[channel["key"]] = dict(found)

    def _reconcile_channel_order(self) -> None:
        if self.apply:
            refreshed = self.client.request(
                "GET",
                f"/guilds/{self.guild_id}/channels",
            )
            if not isinstance(refreshed, list):
                raise DiscordAPIError("Discord returned malformed refreshed channels")
            by_id = {str(channel.get("id")): channel for channel in refreshed}
            for resources in (self.categories, self.channels):
                for key, channel in resources.items():
                    channel_id = str(channel["id"])
                    if channel_id not in by_id:
                        raise DiscordAPIError(
                            f"managed channel {channel.get('name')!r} disappeared"
                        )
                    resources[key] = dict(by_id[channel_id])

        groups = [
            (
                [category["key"] for category in self.manifest["categories"]],
                self.categories,
            )
        ]
        for category in self.manifest["categories"]:
            keys = [
                channel["key"]
                for channel in self.manifest["channels"]
                if channel["category"] == category["key"]
            ]
            groups.append((keys, self.channels))

        payload: list[dict[str, Any]] = []
        for desired_keys, resources in groups:
            if len(desired_keys) < 2:
                continue
            if any(resources[key].get("position") is None for key in desired_keys):
                if self.apply:
                    raise DiscordAPIError(
                        "Discord omitted a managed channel sorting position"
                    )
                self._record("order managed categories and channels")
                return
            current_keys = sorted(
                desired_keys,
                key=lambda key: (
                    int(resources[key]["position"]),
                    str(resources[key]["id"]),
                ),
            )
            if current_keys == desired_keys:
                continue
            target_positions = sorted(
                int(resources[key]["position"]) for key in desired_keys
            )
            payload.extend(
                {
                    "id": str(resources[key]["id"]),
                    "position": target_positions[index],
                }
                for index, key in enumerate(desired_keys)
            )
        if not payload:
            return
        self._record("order managed categories and channels")
        if self.apply:
            self.client.request(
                "PATCH",
                f"/guilds/{self.guild_id}/channels",
                payload,
                reason=self._reason("order managed categories and channels"),
            )

    def _reconcile_guild(self, guild: Mapping[str, Any]) -> None:
        settings = self.manifest["guild"]
        payload = {
            "name": settings["name"],
            "description": settings["description"],
            "preferred_locale": settings["preferred_locale"],
            "verification_level": settings["verification_level"],
            "default_message_notifications": settings[
                "default_message_notifications"
            ],
            "explicit_content_filter": settings["explicit_content_filter"],
            "system_channel_flags": settings["system_channel_flags"],
            "rules_channel_id": str(
                self.channels[settings["rules_channel"]]["id"]
            ),
            "public_updates_channel_id": str(
                self.channels[settings["public_updates_channel"]]["id"]
            ),
            "safety_alerts_channel_id": str(
                self.channels[settings["safety_alerts_channel"]]["id"]
            ),
            "system_channel_id": str(
                self.channels[settings["system_channel"]]["id"]
            ),
        }
        if not _contains_desired(guild, payload):
            self._record("update guild safety settings and channel references")
            if self.apply:
                self.client.request(
                    "PATCH",
                    f"/guilds/{self.guild_id}",
                    payload,
                    reason=self._reason("update guild safety settings"),
                )

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
        prompt_positions: dict[str, int] = {}
        result: list[dict[str, Any]] = []
        for prompt in existing:
            title = str(prompt.get("title", ""))
            if title in prompt_positions:
                raise DiscordAPIError(
                    f"Discord onboarding has duplicate prompt title {title!r}"
                )
            prompt_positions[title] = len(result)
            result.append(self._onboarding_prompt_from_api(prompt))

        for desired_prompt in self.manifest["onboarding"]["prompts"]:
            title = desired_prompt["title"]
            prior = (
                result[prompt_positions[title]]
                if title in prompt_positions
                else None
            )
            prior_options = prior.get("options", []) if prior else []
            option_positions: dict[str, int] = {}
            merged_options: list[dict[str, Any]] = []
            for option in prior_options:
                option_title = str(option.get("title", ""))
                if option_title in option_positions:
                    raise DiscordAPIError(
                        f"Discord onboarding prompt {title!r} has duplicate "
                        f"option {option_title!r}"
                    )
                option_positions[option_title] = len(merged_options)
                merged_options.append(dict(option))
            for desired_option in desired_prompt["options"]:
                option_title = desired_option["title"]
                prior_option = (
                    merged_options[option_positions[option_title]]
                    if option_title in option_positions
                    else None
                )
                resolved = self._desired_onboarding_option(
                    desired_option,
                    prior_option,
                )
                if option_title in option_positions:
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

    def _reconcile_onboarding(self, current: Mapping[str, Any]) -> None:
        desired_default_ids = [
            str(self.channels[key]["id"])
            for key in self.manifest["onboarding"]["default_channels"]
        ]
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
        normalized_current = {
            "prompts": [
                self._onboarding_prompt_from_api(prompt)
                for prompt in current.get("prompts", [])
            ],
            "default_channel_ids": [
                str(value) for value in current.get("default_channel_ids", [])
            ],
            "enabled": bool(current.get("enabled", False)),
            "mode": int(current.get("mode", 0)),
        }
        if not _contains_desired(normalized_current, payload):
            self._record("update Community Onboarding")
            if self.apply:
                self.client.request(
                    "PUT",
                    f"/guilds/{self.guild_id}/onboarding",
                    payload,
                    reason=self._reason("update Community Onboarding"),
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
            found = self._find_by_state_or_name(
                existing,
                kind="automod_rules",
                key=state_key,
                name=rule["name"],
                description="AutoMod rule",
            )
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
        client = DiscordClient(token)
        if args.inspect:
            if args.apply:
                raise ManifestError("--inspect and --apply cannot be combined")
            print(json.dumps(inspect_current_server(client, guild_id), indent=2))
            return 0
        state = load_state(args.state, guild_id)
        provisioner = Provisioner(
            client,
            guild_id,
            manifest,
            apply=args.apply,
            audit_reason=args.reason,
            state=state,
            state_path=args.state,
            rollback_dir=args.rollback_dir,
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
