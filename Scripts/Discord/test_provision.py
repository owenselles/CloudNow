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
            7,
        )
        self.assertEqual(
            len(self.manifest["onboarding"]["writable_default_channels"]),
            5,
        )

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
        self.assertEqual(support["allow"], ["MANAGE_THREADS"])
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
            str(provision.PERMISSIONS["VIEW_CHANNEL"]),
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


class DryRunTests(unittest.TestCase):
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
