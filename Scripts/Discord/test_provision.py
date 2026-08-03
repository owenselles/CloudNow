#!/usr/bin/env python3
"""Focused standard-library tests for Discord provisioning safety."""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import os
import stat
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("provision.py")
SPEC = importlib.util.spec_from_file_location("cloudnow_discord_provision", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
provision = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provision)

REPOSITORY_ROOT = SCRIPT_PATH.parents[2]
MANIFEST_PATH = REPOSITORY_ROOT / "docs/community/discord/server.json"


class FakeResponse:
    def __init__(
        self,
        status: int,
        body: object,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.status = status
        self.headers = headers or {}
        self._body = (
            body
            if isinstance(body, bytes)
            else json.dumps(body).encode("utf-8")
        )

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def getcode(self) -> int:
        return self.status

    def read(self) -> bytes:
        return self._body


class ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = provision.load_manifest(MANIFEST_PATH)

    def test_full_pack_manifest_is_valid_and_complete(self) -> None:
        self.assertEqual(len(self.manifest["categories"]), 6)
        expected_channels = {
            "start-here",
            "rules",
            "announcements",
            "releases",
            "faq",
            "known-issues",
            "general",
            "introductions",
            "showcase",
            "feature-discussion",
            "off-topic",
            "help",
            "support-resources",
            "development",
            "contributing",
            "pull-requests",
            "testing",
            "localization",
            "community-projects",
            "Lounge",
            "Pair Debugging",
            "staff-chat",
            "mod-log",
            "automod-alerts",
            "security-response",
            "discord-updates",
        }
        self.assertEqual(
            {channel["name"] for channel in self.manifest["channels"]},
            expected_channels,
        )
        self.assertEqual(
            len(self.manifest["onboarding"]["default_channels"]),
            8,
        )
        self.assertEqual(
            len(self.manifest["onboarding"]["writable_default_channels"]),
            5,
        )

    def test_new_member_and_onboarding_role_access_matrix(self) -> None:
        channels = {
            channel["key"]: channel for channel in self.manifest["channels"]
        }
        categories = {
            category["key"]: category
            for category in self.manifest["categories"]
        }
        roles = {role["key"]: role for role in self.manifest["roles"]}

        def permissions_for(channel_key: str, role_key: str | None = None) -> int:
            channel = channels[channel_key]
            permissions = provision.permission_bits(
                self.manifest["everyone_permissions"]
            )
            if role_key is not None:
                permissions |= provision.permission_bits(
                    roles[role_key]["permissions"]
                )
            overwrites = provision.merge_manifest_overwrites(
                categories[channel["category"]]["overwrites"],
                channel["overwrites"],
            )
            everyone = next(
                (
                    overwrite
                    for overwrite in overwrites
                    if overwrite["target"] == "@everyone"
                ),
                None,
            )
            if everyone is not None:
                permissions &= ~provision.permission_bits(everyone["deny"])
                permissions |= provision.permission_bits(everyone["allow"])
            if role_key is not None:
                role_overwrite = next(
                    (
                        overwrite
                        for overwrite in overwrites
                        if overwrite["target"] == role_key
                    ),
                    None,
                )
                if role_overwrite is not None:
                    permissions &= ~provision.permission_bits(
                        role_overwrite["deny"]
                    )
                    permissions |= provision.permission_bits(
                        role_overwrite["allow"]
                    )
            return permissions

        view = provision.PERMISSIONS["VIEW_CHANNEL"]
        send = provision.PERMISSIONS["SEND_MESSAGES"]
        public = {
            key for key in channels if permissions_for(key) & view
        }
        writable = {
            key
            for key in public
            if permissions_for(key) & send
        }
        self.assertEqual(
            public,
            set(self.manifest["onboarding"]["default_channels"]),
        )
        self.assertEqual(
            writable,
            set(self.manifest["onboarding"]["writable_default_channels"]),
        )

        expected_hidden_access = {
            "support-interest": {
                "help",
                "support-resources",
                "known-issues",
                "faq",
            },
            "releases": {"releases-channel"},
            "developer-interest": {
                "development-channel",
                "contributing",
                "pull-requests",
                "community-projects",
            },
            "localization-interest": {"localization"},
            "voice-access": {"lounge", "pair-debugging"},
            "beta-updates": {"testing"},
            "project-status": set(),
            "community-events": set(),
        }
        hidden = set(channels) - public
        for role_key, expected in expected_hidden_access.items():
            accessible = {
                channel_key
                for channel_key in hidden
                if permissions_for(channel_key, role_key) & view
            }
            self.assertEqual(accessible, expected, role_key)

    def test_recognition_roles_have_no_permissions(self) -> None:
        roles = {role["name"]: role for role in self.manifest["roles"]}
        for name in ("Contributor", "Beta Tester", "Translator"):
            self.assertEqual(roles[name]["permissions"], [])
        self.assertIn("Localization Interest", roles)

    def test_duplicate_role_name_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["roles"][1]["name"] = manifest["roles"][0]["name"]
        with self.assertRaisesRegex(provision.ManifestError, "duplicates"):
            provision.validate_manifest(manifest)

    def test_duplicate_json_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.json"
            path.write_text('{"manifest_version": 1, "manifest_version": 1}', encoding="utf-8")
            with self.assertRaisesRegex(provision.ManifestError, "duplicate key"):
                provision.load_manifest(path)

    def test_administrator_permission_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["roles"][0]["permissions"].append("ADMINISTRATOR")
        with self.assertRaisesRegex(provision.ManifestError, "ADMINISTRATOR"):
            provision.validate_manifest(manifest)

    def test_everyone_administrator_permission_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["everyone_permissions"].append("ADMINISTRATOR")
        with self.assertRaisesRegex(provision.ManifestError, "ADMINISTRATOR"):
            provision.validate_manifest(manifest)

    def test_provisioner_role_identity_is_reserved(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["roles"][0]["key"] = provision.PROVISIONER_ROLE_KEY
        with self.assertRaisesRegex(provision.ManifestError, "reserved"):
            provision.validate_manifest(manifest)
        manifest = copy.deepcopy(self.manifest)
        manifest["roles"][0]["name"] = provision.PROVISIONER_ROLE_NAME
        with self.assertRaisesRegex(provision.ManifestError, "reserved"):
            provision.validate_manifest(manifest)

    def test_support_permissions_are_scoped_to_help(self) -> None:
        roles = {role["key"]: role for role in self.manifest["roles"]}
        channels = {
            channel["key"]: channel for channel in self.manifest["channels"]
        }
        self.assertEqual(roles["support-team"]["permissions"], [])
        support = next(
            overwrite
            for overwrite in channels["help"]["overwrites"]
            if overwrite["target"] == "support-team"
        )
        self.assertEqual(
            support["allow"],
            ["VIEW_CHANNEL", "MANAGE_THREADS"],
        )
        solved = next(
            tag
            for tag in channels["help"]["forum_tags"]
            if tag["name"] == "Solved"
        )
        self.assertFalse(solved["moderated"])

    def test_alert_only_rule_cannot_block(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        rule = next(
            item for item in manifest["automod_rules"] if item.get("alert_only")
        )
        rule["actions"].append({"type": "block_message"})
        with self.assertRaisesRegex(provision.ManifestError, "alert_only"):
            provision.validate_manifest(manifest)

    def test_only_one_keyword_preset_rule_is_allowed(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        duplicate = copy.deepcopy(manifest["automod_rules"][0])
        duplicate["key"] = "another-preset"
        duplicate["name"] = "Another Preset"
        manifest["automod_rules"].append(duplicate)
        with self.assertRaisesRegex(provision.ManifestError, "keyword_preset"):
            provision.validate_manifest(manifest)

    def test_onboarding_write_count_matches_permissions(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["onboarding"]["writable_default_channels"][0] = "announcements"
        with self.assertRaisesRegex(
            provision.ManifestError,
            "effectively read-only",
        ):
            provision.validate_manifest(manifest)

    def test_v2_channel_fields_are_validated_by_channel_type(self) -> None:
        channels = {
            channel["key"]: channel for channel in self.manifest["channels"]
        }
        self.assertTrue(channels["help"]["require_tag"])
        self.assertEqual(
            channels["help"]["default_thread_slowmode_seconds"],
            30,
        )
        self.assertEqual(channels["pair-debugging"]["user_limit"], 4)

        manifest = copy.deepcopy(self.manifest)
        text = next(
            channel
            for channel in manifest["channels"]
            if channel["type"] == "text"
        )
        text["require_tag"] = True
        with self.assertRaisesRegex(provision.ManifestError, "only valid for forums"):
            provision.validate_manifest(manifest)

        manifest = copy.deepcopy(self.manifest)
        voice = next(
            channel
            for channel in manifest["channels"]
            if channel["type"] == "voice"
        )
        voice["user_limit"] = 100
        with self.assertRaisesRegex(provision.ManifestError, "at most 99"):
            provision.validate_manifest(manifest)

    def test_guild_references_require_text_channels(self) -> None:
        self.assertIsNone(self.manifest["guild"]["system_channel"])
        for field in (
            "rules_channel",
            "public_updates_channel",
            "safety_alerts_channel",
            "system_channel",
        ):
            with self.subTest(field=field):
                manifest = copy.deepcopy(self.manifest)
                manifest["guild"][field] = "announcements"
                with self.assertRaisesRegex(
                    provision.ManifestError,
                    "must reference a text channel",
                ):
                    provision.validate_manifest(manifest)

    def test_v2_is_required_for_authoritative_features(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["manifest_version"] = 1
        with self.assertRaisesRegex(provision.ManifestError, "version 2"):
            provision.validate_manifest(manifest)

    def test_onboarding_cannot_self_assign_guild_permissions(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["onboarding"]["prompts"][0]["options"][0]["roles"].append(
            "moderator"
        )
        with self.assertRaisesRegex(
            provision.ManifestError,
            "self-assignable",
        ):
            provision.validate_manifest(manifest)

    def test_cleanup_requires_exact_safe_identifiers(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["cleanup"]["channels"][0]["id"] = "not-a-snowflake"
        with self.assertRaisesRegex(provision.ManifestError, "snowflake"):
            provision.validate_manifest(manifest)

        manifest = copy.deepcopy(self.manifest)
        manifest["cleanup"]["roles"][0]["migrate_to"] = "missing-role"
        with self.assertRaisesRegex(provision.ManifestError, "unknown managed role"):
            provision.validate_manifest(manifest)

        manifest = copy.deepcopy(self.manifest)
        manifest["cleanup"]["channels"][0]["name"] = manifest["channels"][0]["name"]
        with self.assertRaisesRegex(provision.ManifestError, "managed name"):
            provision.validate_manifest(manifest)

    def test_child_everyone_overwrite_replaces_parent_semantics(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        channel = manifest["channels"][0]
        category = next(
            item
            for item in manifest["categories"]
            if item["key"] == channel["category"]
        )
        category["overwrites"] = [
            {
                "target": "@everyone",
                "allow": [],
                "deny": ["SEND_MESSAGES"],
            }
        ]
        channel["overwrites"] = [
            {
                "target": "@everyone",
                "allow": ["VIEW_CHANNEL"],
                "deny": [],
            }
        ]
        effective = provision._everyone_channel_permissions(manifest, channel)
        self.assertTrue(effective & provision.PERMISSIONS["SEND_MESSAGES"])


class MergeTests(unittest.TestCase):
    def test_permission_overwrites_preserve_unmanaged_targets(self) -> None:
        existing = [
            {"id": "unmanaged", "type": 1, "allow": "4", "deny": "0"},
            {"id": "managed", "type": 0, "allow": "0", "deny": "1"},
        ]
        desired = [
            {"id": "managed", "type": 0, "allow": "2", "deny": "0"},
        ]
        merged = provision.merge_permission_overwrites(existing, desired)
        self.assertEqual(merged[0], existing[0])
        self.assertEqual(merged[1], desired[0])

    def test_channel_overwrites_replace_inherited_targets(self) -> None:
        inherited = [
            {"target": "@everyone", "allow": [], "deny": ["VIEW_CHANNEL"]},
            {"target": "moderator", "allow": ["VIEW_CHANNEL"], "deny": []},
        ]
        specific = [
            {"target": "@everyone", "allow": ["VIEW_CHANNEL"], "deny": []},
        ]
        merged = provision.merge_manifest_overwrites(inherited, specific)
        self.assertEqual(merged[0], specific[0])
        self.assertEqual(merged[1], inherited[1])

    def test_forum_tags_preserve_ids_and_unmanaged_tags(self) -> None:
        existing = [
            {
                "id": "42",
                "name": "Solved",
                "moderated": False,
                "emoji_id": None,
                "emoji_name": "☑️",
            },
            {
                "id": "99",
                "name": "Local tag",
                "moderated": False,
                "emoji_id": None,
                "emoji_name": None,
            },
        ]
        desired = [
            {
                "name": "Solved",
                "moderated": True,
                "emoji_id": None,
                "emoji_name": "✅",
            }
        ]
        merged = provision.merge_forum_tags(existing, desired)
        self.assertEqual(merged[0]["id"], "42")
        self.assertTrue(merged[0]["moderated"])
        self.assertEqual(merged[1], existing[1])

    def test_normalized_dict_lists_ignore_api_order(self) -> None:
        current = {
            "permission_overwrites": [
                {"id": "2", "allow": "1"},
                {"id": "1", "allow": "0"},
            ]
        }
        desired = {
            "permission_overwrites": [
                {"id": "1", "allow": "0"},
                {"id": "2", "allow": "1"},
            ]
        }
        self.assertTrue(provision._contains_desired(current, desired))


class DiscordClientTests(unittest.TestCase):
    def test_rate_limit_retries_using_retry_after(self) -> None:
        calls = 0
        sleeps: list[float] = []

        def opener(_request: object, timeout: int) -> FakeResponse:
            nonlocal calls
            self.assertEqual(timeout, 30)
            calls += 1
            if calls == 1:
                raise urllib.error.HTTPError(
                    "https://discord.com/api/v10/test",
                    429,
                    "rate limited",
                    {},
                    io.BytesIO(b'{"retry_after":0.25,"global":false}'),
                )
            return FakeResponse(200, {"ok": True})

        client = provision.DiscordClient(
            "test-token",
            opener=opener,
            sleeper=sleeps.append,
            clock=lambda: 0.0,
        )
        self.assertEqual(client.request("GET", "/test"), {"ok": True})
        self.assertEqual(calls, 2)
        self.assertEqual(sleeps, [0.25])

    def test_api_error_redacts_token(self) -> None:
        secret = "secret-token-value"

        def opener(_request: object, timeout: int) -> FakeResponse:
            self.assertEqual(timeout, 30)
            return FakeResponse(
                400,
                {"code": 50035, "message": f"invalid {secret}"},
            )

        client = provision.DiscordClient(secret, opener=opener)
        with self.assertRaises(provision.DiscordAPIError) as context:
            client.request("GET", "/test")
        self.assertNotIn(secret, str(context.exception))
        self.assertIn("[REDACTED]", str(context.exception))

    def test_audit_reason_is_sent_but_token_is_not_in_url(self) -> None:
        captured: list[object] = []

        def opener(request: object, timeout: int) -> FakeResponse:
            self.assertEqual(timeout, 30)
            captured.append(request)
            return FakeResponse(200, {"ok": True})

        client = provision.DiscordClient("private-token", opener=opener)
        client.request("PATCH", "/test", {"x": 1}, reason="CloudNow test")
        request = captured[0]
        self.assertNotIn("private-token", request.full_url)
        self.assertTrue(request.headers["User-agent"].startswith("DiscordBot ("))
        self.assertEqual(
            request.headers["X-audit-log-reason"],
            "CloudNow%20test",
        )


class ProvisionerPayloadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = provision.load_manifest(MANIFEST_PATH)
        self.instance = provision.Provisioner(
            client=None,
            guild_id="123456789012345678",
            manifest=self.manifest,
            apply=False,
            audit_reason="test",
            output=lambda _message: None,
        )
        self.instance.bot_user_id = "234567890123456789"
        self.instance.roles = {
            role["key"]: {
                "id": str(300000000000000000 + index),
                "name": role["name"],
            }
            for index, role in enumerate(self.manifest["roles"])
        }
        self.instance.categories = {
            category["key"]: {
                "id": str(400000000000000000 + index),
                "name": category["name"],
            }
            for index, category in enumerate(self.manifest["categories"])
        }
        self.instance.channels = {
            channel["key"]: {
                "id": str(500000000000000000 + index),
                "name": channel["name"],
            }
            for index, channel in enumerate(self.manifest["channels"])
        }

    def _channel(self, key: str) -> dict[str, object]:
        return next(
            channel
            for channel in self.manifest["channels"]
            if channel["key"] == key
        )

    def test_channel_payload_uses_discord_type_matrix(self) -> None:
        voice = self.instance._channel_payload(self._channel("lounge"), None)
        self.assertIn("nsfw", voice)
        self.assertIn("rate_limit_per_user", voice)
        self.assertNotIn("topic", voice)

        announcement = self.instance._channel_payload(
            self._channel("announcements"),
            None,
        )
        self.assertIn("topic", announcement)
        self.assertIn("nsfw", announcement)
        self.assertNotIn("rate_limit_per_user", announcement)

    def test_v2_forum_and_voice_fields_reconcile_without_clobbering_flags(
        self,
    ) -> None:
        forum = self.instance._channel_payload(
            self._channel("help"),
            {
                "flags": 1 << 1,
                "available_tags": [
                    {
                        "id": "42",
                        "name": "Solved",
                        "moderated": False,
                        "emoji_id": None,
                        "emoji_name": None,
                    },
                    {
                        "id": "99",
                        "name": "Obsolete",
                        "moderated": False,
                        "emoji_id": None,
                        "emoji_name": None,
                    },
                ],
                "permission_overwrites": [],
            },
        )
        self.assertEqual(
            forum["flags"],
            (1 << 1) | provision.CHANNEL_FLAG_REQUIRE_TAG,
        )
        self.assertEqual(forum["default_thread_rate_limit_per_user"], 30)
        self.assertNotIn(
            "Obsolete",
            {tag["name"] for tag in forum["available_tags"]},
        )
        solved = next(
            tag for tag in forum["available_tags"] if tag["name"] == "Solved"
        )
        self.assertEqual(solved["id"], "42")

        voice = self.instance._channel_payload(
            self._channel("pair-debugging"),
            None,
        )
        self.assertEqual(voice["user_limit"], 4)

    def test_authoritative_channel_overwrites_remove_unlisted_targets(
        self,
    ) -> None:
        payload = self.instance._channel_payload(
            self._channel("rules"),
            {
                "permission_overwrites": [
                    {
                        "id": "999999999999999999",
                        "type": 0,
                        "allow": "1",
                        "deny": "0",
                    }
                ]
            },
        )
        self.assertNotIn(
            "999999999999999999",
            {item["id"] for item in payload["permission_overwrites"]},
        )
        bot = next(
            item
            for item in payload["permission_overwrites"]
            if item["id"] == self.instance.bot_user_id
        )
        self.assertEqual(bot["allow"], str(provision.BOT_CHANNEL_PERMISSIONS))

    def test_category_write_fails_when_response_ignores_settings(self) -> None:
        category = next(
            item for item in self.manifest["categories"] if item["overwrites"]
        )
        self.instance.manifest = {
            **self.manifest,
            "categories": [category],
        }
        existing = [
            {
                "id": "410000000000000000",
                "name": category["name"],
                "type": provision.CHANNEL_TYPES["category"],
                "permission_overwrites": [],
            }
        ]

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PATCH":
                    return copy.deepcopy(existing[0])
                raise AssertionError(f"unexpected {method} {path}")

        self.instance.client = FakeClient()
        self.instance.apply = True
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "did not confirm",
        ):
            self.instance._reconcile_categories(existing)

    def test_channel_write_fails_when_refetch_ignores_settings(self) -> None:
        channel = self._channel("rules")
        self.instance.manifest = {
            **self.manifest,
            "channels": [channel],
        }
        existing_channel = {
            "id": "510000000000000000",
            "name": channel["name"],
            "type": provision.CHANNEL_TYPES[channel["type"]],
            "parent_id": str(
                self.instance.categories[channel["category"]]["id"]
            ),
            "topic": "stale",
            "permission_overwrites": [],
        }

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PATCH":
                    return {**copy.deepcopy(existing_channel), **payload}
                if method == "GET":
                    return copy.deepcopy(existing_channel)
                raise AssertionError(f"unexpected {method} {path}")

        self.instance.client = FakeClient()
        self.instance.apply = True
        self.instance.channels.pop(channel["key"])
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "did not persist",
        ):
            self.instance._reconcile_channels([existing_channel])

    def test_authoritative_onboarding_removes_unlisted_entries(self) -> None:
        desired = self.instance._merge_onboarding_prompts([])
        obsolete = {
            "id": "600000000000000001",
            "title": "Obsolete prompt",
            "type": 0,
            "single_select": True,
            "required": False,
            "in_onboarding": True,
            "options": [
                {
                    "id": "600000000000000002",
                    "title": "Obsolete option",
                    "description": "",
                    "channel_ids": [],
                    "role_ids": [],
                    "emoji_id": None,
                    "emoji_name": None,
                    "emoji_animated": False,
                }
            ],
        }
        merged = self.instance._merge_onboarding_prompts(
            [*desired, obsolete]
        )
        self.assertEqual(
            [prompt["title"] for prompt in merged],
            [
                prompt["title"]
                for prompt in self.manifest["onboarding"]["prompts"]
            ],
        )

        preserving_manifest = copy.deepcopy(self.manifest)
        preserving_manifest["authoritative"] = False
        self.instance.manifest = preserving_manifest
        preserved = self.instance._merge_onboarding_prompts(
            [*desired, obsolete]
        )
        self.assertIn(
            "Obsolete prompt",
            {prompt["title"] for prompt in preserved},
        )

    def test_authoritative_onboarding_capacity_ignores_removable_prompts(
        self,
    ) -> None:
        current = {
            "prompts": [
                {
                    "id": str(610000000000000000 + index),
                    "title": f"Obsolete {index}",
                    "options": [],
                }
                for index in range(5)
            ]
        }
        self.instance._preflight_onboarding_capacity(current)

    def test_authoritative_onboarding_defaults_are_exact(self) -> None:
        calls: list[tuple[str, object]] = []
        saved: dict[str, object] = {}

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, payload))
                if method == "PUT":
                    saved.update(copy.deepcopy(payload))
                return copy.deepcopy(saved)

        self.instance.client = FakeClient()
        self.instance.apply = True
        current = {
            "prompts": [],
            "default_channel_ids": ["999999999999999999"],
            "enabled": False,
            "mode": 0,
        }
        self.instance._reconcile_onboarding(current)
        payload = next(
            payload for method, payload in calls if method == "PUT"
        )
        expected = [
            str(self.instance.channels[key]["id"])
            for key in self.manifest["onboarding"]["default_channels"]
        ]
        self.assertEqual(payload["default_channel_ids"], expected)

    def test_onboarding_unordered_id_list_order_is_ignored(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["onboarding"]["prompts"][0]["options"][0]["roles"].append(
            "beta-updates"
        )
        self.instance.manifest = manifest
        desired = {
            "prompts": self.instance._merge_onboarding_prompts([]),
            "default_channel_ids": [
                str(self.instance.channels[key]["id"])
                for key in manifest["onboarding"]["default_channels"]
            ],
            "enabled": manifest["onboarding"]["enabled"],
            "mode": 0,
        }
        current = copy.deepcopy(desired)
        current["default_channel_ids"].reverse()
        for prompt in current["prompts"]:
            for option in prompt["options"]:
                option["channel_ids"].reverse()
                option["role_ids"].reverse()

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                raise AssertionError(f"unexpected {method} {path}")

        self.instance.client = FakeClient()
        self.instance.apply = True
        self.instance._reconcile_onboarding(current)

    def test_onboarding_verification_accepts_reordered_channel_ids(self) -> None:
        calls: list[str] = []
        saved: dict[str, object] = {}

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append(method)
                if method == "PUT":
                    saved.update(copy.deepcopy(payload))
                    saved["default_channel_ids"].reverse()
                    for prompt in saved["prompts"]:
                        for option in prompt["options"]:
                            option["channel_ids"].reverse()
                            option["role_ids"].reverse()
                return copy.deepcopy(saved)

        desired = self.instance._merge_onboarding_prompts([])
        self.instance.client = FakeClient()
        self.instance.apply = True
        self.instance._reconcile_onboarding(
            {
                "prompts": desired,
                "default_channel_ids": [
                    str(self.instance.channels[key]["id"])
                    for key in self.manifest["onboarding"][
                        "default_channels"
                    ]
                ],
                "enabled": not self.manifest["onboarding"]["enabled"],
                "mode": 0,
            }
        )
        self.assertEqual(calls, ["PUT", "GET"])

    def test_onboarding_accepts_discord_generated_option_id(self) -> None:
        desired = self.instance._merge_onboarding_prompts([])
        current = {
            "prompts": copy.deepcopy(desired),
            "default_channel_ids": [
                str(self.instance.channels[key]["id"])
                for key in self.manifest["onboarding"]["default_channels"]
            ],
            "enabled": self.manifest["onboarding"]["enabled"],
            "mode": 0,
        }
        current["prompts"][0]["options"].pop()
        sent_id: list[str] = []
        saved: dict[str, object] = {}
        assigned_id = "699999999999999999"

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PUT":
                    response = copy.deepcopy(payload)
                    sent_id.append(str(response["prompts"][0]["options"][-1]["id"]))
                    response["prompts"][0]["options"][-1]["id"] = assigned_id
                    saved.update(response)
                return copy.deepcopy(saved)

        self.instance.client = FakeClient()
        self.instance.apply = True
        self.instance._reconcile_onboarding(current)
        self.assertNotEqual(sent_id, [assigned_id])

    def test_onboarding_response_ids_must_be_present_and_unique(self) -> None:
        desired = {
            "prompts": self.instance._merge_onboarding_prompts([]),
            "default_channel_ids": [
                str(self.instance.channels[key]["id"])
                for key in self.manifest["onboarding"]["default_channels"]
            ],
            "enabled": self.manifest["onboarding"]["enabled"],
            "mode": 0,
        }
        missing = copy.deepcopy(desired)
        missing["prompts"][0]["options"][0].pop("id")
        duplicate = copy.deepcopy(desired)
        duplicate["prompts"][0]["options"][0]["id"] = duplicate["prompts"][0][
            "id"
        ]
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "option is missing its ID",
        ):
            self.instance._onboarding_comparison_state(
                missing,
                include_resource_ids=False,
            )
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "duplicate prompt or option IDs",
        ):
            self.instance._onboarding_comparison_state(
                duplicate,
                include_resource_ids=False,
            )

    def test_onboarding_refetch_must_preserve_returned_ids(self) -> None:
        desired = self.instance._merge_onboarding_prompts([])
        saved: dict[str, object] = {}

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PUT":
                    saved.update(copy.deepcopy(payload))
                    saved["prompts"][0]["options"][0]["id"] = (
                        "699999999999999998"
                    )
                    return copy.deepcopy(saved)
                refreshed = copy.deepcopy(saved)
                refreshed["prompts"][0]["options"][0]["id"] = (
                    "699999999999999997"
                )
                return refreshed

        self.instance.client = FakeClient()
        self.instance.apply = True
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "did not persist exact",
        ):
            self.instance._reconcile_onboarding(
                {
                    "prompts": desired,
                    "default_channel_ids": [
                        str(self.instance.channels[key]["id"])
                        for key in self.manifest["onboarding"][
                            "default_channels"
                        ]
                    ],
                    "enabled": not self.manifest["onboarding"]["enabled"],
                    "mode": 0,
                }
            )

    def test_onboarding_unordered_id_lists_preserve_duplicates(self) -> None:
        desired = {
            "prompts": self.instance._merge_onboarding_prompts([]),
            "default_channel_ids": [
                str(self.instance.channels[key]["id"])
                for key in self.manifest["onboarding"]["default_channels"]
            ],
            "enabled": self.manifest["onboarding"]["enabled"],
            "mode": 0,
        }
        cases = {
            "default channel": lambda value: value[
                "default_channel_ids"
            ].append(value["default_channel_ids"][0]),
            "option channel": lambda value: value["prompts"][0]["options"][0][
                "channel_ids"
            ].append(value["prompts"][0]["options"][0]["channel_ids"][0]),
            "option role": lambda value: value["prompts"][0]["options"][0][
                "role_ids"
            ].append(value["prompts"][0]["options"][0]["role_ids"][0]),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label):
                current = copy.deepcopy(desired)
                mutate(current)
                self.instance.actions.clear()
                self.instance.apply = False
                self.instance._reconcile_onboarding(current)
                self.assertEqual(
                    self.instance.actions,
                    ["update Community Onboarding"],
                )

    def test_onboarding_channel_id_membership_remains_exact(self) -> None:
        calls: list[str] = []
        saved: dict[str, object] = {}
        desired = self.instance._merge_onboarding_prompts([])
        desired[0]["options"][0]["channel_ids"].pop()

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append(method)
                if method == "PUT":
                    saved.update(copy.deepcopy(payload))
                return copy.deepcopy(saved)

        self.instance.client = FakeClient()
        self.instance.apply = True
        self.instance._reconcile_onboarding(
            {
                "prompts": desired,
                "default_channel_ids": [
                    str(self.instance.channels[key]["id"])
                    for key in self.manifest["onboarding"][
                        "default_channels"
                    ]
                ],
                "enabled": self.manifest["onboarding"]["enabled"],
                "mode": 0,
            }
        )
        self.assertEqual(calls, ["PUT", "GET"])

    def test_authoritative_onboarding_detects_prompt_and_option_order_drift(
        self,
    ) -> None:
        desired = self.instance._merge_onboarding_prompts([])
        cases = {
            "prompts": [*reversed(desired)],
            "options": [
                {
                    **prompt,
                    "options": (
                        [*reversed(prompt["options"])]
                        if len(prompt["options"]) > 1
                        else prompt["options"]
                    ),
                }
                for prompt in desired
            ],
        }
        for label, prompts in cases.items():
            with self.subTest(label=label):
                calls: list[str] = []
                saved: dict[str, object] = {}

                class FakeClient:
                    def request(
                        _self,
                        method: str,
                        path: str,
                        payload: object = None,
                        *,
                        reason: str | None = None,
                    ) -> object:
                        calls.append(method)
                        if method == "PUT":
                            saved.update(copy.deepcopy(payload))
                        return copy.deepcopy(saved)

                self.instance.client = FakeClient()
                self.instance.apply = True
                current = {
                    "prompts": prompts,
                    "default_channel_ids": [
                        str(self.instance.channels[key]["id"])
                        for key in self.manifest["onboarding"][
                            "default_channels"
                        ]
                    ],
                    "enabled": self.manifest["onboarding"]["enabled"],
                    "mode": 0,
                }
                self.instance._reconcile_onboarding(current)
                self.assertIn("PUT", calls)

    def test_onboarding_put_fails_when_refetch_has_wrong_order(self) -> None:
        desired = self.instance._merge_onboarding_prompts([])

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PUT":
                    return copy.deepcopy(payload)
                return {
                    **copy.deepcopy(payload_for_get),
                    "prompts": [*reversed(payload_for_get["prompts"])],
                }

        payload_for_get = {
            "prompts": desired,
            "default_channel_ids": [
                str(self.instance.channels[key]["id"])
                for key in self.manifest["onboarding"]["default_channels"]
            ],
            "enabled": self.manifest["onboarding"]["enabled"],
            "mode": 0,
        }
        self.instance.client = FakeClient()
        self.instance.apply = True
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "did not persist exact",
        ):
            self.instance._reconcile_onboarding(
                {
                    **copy.deepcopy(payload_for_get),
                    "enabled": not payload_for_get["enabled"],
                }
            )

    def test_onboarding_put_fails_when_response_has_wrong_order(self) -> None:
        desired = self.instance._merge_onboarding_prompts([])

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PUT":
                    return {
                        **copy.deepcopy(payload),
                        "prompts": [*reversed(payload["prompts"])],
                    }
                raise AssertionError(f"unexpected {method} {path}")

        self.instance.client = FakeClient()
        self.instance.apply = True
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "did not confirm exact",
        ):
            self.instance._reconcile_onboarding(
                {
                    "prompts": desired,
                    "default_channel_ids": [
                        str(self.instance.channels[key]["id"])
                        for key in self.manifest["onboarding"][
                            "default_channels"
                        ]
                    ],
                    "enabled": not self.manifest["onboarding"]["enabled"],
                    "mode": 0,
                }
            )

    def test_private_channels_keep_the_provisioning_bot_visible(self) -> None:
        payload = self.instance._channel_payload(
            self._channel("mod-log"),
            None,
        )
        overwrite = next(
            item
            for item in payload["permission_overwrites"]
            if item["id"] == self.instance.bot_user_id
        )
        self.assertEqual(overwrite["type"], 1)
        self.assertEqual(
            overwrite["allow"],
            str(provision.BOT_CHANNEL_PERMISSIONS),
        )

    def test_new_onboarding_prompts_and_options_get_stable_request_ids(self) -> None:
        first = self.instance._merge_onboarding_prompts([])
        ids = [
            str(item["id"])
            for prompt in first
            for item in [prompt, *prompt["options"]]
        ]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all(item.isdigit() for item in ids))
        self.assertEqual(self.instance._merge_onboarding_prompts(first), first)

    def test_automod_patch_omits_immutable_trigger_type(self) -> None:
        calls: list[tuple[str, str, object]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, path, payload))
                return {"id": "99", "name": "Common Flagged Words"}

        self.instance.client = FakeClient()
        self.instance.apply = True
        rule = self.manifest["automod_rules"][0]
        current = {
            "id": "99",
            **self.instance._automod_payload(rule),
            "enabled": not rule["enabled"],
        }
        self.instance._reconcile_automod([current])
        patch = next(payload for method, _path, payload in calls if method == "PATCH")
        self.assertNotIn("trigger_type", patch)

    def test_singleton_automod_rule_is_adopted_by_trigger_type(self) -> None:
        calls: list[tuple[str, str, object]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, path, payload))
                return {
                    "id": "99",
                    "name": "Spam Content",
                    "trigger_type": provision.AUTOMOD_TRIGGER_TYPES["spam"],
                }

        rule = next(
            item
            for item in self.manifest["automod_rules"]
            if item["trigger"]["type"] == "spam"
        )
        existing = {
            "id": "99",
            **self.instance._automod_payload(rule),
            "name": "Block Suspected Spam Content",
        }
        found = self.instance._find_automod_rule([existing], rule)
        self.assertEqual(found["id"], "99")
        self.instance._preflight_automod_capacity([existing])
        snapshot_rules = self.instance._managed_automod_snapshot_objects(
            [existing]
        )
        self.assertEqual([item["id"] for item in snapshot_rules], ["99"])

        self.instance.manifest = {
            **self.manifest,
            "automod_rules": [rule],
        }
        self.instance.client = FakeClient()
        self.instance.apply = True
        self.instance._reconcile_automod([existing])

        self.assertFalse(any(method == "POST" for method, _path, _body in calls))
        method, path, patch = calls[0]
        self.assertEqual(method, "PATCH")
        self.assertTrue(path.endswith("/auto-moderation/rules/99"))
        self.assertEqual(patch["name"], "Spam Content")
        self.assertNotIn("trigger_type", patch)


class StateAndSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = provision.load_manifest(MANIFEST_PATH)

    def test_state_rejects_a_different_guild(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.json"
            path.write_text(
                json.dumps(
                    {
                        "state_version": 1,
                        "guild_id": "111111111111111111",
                        "resources": {},
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(provision.ManifestError, "belongs to guild"):
                provision.load_state(path, "222222222222222222")

    def test_state_rejects_a_non_snowflake_resource_id(self) -> None:
        guild_id = "123456789012345678"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.json"
            path.write_text(
                json.dumps(
                    {
                        "state_version": 1,
                        "guild_id": guild_id,
                        "resources": {
                            "roles": {
                                "server-admin": {
                                    "id": "../../wrong",
                                    "name": "Server Admin",
                                }
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(provision.ManifestError, "invalid Discord ID"):
                provision.load_state(path, guild_id)

    def test_state_id_adopts_a_renamed_role(self) -> None:
        state = {
            "state_version": 1,
            "guild_id": "123456789012345678",
            "resources": {
                "roles": {
                    "server-admin": {"id": "77", "name": "Old Admin"},
                }
            },
        }
        instance = provision.Provisioner(
            client=None,
            guild_id=state["guild_id"],
            manifest=self.manifest,
            apply=False,
            audit_reason="test",
            state=state,
            output=lambda _message: None,
        )
        found = instance._find_by_state_or_name(
            [{"id": "77", "name": "Old Admin"}],
            kind="roles",
            key="server-admin",
            name="Server Admin",
            description="role",
        )
        self.assertEqual(found["id"], "77")

    def test_snapshot_is_private_and_redacts_secret_like_fields(self) -> None:
        guild_id = "123456789012345678"
        with tempfile.TemporaryDirectory() as temporary:
            rollback_dir = Path(temporary) / "rollbacks"
            output: list[str] = []
            instance = provision.Provisioner(
                client=None,
                guild_id=guild_id,
                manifest=self.manifest,
                apply=True,
                audit_reason="test",
                rollback_dir=rollback_dir,
                output=output.append,
            )
            instance._write_rollback_snapshot(
                {"id": guild_id, "name": "CloudNow", "secret_note": "hide-me"},
                [{"id": guild_id, "name": "@everyone"}],
                [],
                {"prompts": [], "access_token": "hide-me-too"},
                [],
            )
            paths = list(rollback_dir.glob("pre-apply-*.json"))
            self.assertEqual(len(paths), 1)
            snapshot_text = paths[0].read_text(encoding="utf-8")
            self.assertNotIn("hide-me", snapshot_text)
            snapshot = json.loads(snapshot_text)
            self.assertEqual(
                snapshot["onboarding"]["access_token"],
                "[REDACTED]",
            )
            mode = stat.S_IMODE(os.stat(paths[0]).st_mode)
            self.assertEqual(mode, 0o600)

    def test_private_json_fsyncs_parent_after_atomic_replace(self) -> None:
        events: list[str] = []
        real_replace = provision.os.replace

        def tracked_replace(source: object, target: object) -> None:
            events.append("replace")
            real_replace(source, target)

        def tracked_directory_fsync(path: Path) -> None:
            events.append(f"directory:{path.name}")

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state.json"
            with mock.patch.object(
                provision.os,
                "replace",
                side_effect=tracked_replace,
            ), mock.patch.object(
                provision,
                "_fsync_directory",
                side_effect=tracked_directory_fsync,
            ):
                provision._write_private_json(path, {"safe": True})

            self.assertEqual(
                events,
                ["replace", f"directory:{path.parent.name}"],
            )
            self.assertEqual(
                json.loads(path.read_text(encoding="utf-8")),
                {"safe": True},
            )
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


class InspectionTests(unittest.TestCase):
    def test_inspection_is_read_only_without_community(self) -> None:
        guild_id = "123456789012345678"
        calls: list[tuple[str, str]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, path))
                if path == f"/guilds/{guild_id}":
                    return {"id": guild_id, "name": "Existing", "features": []}
                if path.endswith("/roles"):
                    return []
                if path.endswith("/channels"):
                    return []
                if path.endswith("/auto-moderation/rules"):
                    return []
                raise AssertionError(path)

        summary = provision.inspect_current_server(FakeClient(), guild_id)
        self.assertEqual(summary["guild"]["name"], "Existing")
        self.assertIn("not enabled", summary["onboarding"]["note"])
        self.assertEqual({method for method, _path in calls}, {"GET"})

    def test_inspection_labels_managed_obsolete_and_unmanaged_objects(
        self,
    ) -> None:
        guild_id = "123456789012345678"
        manifest = provision.load_manifest(MANIFEST_PATH)

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if path == f"/guilds/{guild_id}":
                    return {"id": guild_id, "features": []}
                if path.endswith("/roles"):
                    return [
                        {
                            "id": guild_id,
                            "name": "@everyone",
                            "position": 0,
                            "permissions": "0",
                        },
                        {
                            "id": "1525110182453968936",
                            "name": "Tester",
                            "position": 1,
                            "permissions": "0",
                        },
                        {
                            "id": "999999999999999998",
                            "name": "Third-party",
                            "position": 2,
                            "permissions": "0",
                        },
                    ]
                if path.endswith("/channels"):
                    return []
                if path.endswith("/auto-moderation/rules"):
                    return []
                raise AssertionError(path)

        summary = provision.inspect_current_server(
            FakeClient(),
            guild_id,
            manifest,
            {},
        )
        statuses = {
            role["name"]: role["management"] for role in summary["roles"]
        }
        self.assertEqual(statuses["@everyone"], "managed")
        self.assertEqual(statuses["Tester"], "declared-obsolete")
        self.assertEqual(statuses["Third-party"], "unmanaged")


class AdministratorBootstrapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = provision.load_manifest(MANIFEST_PATH)
        self.guild_id = "123456789012345678"
        self.bot_id = "234567890123456789"
        self.bot_role_id = "345678901234567890"
        self.provisioner_role_id = "456789012345678901"
        self.everyone = {
            "id": self.guild_id,
            "name": "@everyone",
            "permissions": "0",
            "position": 0,
        }
        self.admin_role = {
            "id": self.bot_role_id,
            "name": "CloudNow Bot",
            "permissions": str(provision.PERMISSIONS["ADMINISTRATOR"]),
            "position": 10,
            "managed": True,
        }

    def _instance(
        self,
        client: object,
        *,
        apply: bool,
        bootstrap: bool,
    ) -> provision.Provisioner:
        return provision.Provisioner(
            client,
            self.guild_id,
            self.manifest,
            apply=apply,
            audit_reason="test",
            bootstrap_from_administrator=bootstrap,
            output=lambda _message: None,
        )

    def test_administrator_is_rejected_without_explicit_bootstrap(self) -> None:
        outer = self

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if path == "/users/@me":
                    return {"id": outer.bot_id, "bot": True}
                if path.endswith(f"/members/{outer.bot_id}"):
                    return {"roles": [outer.bot_role_id]}
                raise AssertionError(f"unexpected {method} {path}")

        instance = self._instance(
            FakeClient(),
            apply=False,
            bootstrap=False,
        )
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "--bootstrap-from-administrator",
        ):
            instance._preflight_bot([self.everyone, self.admin_role])

    def test_bootstrap_dry_run_plans_role_without_mutations(self) -> None:
        outer = self
        methods: list[str] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                methods.append(method)
                if path == "/users/@me":
                    return {"id": outer.bot_id, "bot": True}
                if path.endswith(f"/members/{outer.bot_id}"):
                    return {"roles": [outer.bot_role_id]}
                raise AssertionError(f"unexpected {method} {path}")

        instance = self._instance(
            FakeClient(),
            apply=False,
            bootstrap=True,
        )
        roles = [self.everyone, self.admin_role]
        instance._preflight_bot(roles)
        instance._reconcile_provisioner_role(roles)

        self.assertEqual(set(methods), {"GET"})
        self.assertIn(
            "create role 'CloudNow Provisioner'",
            instance.actions,
        )
        self.assertIn(
            "assign role 'CloudNow Provisioner' to provisioning bot",
            instance.actions,
        )
        permissions = int(
            instance.roles[provision.PROVISIONER_ROLE_KEY]["permissions"]
        )
        self.assertEqual(
            permissions,
            provision.required_bot_permissions(self.manifest),
        )
        self.assertFalse(
            permissions & provision.PERMISSIONS["ADMINISTRATOR"]
        )

    def test_bootstrap_apply_creates_positions_and_assigns_role(self) -> None:
        outer = self
        calls: list[tuple[str, str, object]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, path, payload))
                if path == "/users/@me":
                    return {"id": outer.bot_id, "bot": True}
                if path.endswith(f"/members/{outer.bot_id}"):
                    return {"roles": [outer.bot_role_id]}
                if method == "POST" and path.endswith("/roles"):
                    return {
                        "id": outer.provisioner_role_id,
                        "position": 1,
                        **outer._instance(
                            _self,
                            apply=True,
                            bootstrap=True,
                        )._provisioner_role_payload(),
                    }
                if method == "GET" and path.endswith("/roles"):
                    return [
                        outer.everyone,
                        {
                            "id": outer.provisioner_role_id,
                            "name": provision.PROVISIONER_ROLE_NAME,
                            "permissions": str(
                                provision.required_bot_permissions(
                                    outer.manifest
                                )
                            ),
                            "position": 1,
                            "managed": False,
                        },
                        {**outer.admin_role, "position": 11},
                    ]
                if method == "PATCH" and path.endswith("/roles"):
                    return [
                        outer.everyone,
                        {
                            "id": outer.provisioner_role_id,
                            "name": provision.PROVISIONER_ROLE_NAME,
                            "permissions": str(
                                provision.required_bot_permissions(
                                    outer.manifest
                                )
                            ),
                            "position": 10,
                            "managed": False,
                        },
                        {**outer.admin_role, "position": 11},
                    ]
                if method == "PUT" and path.endswith(
                    f"/members/{outer.bot_id}/roles/"
                    f"{outer.provisioner_role_id}"
                ):
                    return None
                raise AssertionError(f"unexpected {method} {path}")

        instance = self._instance(
            FakeClient(),
            apply=True,
            bootstrap=True,
        )
        roles = [self.everyone, self.admin_role]
        instance._preflight_bot(roles)
        instance._reconcile_provisioner_role(roles)

        methods = [method for method, _path, _payload in calls]
        self.assertIn("POST", methods)
        self.assertNotIn("PATCH", methods)
        self.assertIn("PUT", methods)
        self.assertNotIn("DELETE", methods)
        self.assertFalse(
            any(
                method == "PATCH" and path.endswith(f"/roles/{self.bot_role_id}")
                for method, path, _payload in calls
            )
        )
        self.assertIn(
            self.provisioner_role_id,
            instance.bot_role_ids,
        )

    def test_bootstrap_is_idempotent_when_role_is_already_assigned(self) -> None:
        outer = self
        calls: list[tuple[str, str]] = []
        provisioner_role = {
            "id": self.provisioner_role_id,
            "position": 9,
            "managed": False,
            "name": provision.PROVISIONER_ROLE_NAME,
            "permissions": str(
                provision.required_bot_permissions(self.manifest)
            ),
            "color": provision.PROVISIONER_ROLE_COLOR,
            "hoist": False,
            "mentionable": False,
        }
        roles = [self.everyone, provisioner_role, self.admin_role]

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, path))
                if path == "/users/@me":
                    return {"id": outer.bot_id, "bot": True}
                if path.endswith(f"/members/{outer.bot_id}"):
                    return {
                        "roles": [
                            outer.bot_role_id,
                            outer.provisioner_role_id,
                        ]
                    }
                if method == "GET" and path.endswith("/roles"):
                    return roles
                raise AssertionError(f"unexpected {method} {path}")

        instance = self._instance(
            FakeClient(),
            apply=True,
            bootstrap=True,
        )
        instance._preflight_bot(roles)
        instance._reconcile_provisioner_role(roles)
        self.assertEqual({method for method, _path in calls}, {"GET"})
        self.assertEqual(instance.actions, [])

    def test_community_enablement_preserves_existing_features(self) -> None:
        instance = self._instance(
            client=None,
            apply=False,
            bootstrap=True,
        )
        instance.bot_has_administrator = True
        settings = self.manifest["guild"]
        instance.channels = {
            settings["rules_channel"]: {"id": "567890123456789012"},
            settings["public_updates_channel"]: {
                "id": "678901234567890123"
            },
        }
        updated = instance._enable_community(
            {
                "id": self.guild_id,
                "features": ["INVITES_DISABLED"],
            }
        )
        self.assertEqual(
            updated["features"],
            ["COMMUNITY", "INVITES_DISABLED"],
        )
        self.assertEqual(
            updated["rules_channel_id"],
            "567890123456789012",
        )
        self.assertEqual(
            updated["public_updates_channel_id"],
            "678901234567890123",
        )


class AuthoritativeOrderingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = provision.load_manifest(MANIFEST_PATH)
        self.guild_id = "123456789012345678"
        self.admin_role_id = "223456789012345678"
        self.provisioner_role_id = "323456789012345678"

    def _role_order_fixture(
        self,
        *,
        swap_first_managed_roles: bool,
    ) -> tuple[
        provision.Provisioner,
        list[dict[str, object]],
        list[str],
    ]:
        existing: list[dict[str, object]] = [
            {
                "id": self.guild_id,
                "name": "@everyone",
                "position": 0,
            },
            {
                "id": self.admin_role_id,
                "name": "Temporary Admin",
                "position": 60,
            },
            {
                "id": self.provisioner_role_id,
                "name": provision.PROVISIONER_ROLE_NAME,
                "position": 55,
            },
            {
                "id": "423456789012345678",
                "name": "Assistant",
                "position": 54,
                "managed": True,
            },
            {
                "id": "433456789012345678",
                "name": "Tester",
                "position": 52,
            },
        ]
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=self.manifest,
            apply=True,
            audit_reason="test",
            bootstrap_from_administrator=True,
            output=lambda _message: None,
        )
        instance.bot_role_ids = {
            self.admin_role_id,
            self.provisioner_role_id,
        }
        instance.roles[provision.PROVISIONER_ROLE_KEY] = dict(existing[2])
        role_positions = [
            53 - (2 * index)
            for index in range(len(self.manifest["roles"]))
        ]
        if swap_first_managed_roles:
            role_positions[0], role_positions[1] = (
                role_positions[1],
                role_positions[0],
            )
        desired_ids = [self.provisioner_role_id]
        for index, definition in enumerate(self.manifest["roles"]):
            role_id = str(500000000000000000 + index)
            role = {
                "id": role_id,
                "name": definition["name"],
                "position": role_positions[index],
            }
            existing.append(role)
            instance.roles[definition["key"]] = dict(role)
            desired_ids.append(role_id)
        return instance, existing, desired_ids

    def test_correct_gapped_role_hierarchy_is_idempotent(self) -> None:
        instance, existing, _desired_ids = self._role_order_fixture(
            swap_first_managed_roles=False,
        )

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_role_order(existing)
        self.assertEqual(instance.actions, [])

    def test_wrong_interleaved_order_reuses_managed_slots(self) -> None:
        calls: list[tuple[str, str, object]] = []
        instance, existing, desired_ids = self._role_order_fixture(
            swap_first_managed_roles=True,
        )
        original_slots = sorted(
            (
                int(instance.roles[key]["position"])
                for key in [
                    provision.PROVISIONER_ROLE_KEY,
                    *(role["key"] for role in self.manifest["roles"]),
                ]
            ),
            reverse=True,
        )
        corrected = copy.deepcopy(existing)
        corrected_by_id = {
            str(role["id"]): role for role in corrected
        }
        corrected_by_id["423456789012345678"]["position"] = 57
        corrected_by_id["433456789012345678"]["position"] = 55
        for index, role_id in enumerate(desired_ids):
            corrected_by_id[role_id]["position"] = 58 - (2 * index)

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, path, payload))
                if method == "PATCH":
                    return existing
                if method == "GET":
                    return corrected
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_role_order(existing)
        payload = next(
            value for method, _path, value in calls if method == "PATCH"
        )
        self.assertIsInstance(payload, list)
        assert isinstance(payload, list)
        self.assertEqual(
            [str(item["id"]) for item in payload],
            desired_ids,
        )
        self.assertEqual(
            [int(item["position"]) for item in payload],
            original_slots,
        )
        self.assertNotIn("423456789012345678", desired_ids)
        self.assertNotIn("433456789012345678", desired_ids)
        self.assertEqual(
            instance.actions,
            [
                "order CloudNow Provisioner and managed roles by relative "
                "hierarchy"
            ],
        )

    def test_wrong_reordered_response_fails_closed(self) -> None:
        instance, existing, desired_ids = self._role_order_fixture(
            swap_first_managed_roles=True,
        )
        wrong_response = copy.deepcopy(existing)
        wrong_by_id = {
            str(role["id"]): role for role in wrong_response
        }
        for index, role_id in enumerate(desired_ids):
            wrong_by_id[role_id]["position"] = 58 - (2 * index)
        wrong_by_id[desired_ids[2]]["position"] = int(
            wrong_by_id[desired_ids[1]]["position"]
        )

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PATCH":
                    return existing
                if method == "GET":
                    return wrong_response
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "requested managed role hierarchy",
        ):
            instance._reconcile_role_order(existing)

    def test_reordered_response_missing_managed_role_fails_closed(self) -> None:
        instance, existing, desired_ids = self._role_order_fixture(
            swap_first_managed_roles=True,
        )
        missing_response = [
            role
            for role in existing
            if str(role["id"]) != desired_ids[-1]
        ]

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PATCH":
                    return existing
                if method == "GET":
                    return missing_response
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "disappeared while ordering",
        ):
            instance._reconcile_role_order(existing)

    def _channel_order_fixture(
        self,
        *,
        apply: bool,
        category_positions: tuple[int, int] = (2, 9),
        information_positions: tuple[int, int, int] = (4, 4, 11),
        community_positions: tuple[int, int] = (1, 8),
        information_ids: tuple[str, str, str] = (
            "700000000000000001",
            "700000000000000002",
            "700000000000000003",
        ),
    ) -> tuple[
        provision.Provisioner,
        list[dict[str, object]],
        dict[str, list[str]],
    ]:
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=self.manifest,
            apply=apply,
            audit_reason="test",
            output=lambda _message: None,
        )
        instance.manifest = {
            **self.manifest,
            "categories": [
                {"key": "information"},
                {"key": "community"},
            ],
            "channels": [
                {"key": "rules", "category": "information"},
                {"key": "announcements", "category": "information"},
                {"key": "releases", "category": "information"},
                {"key": "general", "category": "community"},
                {"key": "introductions", "category": "community"},
            ],
        }
        category_ids = {
            "information": "600000000000000001",
            "community": "600000000000000002",
        }
        channel_ids = {
            "rules": information_ids[0],
            "announcements": information_ids[1],
            "releases": information_ids[2],
            "general": "700000000000000004",
            "introductions": "700000000000000005",
        }
        instance.categories = {
            key: {
                "id": category_ids[key],
                "name": key.upper(),
                "type": provision.CHANNEL_TYPES["category"],
                "position": category_positions[index],
            }
            for index, key in enumerate(("information", "community"))
        }
        positions = {
            "rules": information_positions[0],
            "announcements": information_positions[1],
            "releases": information_positions[2],
            "general": community_positions[0],
            "introductions": community_positions[1],
        }
        parents = {
            "rules": category_ids["information"],
            "announcements": category_ids["information"],
            "releases": category_ids["information"],
            "general": category_ids["community"],
            "introductions": category_ids["community"],
        }
        instance.channels = {
            key: {
                "id": channel_id,
                "name": key,
                "type": provision.CHANNEL_TYPES["text"],
                "position": positions[key],
                "parent_id": parents[key],
            }
            for key, channel_id in channel_ids.items()
        }
        current = [
            *copy.deepcopy(list(instance.categories.values())),
            *copy.deepcopy(list(instance.channels.values())),
            {
                "id": "800000000000000001",
                "name": "EXTERNAL",
                "type": provision.CHANNEL_TYPES["category"],
                "position": 6,
            },
            {
                "id": "800000000000000002",
                "name": "external",
                "type": provision.CHANNEL_TYPES["text"],
                "position": 7,
                "parent_id": category_ids["information"],
            },
        ]
        return instance, current, {
            "categories": list(category_ids.values()),
            "information": [
                channel_ids["rules"],
                channel_ids["announcements"],
                channel_ids["releases"],
            ],
            "community": [
                channel_ids["general"],
                channel_ids["introductions"],
            ],
            "external": [
                "800000000000000001",
                "800000000000000002",
            ],
        }

    def test_channel_order_bulk_patch_is_positions_only(self) -> None:
        instance, current, ids = self._channel_order_fixture(
            apply=True,
            information_ids=(
                "700000000000000003",
                "700000000000000001",
                "700000000000000002",
            ),
        )
        corrected = copy.deepcopy(current)
        corrected_by_id = {
            str(channel["id"]): channel for channel in corrected
        }
        for channel_id, position in zip(
            ids["information"],
            (4, 9, 14),
        ):
            corrected_by_id[channel_id]["position"] = position
        calls: list[tuple[str, str, object]] = []
        get_count = 0

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                nonlocal get_count
                calls.append((method, path, payload))
                if method == "GET":
                    get_count += 1
                    return current if get_count == 1 else corrected
                if method == "PATCH":
                    assert isinstance(payload, list)
                    if any("parent_id" in item for item in payload):
                        raise provision.DiscordAPIError(
                            "Only one channel can have a parent_id modified",
                            status=400,
                            code=40009,
                        )
                    return current
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_channel_order()
        payload = next(
            value for method, _path, value in calls if method == "PATCH"
        )
        self.assertIsInstance(payload, list)
        assert isinstance(payload, list)
        self.assertEqual(
            [str(item["id"]) for item in payload],
            ids["information"],
        )
        self.assertEqual(
            [int(item["position"]) for item in payload],
            [4, 5, 11],
        )
        self.assertTrue(all("parent_id" not in item for item in payload))
        payload_ids = {str(item["id"]) for item in payload}
        self.assertTrue(payload_ids.isdisjoint(ids["categories"]))
        self.assertTrue(payload_ids.isdisjoint(ids["community"]))
        self.assertTrue(payload_ids.isdisjoint(ids["external"]))
        self.assertEqual(
            instance.actions,
            ["order managed categories and channels"],
        )

    def test_channel_order_reuses_unique_gapped_slots(self) -> None:
        instance, current, ids = self._channel_order_fixture(
            apply=True,
            information_positions=(11, 3, 8),
        )
        corrected = copy.deepcopy(current)
        corrected_by_id = {
            str(channel["id"]): channel for channel in corrected
        }
        for channel_id, position in zip(ids["information"], (3, 8, 11)):
            corrected_by_id[channel_id]["position"] = position
        payloads: list[list[dict[str, object]]] = []
        get_count = 0

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                nonlocal get_count
                if method == "GET":
                    get_count += 1
                    return current if get_count == 1 else corrected
                if method == "PATCH":
                    assert isinstance(payload, list)
                    payloads.append(payload)
                    return current
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_channel_order()
        self.assertEqual(
            [int(item["position"]) for item in payloads[0]],
            [3, 8, 11],
        )

    def test_correct_gapped_channel_order_is_idempotent(self) -> None:
        instance, _current, _ids = self._channel_order_fixture(
            apply=False,
            information_positions=(2, 7, 12),
            community_positions=(1, 9),
        )

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_channel_order()
        self.assertEqual(instance.actions, [])

    def test_correct_channel_id_tie_order_is_idempotent(self) -> None:
        instance, _current, _ids = self._channel_order_fixture(
            apply=False,
            information_positions=(4, 4, 11),
        )

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_channel_order()
        self.assertEqual(instance.actions, [])

    def test_tied_channel_order_response_fails_closed(self) -> None:
        instance, current, _ids = self._channel_order_fixture(
            apply=True,
            information_ids=(
                "700000000000000003",
                "700000000000000001",
                "700000000000000002",
            ),
        )
        get_count = 0

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                nonlocal get_count
                if method == "GET":
                    get_count += 1
                    return current
                if method == "PATCH":
                    return current
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "strict relative managed",
        ):
            instance._reconcile_channel_order()

    def test_channel_parent_mismatch_fails_before_bulk_order(self) -> None:
        instance, current, ids = self._channel_order_fixture(apply=True)
        current_by_id = {
            str(channel["id"]): channel for channel in current
        }
        current_by_id[ids["information"][1]]["parent_id"] = (
            "800000000000000001"
        )
        methods: list[str] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                methods.append(method)
                if method == "GET":
                    return current
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "configured parent",
        ):
            instance._reconcile_channel_order()
        self.assertEqual(methods, ["GET"])

    def test_guild_patch_fails_closed_when_discord_ignores_a_field(self) -> None:
        settings = self.manifest["guild"]
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=self.manifest,
            apply=True,
            audit_reason="test",
            output=lambda _message: None,
        )
        instance.channels = {
            channel["key"]: {
                "id": str(800000000000000000 + index),
                "name": channel["name"],
            }
            for index, channel in enumerate(self.manifest["channels"])
        }
        desired_updates_id = str(
            instance.channels[settings["public_updates_channel"]]["id"]
        )
        patched: dict[str, object] = {}

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PATCH":
                    patched.update(payload)
                    return {"id": self.guild_id, **payload}
                if method == "GET":
                    return {
                        "id": self.guild_id,
                        **patched,
                        "public_updates_channel_id": "999999999999999999",
                    }
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        current = {
            "id": self.guild_id,
            "name": "Old",
            "public_updates_channel_id": "999999999999999999",
        }
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "did not persist",
        ):
            instance._reconcile_guild(current)
        self.assertNotEqual(
            desired_updates_id,
            "999999999999999999",
        )

    def test_guild_reference_patch_is_isolated(self) -> None:
        settings = self.manifest["guild"]
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=self.manifest,
            apply=True,
            audit_reason="test",
            output=lambda _message: None,
        )
        instance.channels = {
            channel["key"]: {
                "id": str(800000000000000000 + index),
                "name": channel["name"],
            }
            for index, channel in enumerate(self.manifest["channels"])
        }
        desired_refs = {
            "rules_channel_id": instance.channels[
                settings["rules_channel"]
            ]["id"],
            "public_updates_channel_id": instance.channels[
                settings["public_updates_channel"]
            ]["id"],
            "safety_alerts_channel_id": instance.channels[
                settings["safety_alerts_channel"]
            ]["id"],
            "system_channel_id": None,
        }
        current: dict[str, object] = {
            "id": self.guild_id,
            "name": settings["name"],
            "description": settings["description"],
            "preferred_locale": settings["preferred_locale"],
            "verification_level": settings["verification_level"],
            "default_message_notifications": settings[
                "default_message_notifications"
            ],
            "explicit_content_filter": settings["explicit_content_filter"],
            "system_channel_flags": settings["system_channel_flags"],
            **desired_refs,
            "public_updates_channel_id": "999999999999999999",
        }
        patches: list[dict[str, object]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PATCH":
                    self.assertIsInstance(payload, dict)
                    patches.append(copy.deepcopy(payload))
                    current.update(payload)
                    return copy.deepcopy(current)
                if method == "GET":
                    return copy.deepcopy(current)
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_guild(current)

        self.assertEqual(
            patches,
            [{
                "public_updates_channel_id": desired_refs[
                    "public_updates_channel_id"
                ]
            }],
        )
        self.assertEqual(
            instance.actions,
            ["update guild reference 'public_updates_channel_id'"],
        )

    def test_guild_scalar_patch_excludes_channel_references(self) -> None:
        settings = self.manifest["guild"]
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=self.manifest,
            apply=True,
            audit_reason="test",
            output=lambda _message: None,
        )
        instance.channels = {
            channel["key"]: {
                "id": str(800000000000000000 + index),
                "name": channel["name"],
            }
            for index, channel in enumerate(self.manifest["channels"])
        }
        current: dict[str, object] = {
            "id": self.guild_id,
            "name": "Old name",
            "description": settings["description"],
            "preferred_locale": settings["preferred_locale"],
            "verification_level": settings["verification_level"],
            "default_message_notifications": settings[
                "default_message_notifications"
            ],
            "explicit_content_filter": settings["explicit_content_filter"],
            "system_channel_flags": settings["system_channel_flags"],
            "rules_channel_id": instance.channels[
                settings["rules_channel"]
            ]["id"],
            "public_updates_channel_id": instance.channels[
                settings["public_updates_channel"]
            ]["id"],
            "safety_alerts_channel_id": instance.channels[
                settings["safety_alerts_channel"]
            ]["id"],
            "system_channel_id": None,
        }
        patches: list[dict[str, object]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if method == "PATCH":
                    self.assertIsInstance(payload, dict)
                    patches.append(copy.deepcopy(payload))
                    current.update(payload)
                    return copy.deepcopy(current)
                if method == "GET":
                    return copy.deepcopy(current)
                raise AssertionError(f"unexpected {method} {path}")

        instance.client = FakeClient()
        instance._reconcile_guild(current)

        self.assertEqual(len(patches), 1)
        self.assertFalse(any(
            field.endswith("_channel_id")
            for field in patches[0]
        ))


class CleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = provision.load_manifest(MANIFEST_PATH)
        self.guild_id = "123456789012345678"
        self.legacy_role = {
            "id": "1525110182453968936",
            "name": "Tester",
            "permissions": "0",
            "position": 5,
            "managed": False,
        }
        self.target_role = {
            "id": "923456789012345678",
            "name": "Beta Tester",
            "permissions": "0",
            "position": 4,
            "managed": False,
        }
        self.member_id = "823456789012345678"

    def _manifest_with_role_cleanup(self) -> dict[str, object]:
        manifest = copy.deepcopy(self.manifest)
        manifest["cleanup"] = {
            "roles": [
                {
                    "id": self.legacy_role["id"],
                    "name": self.legacy_role["name"],
                    "migrate_to": "beta-tester",
                }
            ],
            "channels": [],
            "categories": [],
        }
        return manifest

    def test_cleanup_dry_run_fetches_members_but_never_mutates(self) -> None:
        methods: list[str] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                methods.append(method)
                if "/members?limit=1000" in path:
                    return [
                        {
                            "user": {"id": self.member_id},
                            "roles": [self.legacy_role["id"]],
                        }
                    ]
                raise AssertionError(f"unexpected {method} {path}")

        instance = provision.Provisioner(
            FakeClient(),
            self.guild_id,
            self._manifest_with_role_cleanup(),
            apply=False,
            audit_reason="test",
            cleanup_obsolete=True,
            output=lambda _message: None,
        )
        instance.highest_bot_role_position = 10
        instance._prepare_cleanup(
            {
                "id": self.guild_id,
                "owner_id": "999999999999999997",
            },
            [self.legacy_role, self.target_role],
            [],
            [],
        )
        instance._execute_cleanup()
        self.assertEqual(set(methods), {"GET"})
        self.assertTrue(
            any(action.startswith("migrate 1 member") for action in instance.actions)
        )
        self.assertTrue(
            any(action.startswith("delete obsolete role") for action in instance.actions)
        )

    def test_cleanup_apply_migrates_before_exact_role_deletion(self) -> None:
        assigned = True
        calls: list[tuple[str, str]] = []
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                nonlocal assigned
                calls.append((method, path))
                if method == "GET" and "/members?limit=1000" in path:
                    return (
                        [
                            {
                                "user": {"id": self.member_id},
                                "roles": [self.legacy_role["id"]],
                            }
                        ]
                        if assigned
                        else []
                    )
                if method == "GET" and path == f"/guilds/{self.guild_id}":
                    return {
                        "id": self.guild_id,
                        "owner_id": "999999999999999997",
                    }
                if method == "GET" and path.endswith("/roles"):
                    return [self.legacy_role, self.target_role]
                if method == "PUT":
                    return None
                if (
                    method == "DELETE"
                    and f"/members/{self.member_id}/roles/" in path
                ):
                    assigned = False
                    return None
                if method == "DELETE" and "/roles/" in path:
                    return None
                raise AssertionError(f"unexpected {method} {path}")

        instance = provision.Provisioner(
            FakeClient(),
            self.guild_id,
            self._manifest_with_role_cleanup(),
            apply=True,
            audit_reason="test",
            cleanup_obsolete=True,
            rollback_dir=Path(temporary.name),
            output=lambda _message: None,
        )
        instance.highest_bot_role_position = 10
        instance._prepare_cleanup(
            {
                "id": self.guild_id,
                "owner_id": "999999999999999997",
            },
            [self.legacy_role, self.target_role],
            [],
            [],
        )
        instance._execute_cleanup()
        mutation_paths = [
            (method, path)
            for method, path in calls
            if method in {"PUT", "DELETE"}
        ]
        self.assertEqual(mutation_paths[0][0], "PUT")
        self.assertIn(f"/members/{self.member_id}/roles/", mutation_paths[1][1])
        self.assertTrue(mutation_paths[-1][1].endswith(self.legacy_role["id"]))

    def test_final_cleanup_snapshot_uses_refreshed_settings_and_members(
        self,
    ) -> None:
        assigned = True
        refreshed_legacy = {
            **self.legacy_role,
            "permissions": str(provision.PERMISSIONS["VIEW_CHANNEL"]),
        }

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                nonlocal assigned
                if method == "GET" and "/members?limit=1000" in path:
                    return (
                        [
                            {
                                "user": {"id": self.member_id},
                                "roles": [self.legacy_role["id"]],
                            }
                        ]
                        if assigned
                        else []
                    )
                if method == "GET" and path == f"/guilds/{self.guild_id}":
                    return {
                        "id": self.guild_id,
                        "owner_id": "999999999999999997",
                    }
                if method == "GET" and path.endswith("/roles"):
                    return [refreshed_legacy, self.target_role]
                if method == "PUT":
                    return None
                if (
                    method == "DELETE"
                    and f"/members/{self.member_id}/roles/" in path
                ):
                    assigned = False
                    return None
                if method == "DELETE" and "/roles/" in path:
                    return None
                raise AssertionError(f"unexpected {method} {path}")

        with tempfile.TemporaryDirectory() as temporary:
            rollback_dir = Path(temporary)
            instance = provision.Provisioner(
                FakeClient(),
                self.guild_id,
                self._manifest_with_role_cleanup(),
                apply=True,
                audit_reason="test",
                cleanup_obsolete=True,
                rollback_dir=rollback_dir,
                output=lambda _message: None,
            )
            instance.highest_bot_role_position = 10
            instance._prepare_cleanup(
                {
                    "id": self.guild_id,
                    "owner_id": "999999999999999997",
                },
                [self.legacy_role, self.target_role],
                [],
                [],
            )
            instance._execute_cleanup()

            paths = list(rollback_dir.glob("pre-delete-*.json"))
            self.assertEqual(len(paths), 1)
            snapshot = json.loads(paths[0].read_text(encoding="utf-8"))
            role = snapshot["cleanup"]["roles"][0]
            self.assertEqual(
                role["object"]["permissions"],
                refreshed_legacy["permissions"],
            )
            self.assertEqual(role["member_ids"], [self.member_id])
            self.assertEqual(stat.S_IMODE(paths[0].stat().st_mode), 0o600)

    def test_cleanup_aborts_without_final_snapshot_directory(self) -> None:
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=self.manifest,
            apply=True,
            audit_reason="test",
            cleanup_obsolete=True,
            output=lambda _message: None,
        )
        instance.cleanup_plan["channels"] = [
            {
                "definition": {
                    "id": "723456789012345678",
                    "name": "obsolete",
                    "type": "text",
                },
                "object": {
                    "id": "723456789012345678",
                    "name": "obsolete",
                    "type": provision.CHANNEL_TYPES["text"],
                },
            }
        ]
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "requires a private rollback directory",
        ):
            instance._write_cleanup_deletion_snapshot({"id": self.guild_id})

    def test_cleanup_revalidates_channel_after_role_deletion(self) -> None:
        channel = {
            "id": "723456789012345678",
            "name": "obsolete",
            "type": provision.CHANNEL_TYPES["text"],
            "last_message_id": None,
        }
        calls: list[tuple[str, str]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                calls.append((method, path))
                if method == "GET" and path == f"/guilds/{self.guild_id}":
                    return {
                        "id": self.guild_id,
                        "owner_id": "999999999999999997",
                    }
                if method == "GET" and path.endswith("/channels"):
                    return [channel]
                if method == "GET" and path.endswith("/roles"):
                    return [self.legacy_role]
                if method == "GET" and "/members?limit=1000" in path:
                    return []
                if method == "GET" and path == f"/channels/{channel['id']}":
                    return {**channel, "name": "renamed-after-role-phase"}
                if method == "DELETE" and "/roles/" in path:
                    return None
                raise AssertionError(f"unexpected {method} {path}")

        with tempfile.TemporaryDirectory() as temporary:
            instance = provision.Provisioner(
                FakeClient(),
                self.guild_id,
                self.manifest,
                apply=True,
                audit_reason="test",
                cleanup_obsolete=True,
                rollback_dir=Path(temporary),
                output=lambda _message: None,
            )
            instance.highest_bot_role_position = 10
            instance.cleanup_plan = {
                "roles": [
                    {
                        "definition": {
                            "id": self.legacy_role["id"],
                            "name": self.legacy_role["name"],
                        },
                        "object": copy.deepcopy(self.legacy_role),
                        "target_role": None,
                        "members": [],
                        "member_ids": [],
                    }
                ],
                "channels": [
                    {
                        "definition": {
                            "id": channel["id"],
                            "name": channel["name"],
                            "type": "text",
                        },
                        "object": copy.deepcopy(channel),
                    }
                ],
                "categories": [],
            }
            with self.assertRaisesRegex(
                provision.DiscordAPIError,
                "changed immediately before deletion",
            ):
                instance._execute_cleanup()

        self.assertTrue(
            any(
                method == "DELETE" and "/roles/" in path
                for method, path in calls
            )
        )
        self.assertFalse(
            any(
                method == "DELETE" and path.startswith("/channels/")
                for method, path in calls
            )
        )

    def test_cleanup_revalidates_category_is_empty_before_delete(self) -> None:
        category = {
            "id": "733456789012345678",
            "name": "OBSOLETE",
            "type": provision.CHANNEL_TYPES["category"],
        }
        channel_list_reads = 0
        calls: list[tuple[str, str]] = []

        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                nonlocal channel_list_reads
                calls.append((method, path))
                if method == "GET" and path == f"/guilds/{self.guild_id}":
                    return {"id": self.guild_id}
                if method == "GET" and path.endswith("/channels"):
                    channel_list_reads += 1
                    if channel_list_reads == 1:
                        return [category]
                    return [
                        category,
                        {
                            "id": "743456789012345678",
                            "name": "new-child",
                            "type": provision.CHANNEL_TYPES["text"],
                            "parent_id": category["id"],
                        },
                    ]
                if method == "GET" and path == f"/channels/{category['id']}":
                    return category
                raise AssertionError(f"unexpected {method} {path}")

        with tempfile.TemporaryDirectory() as temporary:
            instance = provision.Provisioner(
                FakeClient(),
                self.guild_id,
                self.manifest,
                apply=True,
                audit_reason="test",
                cleanup_obsolete=True,
                rollback_dir=Path(temporary),
                output=lambda _message: None,
            )
            instance.cleanup_plan = {
                "roles": [],
                "channels": [],
                "categories": [
                    {
                        "definition": {
                            "id": category["id"],
                            "name": category["name"],
                        },
                        "object": copy.deepcopy(category),
                    }
                ],
            }
            with self.assertRaisesRegex(
                provision.DiscordAPIError,
                "non-empty obsolete category",
            ):
                instance._execute_cleanup()

        self.assertFalse(any(method == "DELETE" for method, _path in calls))

    def test_cleanup_refuses_stale_identity_and_unmanageable_role(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["cleanup"] = {
            "roles": [],
            "channels": [
                {
                    "id": "723456789012345678",
                    "name": "expected-name",
                    "type": "text",
                }
            ],
            "categories": [],
        }
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=manifest,
            apply=False,
            audit_reason="test",
            cleanup_obsolete=True,
            output=lambda _message: None,
        )
        instance.highest_bot_role_position = 10
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "no longer matches",
        ):
            instance._prepare_cleanup(
                {"id": self.guild_id},
                [],
                [
                    {
                        "id": "723456789012345678",
                        "name": "different-name",
                        "type": provision.CHANNEL_TYPES["text"],
                    }
                ],
                [],
            )

        manifest = self._manifest_with_role_cleanup()
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=manifest,
            apply=False,
            audit_reason="test",
            cleanup_obsolete=True,
            output=lambda _message: None,
        )
        instance.highest_bot_role_position = 5
        with self.assertRaisesRegex(
            provision.DiscordAPIError,
            "at or above",
        ):
            instance._prepare_cleanup(
                {"id": self.guild_id},
                [self.legacy_role, self.target_role],
                [],
                [],
            )

    def test_cleanup_plans_role_completion_before_channel_deletion(self) -> None:
        instance = provision.Provisioner(
            client=None,
            guild_id=self.guild_id,
            manifest=self._manifest_with_role_cleanup(),
            apply=False,
            audit_reason="test",
            cleanup_obsolete=True,
            output=lambda _message: None,
        )
        instance.cleanup_plan = {
            "roles": [
                {
                    "definition": {
                        "id": self.legacy_role["id"],
                        "name": "Tester",
                    },
                    "object": self.legacy_role,
                    "target_role": self.target_role,
                    "members": [],
                    "member_ids": [],
                }
            ],
            "channels": [
                {
                    "definition": {
                        "id": "723456789012345678",
                        "name": "obsolete",
                        "type": "text",
                    },
                    "object": {
                        "id": "723456789012345678",
                        "name": "obsolete",
                        "type": 0,
                    },
                }
            ],
            "categories": [],
        }
        instance._execute_cleanup()
        self.assertTrue(instance.actions[0].startswith("delete obsolete role"))
        self.assertTrue(
            instance.actions[1].startswith("delete obsolete text channel")
        )

    def test_cleanup_refuses_owner_role_mutation(self) -> None:
        class FakeClient:
            def request(
                _self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                if "/members?limit=1000" in path:
                    return [
                        {
                            "user": {"id": self.member_id},
                            "roles": [self.legacy_role["id"]],
                        }
                    ]
                raise AssertionError(f"unexpected {method} {path}")

        instance = provision.Provisioner(
            FakeClient(),
            self.guild_id,
            self._manifest_with_role_cleanup(),
            apply=False,
            audit_reason="test",
            cleanup_obsolete=True,
            output=lambda _message: None,
        )
        instance.highest_bot_role_position = 10
        with self.assertRaisesRegex(provision.DiscordAPIError, "guild owner"):
            instance._prepare_cleanup(
                {
                    "id": self.guild_id,
                    "owner_id": self.member_id,
                },
                [self.legacy_role, self.target_role],
                [],
                [],
            )


class ApplyLockTests(unittest.TestCase):
    def test_apply_lock_is_exclusive_and_private_per_state_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "nested" / "state.json"
            with provision._exclusive_apply_lock(state_path) as lock_path:
                self.assertEqual(
                    lock_path,
                    state_path.resolve().with_name("state.json.lock"),
                )
                self.assertEqual(
                    stat.S_IMODE(lock_path.stat().st_mode),
                    0o600,
                )
                with self.assertRaisesRegex(
                    provision.DiscordAPIError,
                    "another Discord apply",
                ):
                    with provision._exclusive_apply_lock(state_path):
                        self.fail("a second apply acquired the same state lock")

            with provision._exclusive_apply_lock(state_path):
                pass

    def test_main_holds_apply_lock_from_state_load_through_run(self) -> None:
        events: list[str] = []
        guild_id = "123456789012345678"

        @provision.contextlib.contextmanager
        def tracked_lock(_path: Path) -> object:
            events.append("lock")
            yield
            events.append("unlock")

        def tracked_load(_path: Path, _guild_id: str) -> dict[str, object]:
            events.append("load")
            return {}

        def tracked_run() -> list[str]:
            events.append("run")
            return []

        with tempfile.TemporaryDirectory() as temporary, mock.patch.dict(
            os.environ,
            {
                "DISCORD_BOT_TOKEN": "test-token",
                "DISCORD_GUILD_ID": guild_id,
            },
        ), mock.patch.object(
            provision,
            "_exclusive_apply_lock",
            side_effect=tracked_lock,
        ), mock.patch.object(
            provision,
            "load_state",
            side_effect=tracked_load,
        ), mock.patch.object(
            provision,
            "Provisioner",
        ) as provisioner_type, mock.patch("builtins.print"):
            provisioner_type.return_value.run.side_effect = tracked_run
            result = provision.main(
                [
                    "--apply",
                    "--state",
                    str(Path(temporary) / "state.json"),
                ]
            )

        self.assertEqual(result, 0)
        self.assertEqual(events, ["lock", "load", "run", "unlock"])

    def test_main_dry_run_does_not_create_apply_lock(self) -> None:
        guild_id = "123456789012345678"
        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            with mock.patch.dict(
                os.environ,
                {
                    "DISCORD_BOT_TOKEN": "test-token",
                    "DISCORD_GUILD_ID": guild_id,
                },
            ), mock.patch.object(
                provision,
                "_exclusive_apply_lock",
            ) as apply_lock, mock.patch.object(
                provision,
                "Provisioner",
            ) as provisioner_type, mock.patch("builtins.print"):
                provisioner_type.return_value.run.return_value = []
                result = provision.main(["--state", str(state_path)])

            self.assertEqual(result, 0)
            apply_lock.assert_not_called()
            self.assertFalse(state_path.with_name("state.json.lock").exists())


class DryRunTests(unittest.TestCase):
    def test_administrator_bootstrap_dry_run_is_get_only(self) -> None:
        manifest = provision.load_manifest(MANIFEST_PATH)
        guild_id = "123456789012345678"
        bot_id = "234567890123456789"
        bot_role_id = "345678901234567890"

        class FakeClient:
            def __init__(self) -> None:
                self.methods: list[str] = []

            def request(
                self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                self.methods.append(method)
                if path == f"/guilds/{guild_id}":
                    return {
                        "id": guild_id,
                        "features": [],
                    }
                if path.endswith("/roles"):
                    return [
                        {
                            "id": guild_id,
                            "name": "@everyone",
                            "permissions": "0",
                            "position": 0,
                        },
                        {
                            "id": bot_role_id,
                            "name": "CloudNow Setup",
                            "permissions": str(
                                provision.PERMISSIONS["ADMINISTRATOR"]
                            ),
                            "position": 10,
                            "managed": True,
                        },
                    ]
                if path == "/users/@me":
                    return {"id": bot_id, "bot": True}
                if path == f"/guilds/{guild_id}/members/{bot_id}":
                    return {"roles": [bot_role_id]}
                if path.endswith("/channels"):
                    return []
                raise AssertionError(f"unexpected {method} {path}")

        client = FakeClient()
        instance = provision.Provisioner(
            client,
            guild_id,
            manifest,
            apply=False,
            audit_reason="test",
            bootstrap_from_administrator=True,
            output=lambda _message: None,
        )
        actions = instance.run()
        self.assertEqual(set(client.methods), {"GET"})
        self.assertIn(
            "create role 'CloudNow Provisioner'",
            actions,
        )
        self.assertIn(
            "enable Community with managed rules and updates channels",
            actions,
        )

    def test_dry_run_only_uses_get_requests(self) -> None:
        manifest = provision.load_manifest(MANIFEST_PATH)
        guild_id = "123456789012345678"
        bot_id = "234567890123456789"
        bot_role_id = "345678901234567890"

        class FakeClient:
            def __init__(self) -> None:
                self.methods: list[str] = []

            def request(
                self,
                method: str,
                path: str,
                payload: object = None,
                *,
                reason: str | None = None,
            ) -> object:
                self.methods.append(method)
                if path == f"/guilds/{guild_id}":
                    return {
                        "id": guild_id,
                        "features": ["COMMUNITY"],
                    }
                if path.endswith("/roles"):
                    return [
                        {
                            "id": guild_id,
                            "name": "@everyone",
                            "permissions": "0",
                            "position": 0,
                        },
                        {
                            "id": bot_role_id,
                            "name": "CloudNow Setup",
                            "permissions": str(
                                provision.required_bot_permissions(manifest)
                            ),
                            "position": 100,
                            "managed": True,
                        }
                    ]
                if path == "/users/@me":
                    return {"id": bot_id, "bot": True}
                if path == f"/guilds/{guild_id}/members/{bot_id}":
                    return {"roles": [bot_role_id]}
                if path.endswith("/channels"):
                    return []
                if path.endswith("/onboarding"):
                    return {
                        "prompts": [],
                        "default_channel_ids": [],
                        "enabled": False,
                        "mode": 0,
                    }
                if path.endswith("/auto-moderation/rules"):
                    return []
                raise AssertionError(f"unexpected {method} {path}")

        client = FakeClient()
        instance = provision.Provisioner(
            client,
            guild_id,
            manifest,
            apply=False,
            audit_reason="test",
            output=lambda _message: None,
        )
        actions = instance.run()
        self.assertGreater(len(actions), 0)
        self.assertEqual(set(client.methods), {"GET"})


if __name__ == "__main__":
    unittest.main()
