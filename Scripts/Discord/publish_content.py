#!/usr/bin/env python3
"""Publish the managed CloudNow Discord content from a local machine.

Only message IDs recorded by this script are ever edited. Existing messages are
not searched by content or title, and nothing is deleted.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from provision import (
    DiscordAPIError,
    DiscordClient,
    ManifestError,
    _write_private_json,
    load_state,
)


MESSAGE_LIMIT = 2_000
SUPPORT_POST_KEY = "support-request-template"
SUPPORT_POST_NAME = "Support request template"
PINNED_THREAD_FLAG = 1 << 1
ALLOWED_MENTIONS = {"parse": []}
CONFIGURATION_TOKEN = re.compile(r"\{[A-Z][A-Z0-9_]*\}")
MESSAGE_HEADING = re.compile(r"(?m)^## Message \d+(?:[^\n]*)\n")

STANDARD_CONTENT = (
    ("start-here", "start-here", "start-here.md", "messages"),
    ("rules", "rules", "rules.md", "messages"),
    ("faq", "faq", "faq.md", "messages"),
    ("contributing", "contributing", "contributing.md", "starter"),
)


@dataclass(frozen=True)
class Publication:
    """Desired messages for one standard Discord channel."""

    key: str
    channel_key: str
    chunks: tuple[str, ...]


def split_markdown(text: str, limit: int = MESSAGE_LIMIT) -> list[str]:
    """Split Markdown at stable whitespace boundaries within Discord's limit."""
    if limit < 1:
        raise ValueError("limit must be positive")
    remaining = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not remaining:
        return []

    chunks: list[str] = []
    while len(remaining) > limit:
        window = remaining[: limit + 1]
        boundary = window.rfind("\n\n", 0, limit + 1)
        skip = 2
        if boundary <= 0:
            boundary = window.rfind("\n", 0, limit + 1)
            skip = 1
        if boundary <= 0:
            boundary = window.rfind(" ", 0, limit + 1)
            skip = 1
        if boundary <= 0:
            boundary = limit
            skip = 0

        chunk = remaining[:boundary].rstrip()
        if not chunk:
            boundary = limit
            skip = 0
            chunk = remaining[:boundary]
        chunks.append(chunk)
        remaining = remaining[boundary + skip :].lstrip()

    if remaining:
        chunks.append(remaining)
    return chunks


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise ManifestError(
            f"cannot read Discord content {path}: {error.strerror}"
        ) from error


def _section_after(text: str, heading: str, path: Path) -> str:
    marker = f"## {heading}"
    positions = [
        match.start()
        for match in re.finditer(rf"(?m)^{re.escape(marker)}\s*$", text)
    ]
    if len(positions) != 1:
        raise ManifestError(
            f"{path} must contain exactly one {marker!r} section"
        )
    start = text.find("\n", positions[0])
    if start < 0:
        return ""
    return text[start + 1 :].strip()


def _message_sections(text: str, path: Path) -> list[str]:
    matches = list(MESSAGE_HEADING.finditer(text))
    if not matches:
        raise ManifestError(f"{path} must contain at least one Message section")
    sections: list[str] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        section = text[match.end() : end].strip()
        if not section:
            raise ManifestError(f"{path} contains an empty Message section")
        sections.append(section)
    return sections


def _reject_tokens(text: str, path: Path) -> None:
    tokens = sorted(set(CONFIGURATION_TOKEN.findall(text)))
    if tokens:
        raise ManifestError(
            f"{path} contains unresolved configuration token(s): "
            f"{', '.join(tokens)}"
        )


def render_rules(text: str, appeal_method: str, path: Path | None = None) -> str:
    """Replace the required moderation appeal token and reject leftovers."""
    rendered_path = path or Path("rules.md")
    if not appeal_method.strip():
        raise ManifestError(
            "DISCORD_MODERATION_APPEAL_METHOD is required to publish rules.md"
        )
    rendered = text.replace(
        "{MODERATION_APPEAL_METHOD}",
        appeal_method.strip(),
    )
    _reject_tokens(rendered, rendered_path)
    return rendered


def load_publications(
    content_dir: Path,
    appeal_method: str,
) -> tuple[list[Publication], tuple[str, ...]]:
    """Load reviewed source files and remove their authoring-only headings."""
    publications: list[Publication] = []
    for key, channel_key, filename, layout in STANDARD_CONTENT:
        path = content_dir / filename
        text = _read_text(path)
        if filename == "rules.md":
            text = render_rules(text, appeal_method, path)
        else:
            _reject_tokens(text, path)

        if layout == "messages":
            sections = _message_sections(text, path)
        else:
            sections = [_section_after(text, "Starter message", path)]

        chunks: list[str] = []
        for section in sections:
            chunks.extend(split_markdown(section))
        if not chunks:
            raise ManifestError(f"{path} contains no publishable content")
        publications.append(
            Publication(
                key=key,
                channel_key=channel_key,
                chunks=tuple(chunks),
            )
        )

    support_path = content_dir / "support-template.md"
    support_text = _section_after(
        _read_text(support_path),
        "Pinned support template",
        support_path,
    )
    _reject_tokens(support_text, support_path)
    support_chunks = tuple(split_markdown(support_text))
    if not support_chunks:
        raise ManifestError(f"{support_path} contains no publishable content")
    return publications, support_chunks


def load_content_state(path: Path, guild_id: str) -> dict[str, Any]:
    """Load publisher-owned message IDs without adopting Discord content."""
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            state = json.load(handle)
    except OSError as error:
        raise ManifestError(f"cannot read state {path}: {error.strerror}") from error
    except json.JSONDecodeError as error:
        raise ManifestError(
            f"invalid JSON in {path} at line {error.lineno}, column {error.colno}"
        ) from error

    if not isinstance(state, dict) or state.get("state_version") != 1:
        raise ManifestError(f"{path} is not a supported Discord content state file")
    state_guild = str(state.get("guild_id", ""))
    if state_guild != guild_id:
        raise ManifestError(
            f"{path} belongs to guild {state_guild or '<missing>'}, not "
            "DISCORD_GUILD_ID"
        )
    if not isinstance(state.get("resources"), dict):
        raise ManifestError(f"{path} has malformed resources")
    return state


def _content_hash(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


class ContentPublisher:
    """Reconcile publisher-owned Discord messages without deletions."""

    def __init__(
        self,
        client: DiscordClient,
        guild_id: str,
        content_dir: Path,
        core_state: Mapping[str, Any],
        *,
        appeal_method: str,
        apply: bool,
        audit_reason: str,
        state: Mapping[str, Any] | None = None,
        state_path: Path | None = None,
        rollback_dir: Path | None = None,
        output: Callable[[str], None] = print,
    ) -> None:
        self.client = client
        self.guild_id = guild_id
        self.content_dir = content_dir
        self.core_state = dict(core_state)
        self.appeal_method = appeal_method
        self.apply = apply
        self.audit_reason = audit_reason
        self.state = dict(state or {})
        self.state_path = state_path
        self.rollback_dir = rollback_dir
        self.output = output
        self.actions: list[str] = []
        self.current_messages: dict[str, list[dict[str, Any]]] = {}
        self.current_thread: dict[str, Any] | None = None
        self.current_support_messages: list[dict[str, Any]] = []

    def _record(self, message: str) -> None:
        self.actions.append(message)
        prefix = "APPLY" if self.apply else "PLAN"
        self.output(f"{prefix}: {message}")

    def _reason(self, operation: str) -> str:
        return f"{self.audit_reason}: {operation}"[:512]

    def _resources(self) -> dict[str, Any]:
        resources = self.state.setdefault("resources", {})
        if not isinstance(resources, dict):
            raise ManifestError("Discord content state has malformed resources")
        standard = resources.setdefault("standard_messages", {})
        forum = resources.setdefault("forum_posts", {})
        if not isinstance(standard, dict) or not isinstance(forum, dict):
            raise ManifestError("Discord content state has malformed resources")
        return resources

    def _core_channel(self, key: str, expected_name: str) -> dict[str, str]:
        resources = self.core_state.get("resources", {})
        channels = resources.get("channels", {}) if isinstance(resources, dict) else {}
        item = channels.get(key) if isinstance(channels, dict) else None
        if not isinstance(item, dict) or not item.get("id"):
            raise ManifestError(
                f"core Discord state has no applied channel ID for {key!r}; "
                "run provision.py --apply first"
            )
        name = str(item.get("name", ""))
        if name != expected_name:
            raise ManifestError(
                f"core Discord state channel {key!r} is named {name!r}, "
                f"expected {expected_name!r}"
            )
        return {"id": str(item["id"]), "name": name}

    @staticmethod
    def _chunk_records(
        item: Mapping[str, Any],
        description: str,
    ) -> list[dict[str, Any]]:
        chunks = item.get("chunks")
        if not isinstance(chunks, list):
            raise ManifestError(f"content state {description} has malformed chunks")
        result: list[dict[str, Any]] = []
        for index, raw in enumerate(chunks):
            if not isinstance(raw, dict) or not raw.get("message_id"):
                raise ManifestError(
                    f"content state {description} chunk {index} has no message ID"
                )
            result.append(dict(raw))
        message_ids = [str(item["message_id"]) for item in result]
        if len(message_ids) != len(set(message_ids)):
            raise ManifestError(
                f"content state {description} contains duplicate message IDs"
            )
        return result

    def _validate_state_bindings(
        self,
        publications: Sequence[Publication],
    ) -> None:
        resources = self._resources()
        standard = resources["standard_messages"]
        allowed_keys = {publication.key for publication in publications}
        unknown = sorted(set(standard) - allowed_keys)
        if unknown:
            raise ManifestError(
                "content state contains unknown standard publication(s): "
                f"{', '.join(unknown)}"
            )

        all_message_ids: list[str] = []
        for publication in publications:
            item = standard.get(publication.key)
            if item is None:
                continue
            if not isinstance(item, dict):
                raise ManifestError(
                    f"content state publication {publication.key!r} is malformed"
                )
            channel = self._core_channel(
                publication.channel_key,
                publication.channel_key,
            )
            if str(item.get("channel_id", "")) != channel["id"]:
                raise ManifestError(
                    f"content state publication {publication.key!r} targets "
                    "a different channel ID than core Discord state"
                )
            records = self._chunk_records(item, publication.key)
            all_message_ids.extend(str(record["message_id"]) for record in records)

        forum = resources["forum_posts"]
        unknown_forum = sorted(set(forum) - {SUPPORT_POST_KEY})
        if unknown_forum:
            raise ManifestError(
                "content state contains unknown forum publication(s): "
                f"{', '.join(unknown_forum)}"
            )
        support = forum.get(SUPPORT_POST_KEY)
        if support is not None:
            if not isinstance(support, dict):
                raise ManifestError("content state support forum post is malformed")
            help_channel = self._core_channel("help", "help")
            if str(support.get("forum_channel_id", "")) != help_channel["id"]:
                raise ManifestError(
                    "content state support forum post targets a different forum "
                    "than core Discord state"
                )
            if not support.get("thread_id"):
                raise ManifestError(
                    "content state support forum post has no thread ID"
                )
            records = self._chunk_records(support, SUPPORT_POST_KEY)
            if not records:
                raise ManifestError(
                    "content state support forum post has no starter message ID"
                )
            all_message_ids.extend(str(record["message_id"]) for record in records)

        if len(all_message_ids) != len(set(all_message_ids)):
            raise ManifestError(
                "content state assigns one message ID to multiple publications"
            )

    def _get_message(
        self,
        channel_id: str,
        message_id: str,
        description: str,
    ) -> dict[str, Any]:
        message = self.client.request(
            "GET",
            f"/channels/{channel_id}/messages/{message_id}",
        )
        if not isinstance(message, dict):
            raise DiscordAPIError(
                f"Discord returned malformed {description} message"
            )
        if str(message.get("id", "")) != message_id:
            raise DiscordAPIError(
                f"Discord returned the wrong message for {description}"
            )
        if str(message.get("channel_id", "")) != channel_id:
            raise DiscordAPIError(
                f"managed {description} message belongs to a different channel"
            )
        return dict(message)

    def _inspect_current(self, publications: Sequence[Publication]) -> None:
        resources = self._resources()
        standard = resources["standard_messages"]
        for publication in publications:
            item = standard.get(publication.key)
            messages: list[dict[str, Any]] = []
            if isinstance(item, dict):
                for record in self._chunk_records(item, publication.key):
                    messages.append(
                        self._get_message(
                            str(item["channel_id"]),
                            str(record["message_id"]),
                            publication.key,
                        )
                    )
            self.current_messages[publication.key] = messages

        support = resources["forum_posts"].get(SUPPORT_POST_KEY)
        if not isinstance(support, dict):
            return
        thread_id = str(support["thread_id"])
        thread = self.client.request("GET", f"/channels/{thread_id}")
        if not isinstance(thread, dict) or str(thread.get("id", "")) != thread_id:
            raise DiscordAPIError("Discord returned the wrong managed support thread")
        if str(thread.get("parent_id", "")) != str(support["forum_channel_id"]):
            raise DiscordAPIError(
                "managed support thread belongs to a different forum"
            )
        self.current_thread = dict(thread)
        for record in self._chunk_records(support, SUPPORT_POST_KEY):
            self.current_support_messages.append(
                self._get_message(
                    thread_id,
                    str(record["message_id"]),
                    SUPPORT_POST_KEY,
                )
            )

    @staticmethod
    def _snapshot_message(message: Mapping[str, Any]) -> dict[str, Any]:
        content = str(message.get("content", ""))
        return {
            "id": str(message.get("id", "")),
            "channel_id": str(message.get("channel_id", "")),
            "pinned": bool(message.get("pinned", False)),
            "content": "[REDACTED]",
            "content_length": len(content),
            "content_sha256": _content_hash(content),
        }

    def _write_snapshot(self) -> None:
        if self.rollback_dir is None:
            return
        snapshot = {
            "snapshot_version": 1,
            "kind": "discord-content",
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "guild_id": self.guild_id,
            "note": (
                "Pre-apply managed-content snapshot. Message bodies are redacted; "
                "this is evidence for manual rollback, not an executable rollback."
            ),
            "standard_messages": {
                key: [self._snapshot_message(message) for message in messages]
                for key, messages in self.current_messages.items()
            },
            "support_forum_post": {
                "thread": {
                    key: self.current_thread.get(key)
                    for key in ("id", "parent_id", "name", "flags")
                }
                if self.current_thread
                else None,
                "messages": [
                    self._snapshot_message(message)
                    for message in self.current_support_messages
                ],
            },
        }
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = self.rollback_dir / f"pre-content-apply-{timestamp}.json"
        _write_private_json(path, snapshot)
        self.output(f"SNAPSHOT: wrote redacted pre-apply content to {path}")

    def _write_state(self) -> None:
        if self.state_path is None:
            return
        self.state["state_version"] = 1
        self.state["guild_id"] = self.guild_id
        self.state["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        _write_private_json(self.state_path, self.state)
        self.output(f"STATE: wrote managed content IDs to {self.state_path}")

    def _new_message_record(
        self,
        message_id: str,
        content: str,
    ) -> dict[str, str]:
        return {
            "message_id": message_id,
            "content_sha256": _content_hash(content),
        }

    def _validate_created_message(
        self,
        message: Any,
        channel_id: str,
        description: str,
    ) -> dict[str, Any]:
        if not isinstance(message, dict) or not message.get("id"):
            raise DiscordAPIError(
                f"Discord returned malformed created {description} message"
            )
        if str(message.get("channel_id", "")) != channel_id:
            raise DiscordAPIError(
                f"Discord created {description} message in an unexpected channel"
            )
        return dict(message)

    def _reconcile_standard(self, publication: Publication) -> None:
        channel = self._core_channel(
            publication.channel_key,
            publication.channel_key,
        )
        resources = self._resources()
        standard = resources["standard_messages"]
        item = standard.get(publication.key)
        if not isinstance(item, dict):
            item = {"channel_id": channel["id"], "chunks": []}
            standard[publication.key] = item
        records = self._chunk_records(item, publication.key)
        messages = self.current_messages[publication.key]

        for index, content in enumerate(publication.chunks):
            payload = {
                "content": content,
                "allowed_mentions": ALLOWED_MENTIONS,
            }
            if index < len(messages):
                message = messages[index]
                if str(message.get("content", "")) != content:
                    self._record(
                        f"update {publication.key} message chunk {index + 1}"
                    )
                    if self.apply:
                        message = self._validate_created_message(
                            self.client.request(
                                "PATCH",
                                f"/channels/{channel['id']}/messages/"
                                f"{message['id']}",
                                payload,
                            ),
                            channel["id"],
                            publication.key,
                        )
                        messages[index] = message
                if index < len(records):
                    records[index]["content_sha256"] = _content_hash(content)
                continue

            self._record(f"create {publication.key} message chunk {index + 1}")
            if self.apply:
                message = self._validate_created_message(
                    self.client.request(
                        "POST",
                        f"/channels/{channel['id']}/messages",
                        payload,
                    ),
                    channel["id"],
                    publication.key,
                )
                messages.append(message)
                records.append(
                    self._new_message_record(str(message["id"]), content)
                )
                item["chunks"] = records
                self._write_state()

        if len(messages) > len(publication.chunks):
            self.output(
                f"WARN: retaining {len(messages) - len(publication.chunks)} "
                f"obsolete managed {publication.key} chunk(s); publisher never deletes"
            )

        first = messages[0] if messages else None
        needs_pin = first is None or not bool(first.get("pinned", False))
        if needs_pin:
            self._record(f"pin first {publication.key} message")
            if self.apply:
                if first is None:
                    raise DiscordAPIError(
                        f"cannot pin missing first {publication.key} message"
                    )
                self.client.request(
                    "PUT",
                    f"/channels/{channel['id']}/messages/pins/{first['id']}",
                    reason=self._reason(
                        f"pin first {publication.key} content message"
                    ),
                )
                first["pinned"] = True
        item["chunks"] = records

    def _create_support_post(
        self,
        help_channel: Mapping[str, str],
        chunks: Sequence[str],
    ) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
        payload = {
            "name": SUPPORT_POST_NAME,
            "message": {
                "content": chunks[0],
                "allowed_mentions": ALLOWED_MENTIONS,
            },
        }
        created = self.client.request(
            "POST",
            f"/channels/{help_channel['id']}/threads",
            payload,
            reason=self._reason("create support request template forum post"),
        )
        if not isinstance(created, dict) or not created.get("id"):
            raise DiscordAPIError(
                "Discord returned malformed created support forum post"
            )
        thread = dict(created)
        thread_id = str(thread["id"])
        if thread.get("parent_id") is not None and (
            str(thread["parent_id"]) != help_channel["id"]
        ):
            raise DiscordAPIError(
                "Discord created support forum post in an unexpected forum"
            )
        raw_message = thread.get("message")
        if isinstance(raw_message, dict) and raw_message.get("id"):
            starter = dict(raw_message)
            starter.setdefault("channel_id", thread_id)
        else:
            # Discord forum starter messages share the newly created thread ID.
            starter = {
                "id": thread_id,
                "channel_id": thread_id,
                "content": chunks[0],
                "pinned": False,
            }
        starter = self._validate_created_message(
            starter,
            thread_id,
            SUPPORT_POST_KEY,
        )
        state_item = {
            "forum_channel_id": help_channel["id"],
            "thread_id": thread_id,
            "name": SUPPORT_POST_NAME,
            "chunks": [
                self._new_message_record(str(starter["id"]), chunks[0])
            ],
        }
        return thread, starter, state_item

    def _reconcile_support(self, chunks: Sequence[str]) -> None:
        help_channel = self._core_channel("help", "help")
        resources = self._resources()
        forum = resources["forum_posts"]
        item = forum.get(SUPPORT_POST_KEY)
        thread = self.current_thread
        messages = self.current_support_messages

        if not isinstance(item, dict):
            self._record(f"create {SUPPORT_POST_NAME!r} forum post")
            if self.apply:
                thread, starter, item = self._create_support_post(
                    help_channel,
                    chunks,
                )
                forum[SUPPORT_POST_KEY] = item
                self.current_thread = thread
                messages.append(starter)
                self._write_state()
            else:
                for index in range(1, len(chunks)):
                    self._record(
                        f"create support template follow-up chunk {index + 1}"
                    )
                self._record(f"pin {SUPPORT_POST_NAME!r} forum post")
                return

        if not isinstance(item, dict):
            raise DiscordAPIError("support forum post state was not created")
        records = self._chunk_records(item, SUPPORT_POST_KEY)
        if thread is None:
            raise DiscordAPIError("managed support forum post was not loaded")
        thread_id = str(item["thread_id"])

        if str(thread.get("name", "")) != SUPPORT_POST_NAME:
            self._record(f"rename support forum post to {SUPPORT_POST_NAME!r}")
            if self.apply:
                rename_payload: dict[str, Any] = {"name": SUPPORT_POST_NAME}
                metadata = thread.get("thread_metadata", {})
                if isinstance(metadata, dict) and metadata.get("archived"):
                    rename_payload["archived"] = False
                updated = self.client.request(
                    "PATCH",
                    f"/channels/{thread_id}",
                    rename_payload,
                    reason=self._reason("rename support request template forum post"),
                )
                if not isinstance(updated, dict):
                    raise DiscordAPIError(
                        "Discord returned malformed updated support forum post"
                    )
                thread = dict(updated)
                self.current_thread = thread

        for index, content in enumerate(chunks):
            payload = {
                "content": content,
                "allowed_mentions": ALLOWED_MENTIONS,
            }
            if index < len(messages):
                message = messages[index]
                if str(message.get("content", "")) != content:
                    self._record(
                        f"update support template message chunk {index + 1}"
                    )
                    if self.apply:
                        message = self._validate_created_message(
                            self.client.request(
                                "PATCH",
                                f"/channels/{thread_id}/messages/{message['id']}",
                                payload,
                            ),
                            thread_id,
                            SUPPORT_POST_KEY,
                        )
                        messages[index] = message
                records[index]["content_sha256"] = _content_hash(content)
                continue

            self._record(f"create support template follow-up chunk {index + 1}")
            if self.apply:
                message = self._validate_created_message(
                    self.client.request(
                        "POST",
                        f"/channels/{thread_id}/messages",
                        payload,
                    ),
                    thread_id,
                    SUPPORT_POST_KEY,
                )
                messages.append(message)
                records.append(
                    self._new_message_record(str(message["id"]), content)
                )
                item["chunks"] = records
                self._write_state()

        if len(messages) > len(chunks):
            self.output(
                f"WARN: retaining {len(messages) - len(chunks)} obsolete managed "
                "support template chunk(s); publisher never deletes"
            )

        flags = int(thread.get("flags", 0) or 0)
        if not flags & PINNED_THREAD_FLAG:
            self._record(f"pin {SUPPORT_POST_NAME!r} forum post")
            if self.apply:
                pin_payload: dict[str, Any] = {
                    "flags": flags | PINNED_THREAD_FLAG,
                }
                metadata = thread.get("thread_metadata", {})
                if isinstance(metadata, dict) and metadata.get("archived"):
                    pin_payload["archived"] = False
                updated = self.client.request(
                    "PATCH",
                    f"/channels/{thread_id}",
                    pin_payload,
                    reason=self._reason("pin support request template forum post"),
                )
                if not isinstance(updated, dict):
                    raise DiscordAPIError(
                        "Discord returned malformed pinned support forum post"
                    )
                self.current_thread = dict(updated)
        item["chunks"] = records

    def run(self) -> list[str]:
        publications, support_chunks = load_publications(
            self.content_dir,
            self.appeal_method,
        )
        self._validate_state_bindings(publications)

        guild = self.client.request("GET", f"/guilds/{self.guild_id}")
        if not isinstance(guild, dict) or str(guild.get("id", "")) != self.guild_id:
            raise DiscordAPIError("Discord returned an unexpected guild")

        self._inspect_current(publications)
        if self.apply:
            self._write_snapshot()

        for publication in publications:
            self._reconcile_standard(publication)
        self._reconcile_support(support_chunks)
        if self.apply:
            self._write_state()
        return self.actions


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _default_content_dir() -> Path:
    return _repository_root() / "docs/community/discord/content"


def _default_core_state_path() -> Path:
    return Path(__file__).resolve().parent / ".discord-state.json"


def _default_state_path() -> Path:
    return Path(__file__).resolve().parent / ".discord-content-state.json"


def _default_rollback_dir() -> Path:
    return Path(__file__).resolve().parent / ".discord-rollbacks"


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Plan or apply CloudNow Discord content from this local checkout. "
            "Dry-run is the default."
        )
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform mutations; without this flag only a plan is printed",
    )
    parser.add_argument(
        "--content-dir",
        type=Path,
        default=_default_content_dir(),
        help="reviewed Discord content source directory",
    )
    parser.add_argument(
        "--core-state",
        type=Path,
        default=_default_core_state_path(),
        help="managed channel state written by provision.py",
    )
    parser.add_argument(
        "--state",
        type=Path,
        default=_default_state_path(),
        help="local managed-content ID state path",
    )
    parser.add_argument(
        "--rollback-dir",
        type=Path,
        default=_default_rollback_dir(),
        help="directory for redacted pre-apply content snapshots",
    )
    parser.add_argument(
        "--reason",
        default="CloudNow local content publication",
        help="prefix recorded in supported Discord audit-log entries",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    token = os.environ.get("DISCORD_BOT_TOKEN", "")
    guild_id = os.environ.get("DISCORD_GUILD_ID", "")
    appeal_method = os.environ.get("DISCORD_MODERATION_APPEAL_METHOD", "")
    try:
        if not guild_id:
            raise ManifestError("DISCORD_GUILD_ID is required")
        if not re.fullmatch(r"\d{17,20}", guild_id):
            raise ManifestError("DISCORD_GUILD_ID must be a Discord snowflake")
        if not token:
            raise ManifestError("DISCORD_BOT_TOKEN is required")
        if not appeal_method.strip():
            raise ManifestError("DISCORD_MODERATION_APPEAL_METHOD is required")
        core_state = load_state(args.core_state, guild_id)
        state = load_content_state(args.state, guild_id)
        publisher = ContentPublisher(
            DiscordClient(token),
            guild_id,
            args.content_dir,
            core_state,
            appeal_method=appeal_method,
            apply=args.apply,
            audit_reason=args.reason,
            state=state,
            state_path=args.state,
            rollback_dir=args.rollback_dir,
        )
        actions = publisher.run()
        if actions:
            if args.apply:
                print(f"Applied {len(actions)} managed content change(s).")
            else:
                print(
                    f"Dry run complete: {len(actions)} content change(s) planned. "
                    "Re-run with --apply to mutate Discord."
                )
        else:
            print("Discord managed content is already current.")
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
