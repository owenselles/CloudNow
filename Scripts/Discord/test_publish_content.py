#!/usr/bin/env python3
"""Focused standard-library tests for local Discord content publication."""

from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import publish_content  # noqa: E402


REPOSITORY_ROOT = SCRIPT_DIR.parents[1]
CONTENT_DIR = REPOSITORY_ROOT / "docs/community/discord/content"
GUILD_ID = "123456789012345678"


def core_state() -> dict[str, Any]:
    channels = {}
    for index, name in enumerate(
        ("start-here", "rules", "faq", "contributing", "help"),
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
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, Any]] = []
        self.messages: dict[tuple[str, str], dict[str, Any]] = {}
        self.threads: dict[str, dict[str, Any]] = {}
        self.next_id = 300000000000000000

    def _id(self) -> str:
        self.next_id += 1
        return str(self.next_id)

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

        parts = path.strip("/").split("/")
        if method == "GET" and len(parts) == 2 and parts[0] == "channels":
            return copy.deepcopy(self.threads[parts[1]])
        if (
            method == "GET"
            and len(parts) == 4
            and parts[0] == "channels"
            and parts[2] == "messages"
        ):
            return copy.deepcopy(self.messages[(parts[1], parts[3])])

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
            }
            self.messages[(parts[1], message_id)] = message
            return copy.deepcopy(message)

        if (
            method == "PATCH"
            and len(parts) == 4
            and parts[0] == "channels"
            and parts[2] == "messages"
        ):
            message = self.messages[(parts[1], parts[3])]
            message["content"] = payload["content"]
            return copy.deepcopy(message)

        if (
            method == "PUT"
            and len(parts) == 5
            and parts[0] == "channels"
            and parts[2:4] == ["messages", "pins"]
        ):
            self.messages[(parts[1], parts[4])]["pinned"] = True
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
            }
            thread = {
                "id": thread_id,
                "parent_id": parts[1],
                "name": payload["name"],
                "flags": 0,
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
            thread.update(payload)
            return copy.deepcopy(thread)

        raise AssertionError(f"unexpected {method} {path}")


def loaded_content() -> tuple[list[publish_content.Publication], tuple[str, ...]]:
    return publish_content.load_publications(
        CONTENT_DIR,
        "email moderators@example.test",
    )


def complete_state(
    client: FakeClient,
    *,
    stale_key: str | None = None,
) -> dict[str, Any]:
    publications, support_chunks = loaded_content()
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
            }
            records.append({"message_id": message_id, "content_sha256": "old"})
        standard[publication.key] = {
            "channel_id": channel_id,
            "chunks": records,
        }

    help_id = channels["help"]["id"]
    thread_id = client._id()
    support_records = []
    for content in support_chunks:
        message_id = thread_id if not support_records else client._id()
        client.messages[(thread_id, message_id)] = {
            "id": message_id,
            "channel_id": thread_id,
            "content": content,
            "pinned": False,
        }
        support_records.append(
            {"message_id": message_id, "content_sha256": "old"}
        )
    client.threads[thread_id] = {
        "id": thread_id,
        "parent_id": help_id,
        "name": publish_content.SUPPORT_POST_NAME,
        "flags": publish_content.PINNED_THREAD_FLAG,
    }
    return {
        "state_version": 1,
        "guild_id": GUILD_ID,
        "resources": {
            "standard_messages": standard,
            "forum_posts": {
                publish_content.SUPPORT_POST_KEY: {
                    "forum_channel_id": help_id,
                    "thread_id": thread_id,
                    "name": publish_content.SUPPORT_POST_NAME,
                    "chunks": support_records,
                }
            },
        },
    }


def publisher(
    client: FakeClient,
    *,
    apply: bool,
    state: dict[str, Any] | None = None,
    state_path: Path | None = None,
    rollback_dir: Path | None = None,
) -> publish_content.ContentPublisher:
    return publish_content.ContentPublisher(
        client,
        GUILD_ID,
        CONTENT_DIR,
        core_state(),
        appeal_method="email moderators@example.test",
        apply=apply,
        audit_reason="test",
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


class PublicationSafetyTests(unittest.TestCase):
    def test_dry_run_only_uses_get_requests(self) -> None:
        client = FakeClient()
        actions = publisher(client, apply=False).run()
        self.assertGreater(len(actions), 0)
        self.assertEqual({method for method, _path, _body in client.calls}, {"GET"})

    def test_state_channel_mismatch_fails_before_api_access(self) -> None:
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
        with self.assertRaisesRegex(
            publish_content.ManifestError,
            "different channel ID",
        ):
            publisher(client, apply=False, state=state).run()
        self.assertEqual(client.calls, [])

    def test_creates_forum_post_and_follow_up_chunks(self) -> None:
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
        self.assertEqual(len(creates), 1)
        self.assertEqual(creates[0][2]["name"], "Support request template")
        self.assertEqual(
            creates[0][2]["message"]["allowed_mentions"],
            {"parse": []},
        )
        thread_id = next(iter(client.threads))
        follow_ups = [
            call
            for call in client.calls
            if call[0] == "POST"
            and call[1] == f"/channels/{thread_id}/messages"
        ]
        self.assertEqual(len(follow_ups), 1)
        self.assertEqual(follow_ups[0][2]["allowed_mentions"], {"parse": []})
        self.assertTrue(
            client.threads[thread_id]["flags"]
            & publish_content.PINNED_THREAD_FLAG
        )

    def test_all_message_writes_disable_allowed_mentions(self) -> None:
        client = FakeClient()
        state = complete_state(client, stale_key="rules")
        publisher(client, apply=True, state=state).run()
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
        self.assertEqual(len(pin_paths), 4)
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


if __name__ == "__main__":
    unittest.main()
