#!/usr/bin/env python3
"""Focused standard-library tests for local Discord content publication."""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import unittest
import urllib.parse
import urllib.request
from unittest import mock
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import publish_content  # noqa: E402


REPOSITORY_ROOT = SCRIPT_DIR.parents[1]
CONTENT_DIR = REPOSITORY_ROOT / "docs/community/discord/content"
GUILD_ID = "123456789012345678"
OTHER_TAG_ID = "400000000000000001"
BOT_USER_ID = "100000000000000001"


def core_state() -> dict[str, Any]:
    channels = {}
    for index, name in enumerate(
        (
            "start-here",
            "rules",
            "faq",
            "contributing",
            "support-resources",
            "known-issues",
            "feature-discussion",
            "security-response",
            "help",
        ),
        start=1,
    ):
        channels[name] = {
            "id": f"2000000000000000{index}",
            "name": name,
        }
    return {
        "state_version": 1,
        "guild_id": GUILD_ID,
        "resources": {"channels": channels},
    }


class FakeClient:
    def __init__(
        self,
        *,
        require_tag: bool = False,
        message_content_intent: bool = True,
    ) -> None:
        self.calls: list[tuple[str, str, Any]] = []
        self.messages: dict[tuple[str, str], dict[str, Any]] = {}
        self.threads: dict[str, dict[str, Any]] = {}
        self.history_responses: dict[str, Any] = {}
        self.next_id = 300000000000000000
        self.pin_notice_ids: list[str] = []
        self.application_flags: int | str = (
            publish_content.GATEWAY_MESSAGE_CONTENT_LIMITED
            if message_content_intent
            else 0
        )
        core_channels = core_state()["resources"]["channels"]
        self.guild_channels = [
            {
                "id": item["id"],
                "guild_id": GUILD_ID,
                "name": item["name"],
                "type": 15 if key == "help" else 0,
            }
            for key, item in core_channels.items()
        ]
        help_id = core_channels["help"]["id"]
        self.help_forum = {
            "id": help_id,
            "type": 15,
            "flags": publish_content.REQUIRE_TAG_FLAG if require_tag else 0,
            "available_tags": [
                {
                    "id": OTHER_TAG_ID,
                    "name": publish_content.OTHER_TAG_NAME,
                }
            ],
        }

    def _id(self) -> str:
        self.next_id += 1
        return str(self.next_id)

    @staticmethod
    def _message_payload(message: dict[str, Any]) -> dict[str, Any]:
        result = copy.deepcopy(message)
        result.setdefault("embeds", [])
        result.setdefault("attachments", [])
        result.setdefault("components", [])
        result.setdefault("type", 0)
        result.setdefault("edited_timestamp", None)
        return result

    def request(
        self,
        method: str,
        path: str,
        payload: Any = None,
        *,
        reason: str | None = None,
    ) -> Any:
        self.calls.append((method, path, copy.deepcopy(payload)))
        if method == "GET" and path == f"/guilds/{GUILD_ID}":
            return {"id": GUILD_ID}
        if method == "GET" and path == f"/guilds/{GUILD_ID}/channels":
            return copy.deepcopy(self.guild_channels)
        if method == "GET" and path == "/oauth2/applications/@me":
            return {
                "id": BOT_USER_ID,
                "flags": self.application_flags,
            }
        if method == "GET" and path == "/users/@me":
            return {"id": BOT_USER_ID, "bot": True}
        if (
            method == "GET"
            and path == f"/guilds/{GUILD_ID}/threads/active"
        ):
            return {
                "threads": [
                    copy.deepcopy(thread)
                    for thread in self.threads.values()
                    if not thread.get("thread_metadata", {}).get("archived")
                ],
                "members": [],
            }

        parsed = urllib.parse.urlsplit(path)
        parts = parsed.path.strip("/").split("/")
        if (
            method == "GET"
            and len(parts) == 5
            and parts[0] == "channels"
            and parts[2:] == ["threads", "archived", "public"]
        ):
            return {
                "threads": [
                    copy.deepcopy(thread)
                    for thread in self.threads.values()
                    if (
                        str(thread.get("parent_id", "")) == parts[1]
                        and thread.get("thread_metadata", {}).get("archived")
                    )
                ],
                "members": [],
                "has_more": False,
            }
        if method == "GET" and len(parts) == 2 and parts[0] == "channels":
            if parts[1] == self.help_forum["id"]:
                return copy.deepcopy(self.help_forum)
            thread = self.threads.get(parts[1])
            if thread is None:
                raise publish_content.DiscordAPIError(
                    "not found",
                    status=404,
                    code=10003,
                )
            return copy.deepcopy(thread)
        if (
            method == "GET"
            and len(parts) == 3
            and parts[0] == "channels"
            and parts[2] == "messages"
        ):
            channel_id = parts[1]
            override = self.history_responses.get(channel_id)
            if override is not None:
                return copy.deepcopy(override)
            query = urllib.parse.parse_qs(parsed.query)
            limit = int(query.get("limit", ["50"])[0])
            before = query.get("before", [None])[0]
            messages = [
                message
                for (candidate_channel, _message_id), message
                in self.messages.items()
                if candidate_channel == channel_id
            ]
            messages.sort(key=lambda item: int(item["id"]), reverse=True)
            if before is not None:
                messages = [
                    message
                    for message in messages
                    if int(message["id"]) < int(before)
                ]
            return [
                self._message_payload(message)
                for message in messages[:limit]
            ]
        if (
            method == "GET"
            and len(parts) == 4
            and parts[0] == "channels"
            and parts[2] == "messages"
        ):
            message = self.messages.get((parts[1], parts[3]))
            if message is None:
                raise publish_content.DiscordAPIError(
                    "not found",
                    status=404,
                    code=10008,
                )
            return self._message_payload(message)

        if (
            method == "POST"
            and len(parts) == 3
            and parts[0] == "channels"
            and parts[2] == "messages"
        ):
            message_id = self._id()
            message = {
                "id": message_id,
                "channel_id": parts[1],
                "content": payload["content"],
                "pinned": False,
                "author": {"id": BOT_USER_ID, "bot": True},
            }
            self.messages[(parts[1], message_id)] = message
            return self._message_payload(message)

        if (
            method == "PATCH"
            and len(parts) == 4
            and parts[0] == "channels"
            and parts[2] == "messages"
        ):
            message = self.messages[(parts[1], parts[3])]
            message["content"] = payload["content"]
            return self._message_payload(message)

        if (
            method == "PUT"
            and len(parts) == 5
            and parts[0] == "channels"
            and parts[2:4] == ["messages", "pins"]
        ):
            self.messages[(parts[1], parts[4])]["pinned"] = True
            notice_id = self._id()
            self.pin_notice_ids.append(notice_id)
            self.messages[(parts[1], notice_id)] = {
                "id": notice_id,
                "channel_id": parts[1],
                "content": "",
                "pinned": False,
                "type": publish_content.CHANNEL_PINNED_MESSAGE_TYPE,
                "author": {"id": BOT_USER_ID, "bot": True},
                "message_reference": {
                    "channel_id": parts[1],
                    "message_id": parts[4],
                },
            }
            return None

        if (
            method == "POST"
            and len(parts) == 3
            and parts[0] == "channels"
            and parts[2] == "threads"
        ):
            thread_id = self._id()
            starter = {
                "id": thread_id,
                "channel_id": thread_id,
                "content": payload["message"]["content"],
                "pinned": False,
                "author": {"id": BOT_USER_ID, "bot": True},
            }
            thread = {
                "id": thread_id,
                "parent_id": parts[1],
                "owner_id": BOT_USER_ID,
                "name": payload["name"],
                "flags": 0,
                "applied_tags": payload.get("applied_tags", []),
                "thread_metadata": {
                    "archived": False,
                    "locked": False,
                },
                "message": starter,
            }
            self.threads[thread_id] = thread
            self.messages[(thread_id, thread_id)] = starter
            return copy.deepcopy(thread)

        if (
            method == "PATCH"
            and len(parts) == 2
            and parts[0] == "channels"
        ):
            thread = self.threads[parts[1]]
            desired_flags = payload.get("flags", thread.get("flags", 0))
            if (
                desired_flags & publish_content.PINNED_THREAD_FLAG
                and not thread.get("flags", 0)
                & publish_content.PINNED_THREAD_FLAG
                and any(
                    candidate["id"] != thread["id"]
                    and candidate.get("parent_id") == thread.get("parent_id")
                    and candidate.get("flags", 0)
                    & publish_content.PINNED_THREAD_FLAG
                    for candidate in self.threads.values()
                )
            ):
                raise publish_content.DiscordAPIError(
                    "Maximum number pinned threads in this channel reached",
                    status=400,
                    code=30047,
                )
            metadata = thread.setdefault("thread_metadata", {})
            for key in ("archived", "locked"):
                if key in payload:
                    metadata[key] = payload[key]
            thread.update({
                key: value
                for key, value in payload.items()
                if key not in {"archived", "locked"}
            })
            return copy.deepcopy(thread)

        if (
            method == "DELETE"
            and len(parts) == 4
            and parts[0] == "channels"
            and parts[2] == "messages"
        ):
            key = (parts[1], parts[3])
            if key not in self.messages:
                raise publish_content.DiscordAPIError(
                    "not found",
                    status=404,
                    code=10008,
                )
            del self.messages[key]
            return None

        raise AssertionError(f"unexpected {method} {path}")


def loaded_content() -> tuple[
    list[publish_content.Publication],
    list[publish_content.ForumPublication],
]:
    return publish_content.load_publications(
        CONTENT_DIR,
        "email moderators@example.test",
    )


def complete_state(
    client: FakeClient,
    *,
    stale_key: str | None = None,
) -> dict[str, Any]:
    publications, forum_publications = loaded_content()
    channels = core_state()["resources"]["channels"]
    standard: dict[str, Any] = {}
    for publication in publications:
        channel_id = channels[publication.channel_key]["id"]
        records = []
        for index, content in enumerate(publication.chunks):
            message_id = client._id()
            actual = "outdated copy" if (
                publication.key == stale_key and index == 0
            ) else content
            client.messages[(channel_id, message_id)] = {
                "id": message_id,
                "channel_id": channel_id,
                "content": actual,
                "pinned": True,
                "author": {"id": BOT_USER_ID, "bot": True},
            }
            records.append({"message_id": message_id, "content_sha256": "old"})
        standard[publication.key] = {
            "channel_id": channel_id,
            "chunks": records,
        }

    help_id = channels["help"]["id"]
    forum_posts: dict[str, Any] = {}
    for publication in forum_publications:
        thread_id = client._id()
        records = []
        for content in publication.chunks:
            message_id = thread_id if not records else client._id()
            client.messages[(thread_id, message_id)] = {
                "id": message_id,
                "channel_id": thread_id,
                "content": content,
                "pinned": False,
                "author": {"id": BOT_USER_ID, "bot": True},
            }
            records.append(
                {"message_id": message_id, "content_sha256": "old"}
            )
        applied_tags = []
        if (
            publication.always_apply_other_tag
            or client.help_forum["flags"] & publish_content.REQUIRE_TAG_FLAG
        ):
            applied_tags = [OTHER_TAG_ID]
        client.threads[thread_id] = {
            "id": thread_id,
            "parent_id": help_id,
            "owner_id": BOT_USER_ID,
            "name": publication.name,
            "flags": (
                publish_content.PINNED_THREAD_FLAG
                if publication.pinned
                else 0
            ),
            "applied_tags": applied_tags,
            "thread_metadata": {
                "archived": False,
                "locked": True,
            },
        }
        forum_posts[publication.key] = {
            "forum_channel_id": help_id,
            "thread_id": thread_id,
            "name": publication.name,
            "chunks": records,
        }
    return {
        "state_version": 1,
        "guild_id": GUILD_ID,
        "resources": {
            "standard_messages": standard,
            "forum_posts": forum_posts,
        },
    }


def publisher(
    client: FakeClient,
    *,
    apply: bool,
    core: dict[str, Any] | None = None,
    state: dict[str, Any] | None = None,
    state_path: Path | None = None,
    rollback_dir: Path | None = None,
    replace_existing_content: bool = False,
) -> publish_content.ContentPublisher:
    return publish_content.ContentPublisher(
        client,
        GUILD_ID,
        CONTENT_DIR,
        core or core_state(),
        appeal_method="email moderators@example.test",
        apply=apply,
        audit_reason="test",
        replace_existing_content=replace_existing_content,
        state=state,
        state_path=state_path,
        rollback_dir=rollback_dir,
        output=lambda _message: None,
    )


class ContentParsingTests(unittest.TestCase):
    def test_split_markdown_never_exceeds_discord_limit(self) -> None:
        text = ("alpha " * 450) + "\n\n" + ("beta " * 450)
        chunks = publish_content.split_markdown(text)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(0 < len(chunk) <= 2_000 for chunk in chunks))
        self.assertEqual(" ".join(text.split()), " ".join(" ".join(chunks).split()))

    def test_moderation_appeal_substitution_is_a_launch_blocker(self) -> None:
        source = "Appeal through `{MODERATION_APPEAL_METHOD}`."
        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "DISCORD_MODERATION_APPEAL_METHOD",
        ):
            publish_content.render_rules(source, "")
        rendered = publish_content.render_rules(source, "a private modmail ticket")
        self.assertEqual(rendered, "Appeal through `a private modmail ticket`.")

    def test_support_known_issues_and_help_posts_are_distinct(self) -> None:
        publications, forum_publications = loaded_content()
        standard = {publication.key: publication for publication in publications}
        forum = {
            publication.key: publication
            for publication in forum_publications
        }
        self.assertIn("CloudNow Support Resources", " ".join(
            standard["support-resources"].chunks
        ))
        self.assertIn("No community-wide issue", " ".join(
            standard["known-issues"].chunks
        ))
        self.assertNotIn(
            "CloudNow Support Resources",
            " ".join(forum[publish_content.SUPPORT_POST_KEY].chunks),
        )
        self.assertNotIn(
            "Support request",
            " ".join(forum[publish_content.GUIDELINES_POST_KEY].chunks),
        )


class PublicationSafetyTests(unittest.TestCase):
    def test_dry_run_only_uses_get_requests(self) -> None:
        client = FakeClient()
        actions = publisher(client, apply=False).run()
        self.assertGreater(len(actions), 0)
        self.assertEqual({method for method, _path, _body in client.calls}, {"GET"})
        self.assertEqual(
            sum(
                path == "/users/@me"
                for _method, path, _payload in client.calls
            ),
            1,
        )

    def test_fresh_replacement_flow_plans_applies_and_converges(self) -> None:
        client = FakeClient(require_tag=True)

        plan_actions = publisher(
            client,
            apply=False,
            replace_existing_content=True,
        ).run()
        self.assertGreater(len(plan_actions), 0)
        self.assertEqual(
            {method for method, _path, _body in client.calls},
            {"GET"},
        )

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            rollback_dir = Path(temporary) / "rollbacks"
            client.calls.clear()
            apply_actions = publisher(
                client,
                apply=True,
                state_path=state_path,
                rollback_dir=rollback_dir,
                replace_existing_content=True,
            ).run()
            self.assertEqual(apply_actions, plan_actions)
            state = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )

            client.calls.clear()
            second_plan = publisher(
                client,
                apply=False,
                state=state,
                replace_existing_content=True,
            ).run()
            self.assertEqual(second_plan, [])
            self.assertEqual(
                {method for method, _path, _body in client.calls},
                {"GET"},
            )

            client.calls.clear()
            second_apply = publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
                rollback_dir=rollback_dir,
                replace_existing_content=True,
            ).run()

        self.assertEqual(second_apply, [])
        self.assertEqual(
            [call for call in client.calls if call[0] != "GET"],
            [],
        )

    def test_replacement_requires_message_content_intent(self) -> None:
        client = FakeClient(message_content_intent=False)

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "requires Message Content Intent",
        ):
            publisher(
                client,
                apply=False,
                replace_existing_content=True,
            ).run()

        self.assertEqual(
            client.calls,
            [
                ("GET", f"/guilds/{GUILD_ID}", None),
                ("GET", f"/guilds/{GUILD_ID}/channels", None),
                ("GET", "/users/@me", None),
                ("GET", "/oauth2/applications/@me", None),
            ],
        )

    def test_replacement_accepts_approved_message_content_flag(self) -> None:
        client = FakeClient()
        client.application_flags = publish_content.GATEWAY_MESSAGE_CONTENT

        actions = publisher(
            client,
            apply=False,
            replace_existing_content=True,
        ).run()

        self.assertGreater(len(actions), 0)
        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_replacement_rejects_malformed_application_flags(self) -> None:
        client = FakeClient()
        client.application_flags = "not-an-integer"

        with self.assertRaisesRegex(
            publish_content.DiscordAPIError,
            "malformed bot application flags",
        ):
            publisher(
                client,
                apply=False,
                replace_existing_content=True,
            ).run()

        self.assertEqual(
            client.calls,
            [
                ("GET", f"/guilds/{GUILD_ID}", None),
                ("GET", f"/guilds/{GUILD_ID}/channels", None),
                ("GET", "/users/@me", None),
                ("GET", "/oauth2/applications/@me", None),
            ],
        )

    def test_state_channel_mismatch_resets_to_current_core_channel(self) -> None:
        state = {
            "state_version": 1,
            "guild_id": GUILD_ID,
            "resources": {
                "standard_messages": {
                    "start-here": {
                        "channel_id": "999999999999999999",
                        "chunks": [{"message_id": "888888888888888888"}],
                    }
                },
                "forum_posts": {},
            },
        }
        client = FakeClient()
        actions = publisher(client, apply=False, state=state).run()
        self.assertIn("create start-here message chunk 1", actions)
        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_core_channel_outside_guild_fails_before_mutation(self) -> None:
        client = FakeClient()
        core = core_state()
        core["resources"]["channels"]["start-here"]["id"] = (
            "999999999999999999"
        )

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "not a live channel in guild",
        ):
            publisher(client, apply=True, core=core).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_live_channel_type_mismatch_fails_before_mutation(self) -> None:
        client = FakeClient()
        start_id = core_state()["resources"]["channels"]["start-here"]["id"]
        next(
            channel
            for channel in client.guild_channels
            if channel["id"] == start_id
        )["type"] = 2

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "has type 2, expected 0",
        ):
            publisher(client, apply=True).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_duplicate_live_channel_inventory_fails_before_mutation(
        self,
    ) -> None:
        client = FakeClient()
        client.guild_channels.append(copy.deepcopy(client.guild_channels[0]))

        with self.assertRaisesRegex(
            publish_content.DiscordAPIError,
            "unsafe guild channel inventory",
        ):
            publisher(client, apply=True).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_tracked_standard_messages_must_be_bot_owned(self) -> None:
        for publication_key in ("rules", "feature-discussion"):
            with self.subTest(publication=publication_key):
                client = FakeClient()
                state = complete_state(client)
                item = state["resources"]["standard_messages"][
                    publication_key
                ]
                message_id = item["chunks"][0]["message_id"]
                client.messages[(item["channel_id"], message_id)]["author"] = {
                    "id": "500000000000000001",
                }
                client.calls.clear()

                with self.assertRaisesRegex(
                    publish_content.ManifestError,
                    "message not owned by the provisioning bot",
                ):
                    publisher(client, apply=True, state=state).run()

                self.assertTrue(all(
                    method == "GET"
                    for method, _path, _payload in client.calls
                ))

    def test_tracked_forum_starter_must_be_bot_owned(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        item = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        thread_id = item["thread_id"]
        client.messages[(thread_id, thread_id)]["author"] = {
            "id": "500000000000000001",
        }
        client.calls.clear()

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "message not owned by the provisioning bot",
        ):
            publisher(client, apply=True, state=state).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_tracked_forum_followup_must_be_bot_owned(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        item = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        message_id = client._id()
        client.messages[(item["thread_id"], message_id)] = {
            "id": message_id,
            "channel_id": item["thread_id"],
            "content": "member-authored follow-up",
            "pinned": False,
            "author": {"id": "500000000000000001"},
        }
        item["chunks"].append({
            "message_id": message_id,
            "content_sha256": "corrupt-state",
        })
        client.calls.clear()

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "message not owned by the provisioning bot",
        ):
            publisher(client, apply=True, state=state).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_tracked_forum_thread_owner_must_be_bot(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        item = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        client.threads[item["thread_id"]]["owner_id"] = (
            "500000000000000001"
        )
        client.calls.clear()

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "thread not owned by the provisioning bot",
        ):
            publisher(client, apply=True, state=state).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_missing_thread_owner_uses_bot_owned_starter(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        for thread in client.threads.values():
            thread.pop("owner_id")

        actions = publisher(client, apply=False, state=state).run()

        self.assertEqual(actions, [])

    def test_duplicate_forum_thread_binding_fails_before_mutation(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        forum = state["resources"]["forum_posts"]
        forum[publish_content.GUIDELINES_POST_KEY]["thread_id"] = forum[
            publish_content.SUPPORT_POST_KEY
        ]["thread_id"]
        client.calls.clear()

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "one thread ID",
        ):
            publisher(client, apply=False, state=state).run()
        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_creates_two_forum_posts_but_pins_only_support(self) -> None:
        client = FakeClient()
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            publisher(
                client,
                apply=True,
                state_path=temporary_path / "state.json",
                rollback_dir=temporary_path / "rollbacks",
            ).run()

        creates = [
            call
            for call in client.calls
            if call[0] == "POST" and call[1].endswith("/threads")
        ]
        self.assertEqual(len(creates), 2)
        by_name = {call[2]["name"]: call[2] for call in creates}
        self.assertEqual(
            set(by_name),
            {
                publish_content.GUIDELINES_POST_NAME,
                publish_content.SUPPORT_POST_NAME,
            },
        )
        self.assertEqual(
            by_name[publish_content.GUIDELINES_POST_NAME]["applied_tags"],
            [OTHER_TAG_ID],
        )
        self.assertNotIn(
            "applied_tags",
            by_name[publish_content.SUPPORT_POST_NAME],
        )
        for payload in by_name.values():
            self.assertEqual(
                payload["message"]["allowed_mentions"],
                {"parse": []},
            )
        pinned_threads = [
            thread
            for thread in client.threads.values()
            if thread["flags"] & publish_content.PINNED_THREAD_FLAG
        ]
        self.assertEqual(len(pinned_threads), 1)
        self.assertEqual(
            pinned_threads[0]["name"],
            publish_content.SUPPORT_POST_NAME,
        )
        support_thread = next(
            thread
            for thread in client.threads.values()
            if thread["name"] == publish_content.SUPPORT_POST_NAME
        )
        self.assertTrue(
            support_thread["thread_metadata"]["locked"]
        )

    def test_unexpected_guidelines_pin_is_removed_and_converges(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        guidelines = state["resources"]["forum_posts"][
            publish_content.GUIDELINES_POST_KEY
        ]
        guidelines_thread = client.threads[guidelines["thread_id"]]
        guidelines_thread["flags"] |= publish_content.PINNED_THREAD_FLAG

        actions = publisher(client, apply=True, state=state).run()

        self.assertIn(
            "unpin 'Help forum guidelines' forum post",
            actions,
        )
        self.assertFalse(
            guidelines_thread["flags"] & publish_content.PINNED_THREAD_FLAG
        )

        client.calls.clear()
        second_actions = publisher(client, apply=True, state=state).run()
        self.assertEqual(second_actions, [])
        self.assertEqual(
            [call for call in client.calls if call[0] != "GET"],
            [],
        )

    def test_interrupted_apply_safely_moves_pin_then_converges(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        guidelines = state["resources"]["forum_posts"][
            publish_content.GUIDELINES_POST_KEY
        ]
        support = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        guidelines_thread = client.threads[guidelines["thread_id"]]
        support_thread = client.threads[support["thread_id"]]
        guidelines_thread["flags"] = publish_content.PINNED_THREAD_FLAG
        support_thread["flags"] = 0
        support_thread["thread_metadata"]["locked"] = False

        actions = publisher(client, apply=False, state=state).run()

        self.assertEqual(
            actions,
            [
                "unpin 'Help forum guidelines' forum post",
                "pin 'Support request template' forum post",
                "lock 'Support request template' forum post",
            ],
        )
        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

        client.calls.clear()
        applied_actions = publisher(client, apply=True, state=state).run()
        self.assertEqual(applied_actions, actions)
        forum_patches = [
            (path, payload)
            for method, path, payload in client.calls
            if method == "PATCH" and "/messages/" not in path
        ]
        self.assertEqual(
            forum_patches,
            [
                (
                    f"/channels/{guidelines['thread_id']}",
                    {"flags": 0},
                ),
                (
                    f"/channels/{support['thread_id']}",
                    {
                        "flags": publish_content.PINNED_THREAD_FLAG,
                        "locked": True,
                    },
                ),
            ],
        )
        self.assertFalse(
            guidelines_thread["flags"]
            & publish_content.PINNED_THREAD_FLAG
        )
        self.assertTrue(
            support_thread["flags"]
            & publish_content.PINNED_THREAD_FLAG
        )
        self.assertTrue(support_thread["thread_metadata"]["locked"])

        client.calls.clear()
        self.assertEqual(
            publisher(client, apply=False, state=state).run(),
            [],
        )

    def test_require_tag_applies_other_to_support_template(self) -> None:
        client = FakeClient(require_tag=True)
        state = complete_state(client)
        support = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        client.threads[support["thread_id"]]["applied_tags"] = []

        first_actions = publisher(client, apply=True, state=state).run()
        self.assertIn(
            "apply exact 'Other' tag to 'Support request template'",
            first_actions,
        )
        self.assertEqual(
            client.threads[support["thread_id"]]["applied_tags"],
            [OTHER_TAG_ID],
        )

        client.calls.clear()
        second_actions = publisher(client, apply=True, state=state).run()
        self.assertEqual(second_actions, [])
        self.assertEqual(
            [call for call in client.calls if call[0] != "GET"],
            [],
        )

    def test_forum_reference_posts_are_locked_and_exactly_tagged(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        guidelines = state["resources"]["forum_posts"][
            publish_content.GUIDELINES_POST_KEY
        ]
        thread = client.threads[guidelines["thread_id"]]
        thread["applied_tags"] = [
            OTHER_TAG_ID,
            "400000000000000002",
        ]
        thread["thread_metadata"]["locked"] = False

        actions = publisher(client, apply=True, state=state).run()

        self.assertIn(
            "apply exact 'Other' tag to 'Help forum guidelines'",
            actions,
        )
        self.assertIn("lock 'Help forum guidelines' forum post", actions)
        self.assertEqual(thread["applied_tags"], [OTHER_TAG_ID])
        self.assertTrue(thread["thread_metadata"]["locked"])

    def test_fresh_apply_written_state_is_idempotent(self) -> None:
        client = FakeClient(require_tag=True)
        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            publisher(
                client,
                apply=True,
                state_path=state_path,
            ).run()
            state = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )

            client.calls.clear()
            actions = publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
            ).run()

        self.assertEqual(actions, [])
        self.assertEqual(
            [call for call in client.calls if call[0] != "GET"],
            [],
        )

    def test_all_message_writes_disable_allowed_mentions(self) -> None:
        client = FakeClient()
        with tempfile.TemporaryDirectory() as temporary:
            publisher(
                client,
                apply=True,
                state_path=Path(temporary) / "state.json",
            ).run()
        message_writes = [
            payload
            for method, path, payload in client.calls
            if (
                method in {"POST", "PATCH"}
                and "/messages" in path
            )
            or (method == "POST" and path.endswith("/threads"))
        ]
        self.assertGreater(len(message_writes), 0)
        for payload in message_writes:
            if "message" in payload:
                payload = payload["message"]
            self.assertEqual(payload["allowed_mentions"], {"parse": []})

    def test_standard_messages_use_current_pin_route(self) -> None:
        client = FakeClient()
        with tempfile.TemporaryDirectory() as temporary:
            publisher(
                client,
                apply=True,
                state_path=Path(temporary) / "state.json",
            ).run()
        pin_paths = [
            path
            for method, path, _payload in client.calls
            if method == "PUT"
        ]
        self.assertEqual(len(pin_paths), 8)
        self.assertTrue(
            all("/messages/pins/" in path for path in pin_paths)
        )

    def test_edit_is_idempotent(self) -> None:
        client = FakeClient()
        state = complete_state(client, stale_key="faq")
        first_actions = publisher(client, apply=True, state=state).run()
        edits = [
            call
            for call in client.calls
            if call[0] == "PATCH" and "/messages/" in call[1]
        ]
        self.assertEqual(len(edits), 1)
        self.assertIn("update faq message chunk 1", first_actions)

        client.calls.clear()
        second_actions = publisher(client, apply=True, state=state).run()
        mutations = [
            call for call in client.calls if call[0] != "GET"
        ]
        self.assertEqual(second_actions, [])
        self.assertEqual(mutations, [])

    def test_replace_dry_run_lists_only_unmanaged_standard_messages(
        self,
    ) -> None:
        client = FakeClient()
        state = complete_state(client)
        start_id = core_state()["resources"]["channels"]["start-here"]["id"]
        unmanaged_id = client._id()
        client.messages[(start_id, unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": start_id,
            "content": "old unmanaged content",
            "pinned": True,
        }
        forum_user_message_id = client._id()
        client.messages[(client.help_forum["id"], forum_user_message_id)] = {
            "id": forum_user_message_id,
            "channel_id": client.help_forum["id"],
            "content": "forum content must remain",
            "pinned": False,
        }

        actions = publisher(
            client,
            apply=False,
            state=state,
            replace_existing_content=True,
        ).run()

        self.assertEqual(
            [
                action
                for action in actions
                if action.startswith("delete unmanaged message")
            ],
            [
                f"delete unmanaged message {unmanaged_id} from #start-here"
            ],
        )
        self.assertNotIn(
            "DELETE",
            {method for method, _path, _payload in client.calls},
        )
        self.assertFalse(any(
            path.startswith(
                f"/channels/{client.help_forum['id']}/messages?"
            )
            for method, path, _payload in client.calls
            if method == "GET"
        ))

    def test_replace_preserves_security_response_incident_history(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        channel_id = core_state()["resources"]["channels"][
            "security-response"
        ]["id"]
        incident_id = client._id()
        client.messages[(channel_id, incident_id)] = {
            "id": incident_id,
            "channel_id": channel_id,
            "content": "private incident coordination",
            "pinned": False,
        }

        with tempfile.TemporaryDirectory() as temporary:
            actions = publisher(
                client,
                apply=True,
                state=state,
                rollback_dir=Path(temporary),
                replace_existing_content=True,
            ).run()

        self.assertIn((channel_id, incident_id), client.messages)
        self.assertFalse(any(
            incident_id in action
            for action in actions
        ))
        self.assertFalse(any(
            method == "GET"
            and path.startswith(f"/channels/{channel_id}/messages?")
            for method, path, _payload in client.calls
        ))

    def test_replace_fails_when_history_omits_managed_message(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        faq_id = core_state()["resources"]["channels"]["faq"]["id"]
        client.history_responses[faq_id] = []

        with self.assertRaisesRegex(
            publish_content.DiscordAPIError,
            "omitted publisher-owned message",
        ):
            publisher(
                client,
                apply=False,
                state=state,
                replace_existing_content=True,
            ).run()

        self.assertFalse(any(
            method != "GET"
            for method, _path, _payload in client.calls
        ))

    def test_replace_refetch_detects_concurrent_message_edit(self) -> None:
        class RaceClient(FakeClient):
            def __init__(self) -> None:
                super().__init__()
                self.target_channel = ""
                self.target_message = ""
                self.history_reads = 0

            def request(
                self,
                method: str,
                path: str,
                payload: Any = None,
                *,
                reason: str | None = None,
            ) -> Any:
                if (
                    method == "GET"
                    and self.target_channel
                    and path.startswith(
                        f"/channels/{self.target_channel}/messages?"
                    )
                ):
                    self.history_reads += 1
                    if self.history_reads == 2:
                        self.messages[(
                            self.target_channel,
                            self.target_message,
                        )]["reactions"] = [
                            {
                                "count": 1,
                                "me": False,
                                "emoji": {"id": None, "name": "👍"},
                            }
                        ]
                return super().request(
                    method,
                    path,
                    payload,
                    reason=reason,
                )

        client = RaceClient()
        state = complete_state(client)
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        unmanaged_id = client._id()
        client.target_channel = rules_id
        client.target_message = unmanaged_id
        client.messages[(rules_id, unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": rules_id,
            "content": "original legacy text",
            "pinned": False,
        }

        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                publish_content.DiscordAPIError,
                "changed after backup",
            ):
                publisher(
                    client,
                    apply=True,
                    state=state,
                    rollback_dir=Path(temporary),
                    replace_existing_content=True,
                ).run()

        self.assertIn((rules_id, unmanaged_id), client.messages)
        self.assertFalse(any(
            method == "DELETE"
            for method, _path, _payload in client.calls
        ))

    def test_replace_apply_snapshots_full_payload_before_delete(self) -> None:
        client = FakeClient()
        state = complete_state(client, stale_key="rules")
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        unmanaged_id = client._id()
        client.messages[(rules_id, unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": rules_id,
            "content": "legacy rules body with recovery detail",
            "pinned": True,
            "author": {"id": "500000000000000001"},
        }
        managed_id = state["resources"]["standard_messages"]["rules"][
            "chunks"
        ][0]["message_id"]

        with tempfile.TemporaryDirectory() as temporary:
            rollback_dir = Path(temporary) / "rollbacks"
            publisher(
                client,
                apply=True,
                state=state,
                rollback_dir=rollback_dir,
                replace_existing_content=True,
            ).run()

            snapshots = list(rollback_dir.glob(
                "pre-content-replacement-*.json"
            ))
            self.assertEqual(len(snapshots), 1)
            self.assertEqual(os.stat(snapshots[0]).st_mode & 0o777, 0o600)
            snapshot = json.loads(snapshots[0].read_text(encoding="utf-8"))
            deleted = snapshot["deleted_messages"]
            self.assertEqual(len(deleted), 1)
            self.assertEqual(
                deleted[0]["message"]["content"],
                "legacy rules body with recovery detail",
            )

        self.assertNotIn((rules_id, unmanaged_id), client.messages)
        self.assertIn((rules_id, managed_id), client.messages)
        patch_index = next(
            index
            for index, call in enumerate(client.calls)
            if call[0] == "PATCH" and "/messages/" in call[1]
        )
        delete_index = next(
            index
            for index, call in enumerate(client.calls)
            if call[0] == "DELETE"
        )
        self.assertLess(patch_index, delete_index)

    def test_replace_backs_up_attachment_bytes_before_delete(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        unmanaged_id = client._id()
        attachment_id = client._id()
        attachment_body = b"legacy attachment"
        attachment_url = (
            "https://cdn.discordapp.com/attachments/"
            f"{rules_id}/{attachment_id}/legacy.txt?ex=1&is=1&hm=1"
        )
        client.messages[(rules_id, unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": rules_id,
            "content": "legacy message with attachment",
            "attachments": [
                {
                    "id": attachment_id,
                    "filename": "legacy.txt",
                    "size": len(attachment_body),
                    "url": attachment_url,
                }
            ],
            "pinned": False,
        }

        class FakeResponse:
            def __init__(self) -> None:
                self.remaining = attachment_body

            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, *_args: Any) -> None:
                return None

            def geturl(self) -> str:
                return attachment_url

            def read(self, _size: int) -> bytes:
                result = self.remaining
                self.remaining = b""
                return result

        class FakeOpener:
            def __init__(self) -> None:
                self.requests: list[urllib.request.Request] = []

            def open(
                self,
                request: urllib.request.Request,
                *,
                timeout: int,
            ) -> FakeResponse:
                self.requests.append(request)
                self.assert_timeout = timeout
                return FakeResponse()

        with tempfile.TemporaryDirectory() as temporary:
            rollback_dir = Path(temporary) / "rollbacks"
            fake_opener = FakeOpener()
            with mock.patch.object(
                publish_content.urllib.request,
                "build_opener",
                return_value=fake_opener,
            ) as build_opener:
                publisher(
                    client,
                    apply=True,
                    state=state,
                    rollback_dir=rollback_dir,
                    replace_existing_content=True,
                ).run()

            snapshot_path = next(rollback_dir.glob(
                "pre-content-replacement-*.json"
            ))
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
            backup = snapshot["attachment_backups"][0]
            attachment_path = rollback_dir / backup["local_path"]
            self.assertEqual(attachment_path.read_bytes(), attachment_body)
            self.assertEqual(
                os.stat(attachment_path).st_mode & 0o777,
                0o600,
            )
            self.assertEqual(
                os.stat(attachment_path.parent).st_mode & 0o777,
                0o700,
            )
            self.assertEqual(
                backup["sha256"],
                publish_content.hashlib.sha256(
                    attachment_body
                ).hexdigest(),
            )
            build_opener.assert_called_once()
            self.assertEqual(len(fake_opener.requests), 1)
            self.assertNotIn(
                "Authorization",
                fake_opener.requests[0].headers,
            )
            self.assertEqual(fake_opener.assert_timeout, 60)

        self.assertNotIn((rules_id, unmanaged_id), client.messages)

    def test_short_attachment_backup_refuses_all_discord_mutations(
        self,
    ) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        unmanaged_id = client._id()
        attachment_id = client._id()
        attachment_url = (
            "https://cdn.discordapp.com/attachments/"
            f"{rules_id}/{attachment_id}/legacy.txt"
        )
        client.messages[(rules_id, unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": rules_id,
            "content": "legacy",
            "attachments": [
                {
                    "id": attachment_id,
                    "filename": "legacy.txt",
                    "size": 10,
                    "url": attachment_url,
                }
            ],
            "pinned": False,
        }

        class ShortResponse:
            used = False

            def __enter__(self) -> "ShortResponse":
                return self

            def __exit__(self, *_args: Any) -> None:
                return None

            def geturl(self) -> str:
                return attachment_url

            def read(self, _size: int) -> bytes:
                if self.used:
                    return b""
                self.used = True
                return b"short"

        opener = mock.Mock()
        opener.open.return_value = ShortResponse()
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(
                publish_content.urllib.request,
                "build_opener",
                return_value=opener,
            ):
                with self.assertRaisesRegex(
                    publish_content.DiscordAPIError,
                    "was 5 bytes, expected 10",
                ):
                    publisher(
                        client,
                        apply=True,
                        state=state,
                        rollback_dir=Path(temporary),
                        replace_existing_content=True,
                    ).run()

        self.assertFalse(any(
            method != "GET"
            for method, _path, _payload in client.calls
        ))

    def test_unsafe_attachment_url_refuses_all_discord_mutations(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        unmanaged_id = client._id()
        attachment_id = client._id()
        client.messages[(rules_id, unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": rules_id,
            "content": "legacy",
            "attachments": [
                {
                    "id": attachment_id,
                    "filename": "legacy.txt",
                    "size": 1,
                    "url": "https://example.test/attachments/file",
                }
            ],
            "pinned": False,
        }

        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                publish_content.DiscordAPIError,
                "unsafe Discord attachment URL",
            ):
                publisher(
                    client,
                    apply=True,
                    state=state,
                    rollback_dir=Path(temporary),
                    replace_existing_content=True,
                ).run()

        self.assertFalse(any(
            method != "GET"
            for method, _path, _payload in client.calls
        ))

    def test_nested_snapshot_attachment_is_backed_up(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        unmanaged_id = client._id()
        attachment_id = client._id()
        attachment_body = b"forwarded file"
        attachment_url = (
            "https://cdn.discordapp.com/attachments/"
            f"{rules_id}/{attachment_id}/forwarded.txt"
        )
        client.messages[(rules_id, unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": rules_id,
            "content": "forwarded legacy message",
            "message_snapshots": [
                {
                    "message": {
                        "content": "snapshot",
                        "attachments": [
                            {
                                "id": attachment_id,
                                "filename": "forwarded.txt",
                                "size": len(attachment_body),
                                "url": attachment_url,
                            }
                        ],
                    }
                }
            ],
            "pinned": False,
        }

        class NestedResponse:
            used = False

            def __enter__(self) -> "NestedResponse":
                return self

            def __exit__(self, *_args: Any) -> None:
                return None

            def geturl(self) -> str:
                return attachment_url

            def read(self, _size: int) -> bytes:
                if self.used:
                    return b""
                self.used = True
                return attachment_body

        opener = mock.Mock()
        opener.open.return_value = NestedResponse()
        with tempfile.TemporaryDirectory() as temporary:
            rollback_dir = Path(temporary)
            with mock.patch.object(
                publish_content.urllib.request,
                "build_opener",
                return_value=opener,
            ):
                publisher(
                    client,
                    apply=True,
                    state=state,
                    rollback_dir=rollback_dir,
                    replace_existing_content=True,
                ).run()
            snapshot_path = next(rollback_dir.glob(
                "pre-content-replacement-*.json"
            ))
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
            backup = snapshot["attachment_backups"][0]
            self.assertEqual(
                (rollback_dir / backup["local_path"]).read_bytes(),
                attachment_body,
            )

        self.assertNotIn((rules_id, unmanaged_id), client.messages)

    def test_non_deletable_system_message_blocks_replacement(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        system_id = client._id()
        client.messages[(rules_id, system_id)] = {
            "id": system_id,
            "channel_id": rules_id,
            "content": "",
            "type": 21,
            "pinned": False,
        }

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "non-deletable Discord message type 21",
        ):
            publisher(
                client,
                apply=False,
                state=state,
                replace_existing_content=True,
            ).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_message_with_child_thread_blocks_replacement(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules_id = core_state()["resources"]["channels"]["rules"]["id"]
        message_id = client._id()
        client.messages[(rules_id, message_id)] = {
            "id": message_id,
            "channel_id": rules_id,
            "content": "legacy message with discussion thread",
            "flags": publish_content.HAS_THREAD_MESSAGE_FLAG,
            "thread": {
                "id": message_id,
                "parent_id": rules_id,
            },
            "pinned": False,
        }

        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "owns a Discord thread",
        ):
            publisher(
                client,
                apply=False,
                state=state,
                replace_existing_content=True,
            ).run()

        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_replace_deletes_before_pinning_desired_message(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules = state["resources"]["standard_messages"]["rules"]
        desired_id = rules["chunks"][0]["message_id"]
        client.messages[(rules["channel_id"], desired_id)]["pinned"] = False
        unmanaged_id = client._id()
        client.messages[(rules["channel_id"], unmanaged_id)] = {
            "id": unmanaged_id,
            "channel_id": rules["channel_id"],
            "content": "legacy pinned message",
            "pinned": True,
        }

        with tempfile.TemporaryDirectory() as temporary:
            publisher(
                client,
                apply=True,
                state=state,
                rollback_dir=Path(temporary),
                replace_existing_content=True,
            ).run()

        delete_index = next(
            index
            for index, call in enumerate(client.calls)
            if call[0] == "DELETE" and unmanaged_id in call[1]
        )
        pin_index = next(
            index
            for index, call in enumerate(client.calls)
            if call[0] == "PUT" and desired_id in call[1]
        )
        self.assertLess(delete_index, pin_index)

    def test_replace_removes_only_the_notice_created_by_its_pin(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules = state["resources"]["standard_messages"]["rules"]
        desired_id = rules["chunks"][0]["message_id"]
        client.messages[(rules["channel_id"], desired_id)]["pinned"] = False

        with tempfile.TemporaryDirectory() as temporary:
            actions = publisher(
                client,
                apply=True,
                state=state,
                rollback_dir=Path(temporary),
                replace_existing_content=True,
            ).run()

        notice_id = client.pin_notice_ids[-1]
        self.assertNotIn((rules["channel_id"], notice_id), client.messages)
        self.assertIn("delete generated rules pin notice", actions)
        pin_index = next(
            index
            for index, call in enumerate(client.calls)
            if call[0] == "PUT" and desired_id in call[1]
        )
        notice_delete_index = next(
            index
            for index, call in enumerate(client.calls)
            if call[0] == "DELETE" and notice_id in call[1]
        )
        self.assertLess(pin_index, notice_delete_index)

    def test_existing_pin_notice_is_backed_up_then_deleted(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules = state["resources"]["standard_messages"]["rules"]
        desired_id = rules["chunks"][0]["message_id"]
        notice_id = client._id()
        client.messages[(rules["channel_id"], notice_id)] = {
            "id": notice_id,
            "channel_id": rules["channel_id"],
            "content": "",
            "pinned": False,
            "type": publish_content.CHANNEL_PINNED_MESSAGE_TYPE,
            "author": {"id": BOT_USER_ID, "bot": True},
            "message_reference": {
                "channel_id": rules["channel_id"],
                "message_id": desired_id,
            },
        }

        with tempfile.TemporaryDirectory() as temporary:
            rollback_dir = Path(temporary)
            publisher(
                client,
                apply=True,
                state=state,
                rollback_dir=rollback_dir,
                replace_existing_content=True,
            ).run()
            snapshot_path = next(rollback_dir.glob(
                "pre-content-replacement-*.json"
            ))
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))

        self.assertNotIn((rules["channel_id"], notice_id), client.messages)
        self.assertIn(
            notice_id,
            {
                item["message"]["id"]
                for item in snapshot["deleted_messages"]
            },
        )

    def test_unmatched_or_concurrent_post_pin_content_is_retained(
        self,
    ) -> None:
        class PostPinRaceClient(FakeClient):
            def __init__(self, mode: str) -> None:
                super().__init__()
                self.mode = mode
                self.extra_id = ""

            def request(
                self,
                method: str,
                path: str,
                payload: Any = None,
                *,
                reason: str | None = None,
            ) -> Any:
                result = super().request(
                    method,
                    path,
                    payload,
                    reason=reason,
                )
                if method != "PUT" or "/messages/pins/" not in path:
                    return result
                parsed = urllib.parse.urlsplit(path)
                parts = parsed.path.strip("/").split("/")
                notice_id = self.pin_notice_ids[-1]
                notice = self.messages[(parts[1], notice_id)]
                if self.mode == "wrong-author":
                    notice["author"] = {"id": "500000000000000001"}
                    self.extra_id = notice_id
                elif self.mode == "wrong-reference":
                    notice["message_reference"]["message_id"] = (
                        "500000000000000002"
                    )
                    self.extra_id = notice_id
                elif self.mode == "wrong-type":
                    notice["type"] = 0
                    self.extra_id = notice_id
                else:
                    self.extra_id = self._id()
                    self.messages[(parts[1], self.extra_id)] = {
                        "id": self.extra_id,
                        "channel_id": parts[1],
                        "content": "concurrent member message",
                        "pinned": False,
                        "author": {"id": "500000000000000003"},
                    }
                return result

        for mode in (
            "wrong-author",
            "wrong-reference",
            "wrong-type",
            "concurrent",
        ):
            with self.subTest(mode=mode):
                client = PostPinRaceClient(mode)
                state = complete_state(client)
                rules = state["resources"]["standard_messages"]["rules"]
                desired_id = rules["chunks"][0]["message_id"]
                client.messages[
                    (rules["channel_id"], desired_id)
                ]["pinned"] = False

                with tempfile.TemporaryDirectory() as temporary:
                    with self.assertRaisesRegex(
                        publish_content.DiscordAPIError,
                        (
                            "changed during publication|"
                            "did not expose the generated"
                        ),
                    ):
                        publisher(
                            client,
                            apply=True,
                            state=state,
                            rollback_dir=Path(temporary),
                            replace_existing_content=True,
                        ).run()

                self.assertIn(
                    (rules["channel_id"], client.extra_id),
                    client.messages,
                )
                self.assertFalse(any(
                    method == "DELETE" and client.extra_id in path
                    for method, path, _payload in client.calls
                ))

    def test_generated_pin_notice_delete_accepts_404_race(self) -> None:
        class AlreadyDeletedNoticeClient(FakeClient):
            def request(
                self,
                method: str,
                path: str,
                payload: Any = None,
                *,
                reason: str | None = None,
            ) -> Any:
                if (
                    method == "DELETE"
                    and self.pin_notice_ids
                    and path.endswith(f"/{self.pin_notice_ids[-1]}")
                ):
                    parsed = urllib.parse.urlsplit(path)
                    parts = parsed.path.strip("/").split("/")
                    self.calls.append((method, path, copy.deepcopy(payload)))
                    self.messages.pop((parts[1], parts[3]), None)
                    raise publish_content.DiscordAPIError(
                        "not found",
                        status=404,
                        code=10008,
                    )
                return super().request(
                    method,
                    path,
                    payload,
                    reason=reason,
                )

        client = AlreadyDeletedNoticeClient()
        state = complete_state(client)
        rules = state["resources"]["standard_messages"]["rules"]
        desired_id = rules["chunks"][0]["message_id"]
        client.messages[(rules["channel_id"], desired_id)]["pinned"] = False

        with tempfile.TemporaryDirectory() as temporary:
            actions = publisher(
                client,
                apply=True,
                state=state,
                rollback_dir=Path(temporary),
                replace_existing_content=True,
            ).run()

        self.assertIn("delete generated rules pin notice", actions)
        self.assertNotIn(
            (rules["channel_id"], client.pin_notice_ids[-1]),
            client.messages,
        )

    def test_multiple_generated_pin_notices_fail_without_deleting(self) -> None:
        class DuplicateNoticeClient(FakeClient):
            def request(
                self,
                method: str,
                path: str,
                payload: Any = None,
                *,
                reason: str | None = None,
            ) -> Any:
                result = super().request(
                    method,
                    path,
                    payload,
                    reason=reason,
                )
                if method == "PUT" and "/messages/pins/" in path:
                    parsed = urllib.parse.urlsplit(path)
                    parts = parsed.path.strip("/").split("/")
                    original = self.messages[
                        (parts[1], self.pin_notice_ids[-1])
                    ]
                    duplicate_id = self._id()
                    duplicate = copy.deepcopy(original)
                    duplicate["id"] = duplicate_id
                    self.pin_notice_ids.append(duplicate_id)
                    self.messages[(parts[1], duplicate_id)] = duplicate
                return result

        client = DuplicateNoticeClient()
        state = complete_state(client)
        rules = state["resources"]["standard_messages"]["rules"]
        desired_id = rules["chunks"][0]["message_id"]
        client.messages[(rules["channel_id"], desired_id)]["pinned"] = False

        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                publish_content.DiscordAPIError,
                "multiple pin notices",
            ):
                publisher(
                    client,
                    apply=True,
                    state=state,
                    rollback_dir=Path(temporary),
                    replace_existing_content=True,
                ).run()

        self.assertTrue(all(
            (rules["channel_id"], notice_id) in client.messages
            for notice_id in client.pin_notice_ids
        ))
        self.assertFalse(any(
            method == "DELETE"
            for method, _path, _payload in client.calls
        ))

    def test_generated_pin_notice_lookup_retries_until_visible(self) -> None:
        class DelayedNoticeClient(FakeClient):
            def __init__(self) -> None:
                super().__init__()
                self.pin_completed = False
                self.hidden_reads = 0

            def request(
                self,
                method: str,
                path: str,
                payload: Any = None,
                *,
                reason: str | None = None,
            ) -> Any:
                result = super().request(
                    method,
                    path,
                    payload,
                    reason=reason,
                )
                if method == "PUT" and "/messages/pins/" in path:
                    self.pin_completed = True
                if (
                    method == "GET"
                    and self.pin_completed
                    and "/messages?" in path
                    and self.hidden_reads < 2
                ):
                    self.hidden_reads += 1
                    return [
                        message
                        for message in result
                        if str(message["id"]) not in self.pin_notice_ids
                    ]
                return result

        client = DelayedNoticeClient()
        state = complete_state(client)
        rules = state["resources"]["standard_messages"]["rules"]
        desired_id = rules["chunks"][0]["message_id"]
        client.messages[(rules["channel_id"], desired_id)]["pinned"] = False

        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(publish_content.time, "sleep"):
                publisher(
                    client,
                    apply=True,
                    state=state,
                    rollback_dir=Path(temporary),
                    replace_existing_content=True,
                ).run()

        self.assertEqual(client.hidden_reads, 2)
        self.assertNotIn(
            (rules["channel_id"], client.pin_notice_ids[-1]),
            client.messages,
        )

    def test_final_verification_detects_content_edit_or_unpin(self) -> None:
        class FinalVerificationRaceClient(FakeClient):
            def __init__(self, mode: str) -> None:
                super().__init__()
                self.mode = mode
                self.target: tuple[str, str] | None = None

            def request(
                self,
                method: str,
                path: str,
                payload: Any = None,
                *,
                reason: str | None = None,
            ) -> Any:
                result = super().request(
                    method,
                    path,
                    payload,
                    reason=reason,
                )
                if (
                    method == "DELETE"
                    and self.pin_notice_ids
                    and path.endswith(f"/{self.pin_notice_ids[-1]}")
                    and self.target is not None
                ):
                    if self.mode == "content":
                        self.messages[self.target]["content"] = (
                            "concurrent bot-token edit"
                        )
                    else:
                        self.messages[self.target]["pinned"] = False
                return result

        for mode, expected_error in (
            ("content", "content changed during publication"),
            ("unpin", "was unpinned during publication"),
        ):
            with self.subTest(mode=mode):
                client = FinalVerificationRaceClient(mode)
                state = complete_state(client)
                rules = state["resources"]["standard_messages"]["rules"]
                desired_id = rules["chunks"][0]["message_id"]
                client.target = (rules["channel_id"], desired_id)
                client.messages[client.target]["pinned"] = False

                with tempfile.TemporaryDirectory() as temporary:
                    with self.assertRaisesRegex(
                        publish_content.DiscordAPIError,
                        expected_error,
                    ):
                        publisher(
                            client,
                            apply=True,
                            state=state,
                            rollback_dir=Path(temporary),
                            replace_existing_content=True,
                        ).run()

                self.assertIn(client.target, client.messages)

    def test_deleted_managed_message_is_recreated_and_converges(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        faq = state["resources"]["standard_messages"]["faq"]
        deleted_id = faq["chunks"][0]["message_id"]
        del client.messages[(faq["channel_id"], deleted_id)]

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            first_actions = publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
            ).run()
            persisted = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )
            replacement_id = persisted["resources"]["standard_messages"][
                "faq"
            ]["chunks"][0]["message_id"]
            client.calls.clear()
            second_actions = publisher(
                client,
                apply=True,
                state=persisted,
                state_path=state_path,
            ).run()

        self.assertTrue(any(
            action.startswith("create faq message chunk")
            for action in first_actions
        ))
        self.assertNotEqual(replacement_id, deleted_id)
        self.assertEqual(second_actions, [])
        self.assertEqual(
            [call for call in client.calls if call[0] != "GET"],
            [],
        )

    def test_deleted_managed_forum_post_is_recreated_and_converges(
        self,
    ) -> None:
        client = FakeClient()
        state = complete_state(client)
        support = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        deleted_thread_id = support["thread_id"]
        del client.threads[deleted_thread_id]
        for key in list(client.messages):
            if key[0] == deleted_thread_id:
                del client.messages[key]

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            first_actions = publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
            ).run()
            persisted = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )
            replacement_thread_id = persisted["resources"]["forum_posts"][
                publish_content.SUPPORT_POST_KEY
            ]["thread_id"]
            client.calls.clear()
            second_actions = publisher(
                client,
                apply=True,
                state=persisted,
                state_path=state_path,
            ).run()

        self.assertIn(
            "create 'Support request template' forum post",
            first_actions,
        )
        self.assertNotEqual(replacement_thread_id, deleted_thread_id)
        self.assertEqual(second_actions, [])
        self.assertEqual(
            [call for call in client.calls if call[0] != "GET"],
            [],
        )

    def test_pending_forum_thread_is_adopted_without_duplicate(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        support = state["resources"]["forum_posts"].pop(
            publish_content.SUPPORT_POST_KEY
        )
        _publications, forum_publications = loaded_content()
        support_publication = next(
            publication
            for publication in forum_publications
            if publication.key == publish_content.SUPPORT_POST_KEY
        )
        state["resources"]["pending_creates"] = {
            publish_content.SUPPORT_POST_KEY: {
                "kind": "forum-thread",
                "forum_channel_id": client.help_forum["id"],
                "name": support_publication.name,
                "chunk_index": 0,
                "content_sha256": publish_content._content_hash(
                    support_publication.chunks[0]
                ),
            }
        }

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
            ).run()
            persisted = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )

        self.assertEqual(
            persisted["resources"]["forum_posts"][
                publish_content.SUPPORT_POST_KEY
            ]["thread_id"],
            support["thread_id"],
        )
        self.assertEqual(
            persisted["resources"]["pending_creates"],
            {},
        )
        self.assertFalse(any(
            method == "POST"
            and path.endswith("/threads")
            and payload["name"] == support_publication.name
            for method, path, payload in client.calls
        ))

    def test_pending_forum_followup_is_adopted_without_duplicate(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        support = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        orphan_content = "orphaned bot follow-up from interrupted apply"
        orphan_id = client._id()
        client.messages[(support["thread_id"], orphan_id)] = {
            "id": orphan_id,
            "channel_id": support["thread_id"],
            "content": orphan_content,
            "pinned": False,
            "author": {"id": BOT_USER_ID, "bot": True},
        }
        state["resources"]["pending_creates"] = {
            publish_content.SUPPORT_POST_KEY: {
                "kind": "forum-message",
                "thread_id": support["thread_id"],
                "chunk_index": len(support["chunks"]),
                "content_sha256": publish_content._content_hash(
                    orphan_content
                ),
            }
        }

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
            ).run()
            persisted = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )

        self.assertIn(
            orphan_id,
            {
                record["message_id"]
                for record in persisted["resources"]["forum_posts"][
                    publish_content.SUPPORT_POST_KEY
                ]["chunks"]
            },
        )
        self.assertEqual(
            persisted["resources"]["pending_creates"],
            {},
        )
        self.assertFalse(any(
            method == "POST"
            and path
            == f"/channels/{support['thread_id']}/messages"
            for method, path, _payload in client.calls
        ))

    def test_pending_non_authoritative_starter_is_adopted(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        feature = state["resources"]["standard_messages"][
            "feature-discussion"
        ]
        orphan_id = feature["chunks"][0]["message_id"]
        feature["chunks"] = []
        _publications, _forum_publications = loaded_content()
        content = client.messages[(feature["channel_id"], orphan_id)]["content"]
        state["resources"]["pending_creates"] = {
            "feature-discussion": {
                "kind": "standard-message",
                "channel_id": feature["channel_id"],
                "chunk_index": 0,
                "content_sha256": publish_content._content_hash(content),
            }
        }

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
            ).run()
            persisted = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )

        self.assertEqual(
            persisted["resources"]["standard_messages"][
                "feature-discussion"
            ]["chunks"][0]["message_id"],
            orphan_id,
        )
        self.assertFalse(any(
            method == "POST"
            and path == f"/channels/{feature['channel_id']}/messages"
            for method, path, _payload in client.calls
        ))

    def test_pending_recovery_dry_run_does_not_write_state(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        feature = state["resources"]["standard_messages"][
            "feature-discussion"
        ]
        orphan_id = feature["chunks"][0]["message_id"]
        feature["chunks"] = []
        content = client.messages[(feature["channel_id"], orphan_id)]["content"]
        state["resources"]["pending_creates"] = {
            "feature-discussion": {
                "kind": "standard-message",
                "channel_id": feature["channel_id"],
                "chunk_index": 0,
                "content_sha256": publish_content._content_hash(content),
            }
        }

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            publish_content._write_private_json(state_path, state)
            before = state_path.read_bytes()
            loaded = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )
            actions = publisher(
                client,
                apply=False,
                state=loaded,
                state_path=state_path,
            ).run()
            after = state_path.read_bytes()

        self.assertEqual(after, before)
        self.assertTrue(any(
            action.startswith(
                "adopt pending bot-owned feature-discussion create"
            )
            for action in actions
        ))
        self.assertTrue(all(
            method == "GET"
            for method, _path, _payload in client.calls
        ))

    def test_content_state_lock_rejects_concurrent_apply(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            with publish_content._content_state_lock(state_path):
                with self.assertRaisesRegex(
                    publish_content.ManifestError,
                    "another Discord content apply",
                ):
                    with publish_content._content_state_lock(state_path):
                        self.fail("second lock unexpectedly succeeded")
            lock_path = state_path.with_name(f"{state_path.name}.lock")
            self.assertEqual(os.stat(lock_path).st_mode & 0o777, 0o600)

    def test_replace_prunes_obsolete_managed_chunks_and_converges(
        self,
    ) -> None:
        client = FakeClient()
        state = complete_state(client)
        rules = state["resources"]["standard_messages"]["rules"]
        rules_obsolete_id = client._id()
        client.messages[(rules["channel_id"], rules_obsolete_id)] = {
            "id": rules_obsolete_id,
            "channel_id": rules["channel_id"],
            "content": "obsolete managed rules follow-up",
            "pinned": False,
            "author": {"id": BOT_USER_ID, "bot": True},
        }
        rules["chunks"].append({
            "message_id": rules_obsolete_id,
            "content_sha256": "old",
        })

        support = state["resources"]["forum_posts"][
            publish_content.SUPPORT_POST_KEY
        ]
        support_obsolete_id = client._id()
        client.messages[(support["thread_id"], support_obsolete_id)] = {
            "id": support_obsolete_id,
            "channel_id": support["thread_id"],
            "content": "obsolete managed support follow-up",
            "pinned": False,
            "author": {"id": BOT_USER_ID, "bot": True},
        }
        support["chunks"].append({
            "message_id": support_obsolete_id,
            "content_sha256": "old",
        })

        with tempfile.TemporaryDirectory() as temporary:
            state_path = Path(temporary) / "state.json"
            rollback_dir = Path(temporary) / "rollbacks"
            first_actions = publisher(
                client,
                apply=True,
                state=state,
                state_path=state_path,
                rollback_dir=rollback_dir,
                replace_existing_content=True,
            ).run()

            self.assertTrue(any(
                f"obsolete managed message {rules_obsolete_id}" in action
                for action in first_actions
            ))
            self.assertTrue(any(
                f"obsolete managed message {support_obsolete_id}" in action
                for action in first_actions
            ))
            persisted = publish_content.load_content_state(
                state_path,
                GUILD_ID,
            )
            self.assertNotIn(
                rules_obsolete_id,
                {
                    record["message_id"]
                    for record in persisted["resources"][
                        "standard_messages"
                    ]["rules"]["chunks"]
                },
            )
            self.assertNotIn(
                support_obsolete_id,
                {
                    record["message_id"]
                    for record in persisted["resources"]["forum_posts"][
                        publish_content.SUPPORT_POST_KEY
                    ]["chunks"]
                },
            )

            client.calls.clear()
            second_actions = publisher(
                client,
                apply=True,
                state=persisted,
                state_path=state_path,
                rollback_dir=rollback_dir,
                replace_existing_content=True,
            ).run()

        self.assertNotIn(
            (rules["channel_id"], rules_obsolete_id),
            client.messages,
        )
        self.assertNotIn(
            (support["thread_id"], support_obsolete_id),
            client.messages,
        )
        self.assertEqual(second_actions, [])
        self.assertEqual(
            [call for call in client.calls if call[0] != "GET"],
            [],
        )

    def test_replace_paginates_standard_channel_history(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        start_id = core_state()["resources"]["channels"]["start-here"]["id"]
        unmanaged_ids = []
        for _index in range(101):
            message_id = client._id()
            unmanaged_ids.append(message_id)
            client.messages[(start_id, message_id)] = {
                "id": message_id,
                "channel_id": start_id,
                "content": "legacy",
                "pinned": False,
            }

        actions = publisher(
            client,
            apply=False,
            state=state,
            replace_existing_content=True,
        ).run()

        deletions = [
            action
            for action in actions
            if action.startswith("delete unmanaged message")
        ]
        self.assertEqual(len(deletions), len(unmanaged_ids))
        start_history_reads = [
            path
            for method, path, _payload in client.calls
            if method == "GET"
            and path.startswith(f"/channels/{start_id}/messages?")
        ]
        self.assertEqual(len(start_history_reads), 2)
        self.assertIn("before=", start_history_reads[1])

    def test_replace_fails_closed_on_malformed_history(self) -> None:
        client = FakeClient()
        state = complete_state(client)
        faq_id = core_state()["resources"]["channels"]["faq"]["id"]
        client.history_responses[faq_id] = {"not": "a message list"}

        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                publish_content.DiscordAPIError,
                "malformed message history",
            ):
                publisher(
                    client,
                    apply=True,
                    state=state,
                    rollback_dir=Path(temporary),
                    replace_existing_content=True,
                ).run()

        self.assertFalse(any(
            method == "DELETE"
            for method, _path, _payload in client.calls
        ))


if __name__ == "__main__":
    unittest.main()
