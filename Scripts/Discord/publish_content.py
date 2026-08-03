#!/usr/bin/env python3
"""Publish the managed CloudNow Discord content from a local machine.

Only recorded IDs, plus exact bot-owned writes recovered from the durable
pending-create journal, are edited or adopted. Explicit replacement can delete
non-desired authoritative-channel content and obsolete recorded follow-ups
after writing a private recovery bundle; unrelated forum posts, forum replies,
and writable-channel history remain untouched.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
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
GUIDELINES_POST_KEY = "help-forum-guidelines"
GUIDELINES_POST_NAME = "Help forum guidelines"
OTHER_TAG_NAME = "Other"
CHANNEL_PINNED_MESSAGE_TYPE = 6
PIN_NOTICE_LOOKUP_ATTEMPTS = 4
PIN_NOTICE_RETRY_SECONDS = 0.25
PINNED_THREAD_FLAG = 1 << 1
REQUIRE_TAG_FLAG = 1 << 4
HAS_THREAD_MESSAGE_FLAG = 1 << 5
GATEWAY_MESSAGE_CONTENT = 1 << 18
GATEWAY_MESSAGE_CONTENT_LIMITED = 1 << 19
ALLOWED_MENTIONS = {"parse": []}
PUBLISH_CHANNEL_TYPES = {
    "start-here": 0,
    "rules": 0,
    "faq": 0,
    "contributing": 0,
    "support-resources": 0,
    "known-issues": 0,
    "feature-discussion": 0,
    "security-response": 0,
    "help": 15,
}
CONFIGURATION_TOKEN = re.compile(r"\{[A-Z][A-Z0-9_]*\}")
MESSAGE_HEADING = re.compile(r"(?m)^## Message \d+(?:[^\n]*)\n")
ATTACHMENT_HOSTS = frozenset(
    {
        "cdn.discordapp.com",
        "media.discordapp.net",
    }
)
DOWNLOAD_CHUNK_SIZE = 64 * 1024
DELETABLE_MESSAGE_TYPES = frozenset(
    {
        0,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        22,
        23,
        24,
        25,
        26,
        27,
        28,
        29,
        31,
        32,
        36,
        37,
        38,
        39,
        44,
        46,
    }
)

STANDARD_CONTENT = (
    ("start-here", "start-here", "start-here.md", "messages", True),
    ("rules", "rules", "rules.md", "messages", True),
    ("faq", "faq", "faq.md", "messages", True),
    (
        "contributing",
        "contributing",
        "contributing.md",
        "starter",
        True,
    ),
    (
        "support-resources",
        "support-resources",
        "support-template.md",
        "starter",
        True,
    ),
    (
        "known-issues",
        "known-issues",
        "known-issues.md",
        "starter",
        True,
    ),
    (
        "feature-discussion",
        "feature-discussion",
        "feature-discussion.md",
        "starter",
        False,
    ),
    (
        "security-response",
        "security-response",
        "canned-responses.md",
        "security-starter",
        False,
    ),
)


@dataclass(frozen=True)
class Publication:
    """Desired messages for one standard Discord channel."""

    key: str
    channel_key: str
    chunks: tuple[str, ...]
    authoritative: bool = True


@dataclass(frozen=True)
class ForumPublication:
    """Desired publisher-owned reference post in the help forum."""

    key: str
    name: str
    chunks: tuple[str, ...]
    always_apply_other_tag: bool
    pinned: bool


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


def _section_between(
    text: str,
    start_heading: str,
    end_heading: str,
    path: Path,
) -> str:
    """Return content between two exact Markdown heading lines."""

    def heading_position(heading: str) -> int:
        positions = [
            match.start()
            for match in re.finditer(
                rf"(?m)^{re.escape(heading)}\s*$",
                text,
            )
        ]
        if len(positions) != 1:
            raise ManifestError(
                f"{path} must contain exactly one {heading!r} heading"
            )
        return positions[0]

    start_position = heading_position(start_heading)
    end_position = heading_position(end_heading)
    if end_position <= start_position:
        raise ManifestError(
            f"{path} heading {end_heading!r} must follow {start_heading!r}"
        )
    start = text.find("\n", start_position)
    if start < 0:
        return ""
    return text[start + 1 : end_position].strip()


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
) -> tuple[list[Publication], list[ForumPublication]]:
    """Load reviewed source files and remove their authoring-only headings."""
    publications: list[Publication] = []
    for key, channel_key, filename, layout, authoritative in STANDARD_CONTENT:
        path = content_dir / filename
        text = _read_text(path)
        if layout == "security-starter":
            sections = [
                _section_after(
                    text,
                    "Staff-only `#security-response` Starter",
                    path,
                )
            ]
            for section in sections:
                _reject_tokens(section, path)
        elif filename == "rules.md":
            text = render_rules(text, appeal_method, path)
            sections = _message_sections(text, path)
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
                authoritative=authoritative,
            )
        )

    support_path = content_dir / "support-template.md"
    support_source = _read_text(support_path)
    guidelines_text = _section_between(
        support_source,
        "## Forum guidelines",
        "## Pinned support template",
        support_path,
    )
    support_text = _section_between(
        support_source,
        "## Pinned support template",
        "# `#support-resources`",
        support_path,
    )
    _reject_tokens(guidelines_text, support_path)
    _reject_tokens(support_text, support_path)
    guidelines_chunks = tuple(split_markdown(guidelines_text))
    support_chunks = tuple(split_markdown(support_text))
    if not guidelines_chunks:
        raise ManifestError(f"{support_path} contains no forum guidelines")
    if not support_chunks:
        raise ManifestError(f"{support_path} contains no publishable content")
    forum_publications = [
        ForumPublication(
            key=GUIDELINES_POST_KEY,
            name=GUIDELINES_POST_NAME,
            chunks=guidelines_chunks,
            always_apply_other_tag=True,
            pinned=False,
        ),
        ForumPublication(
            key=SUPPORT_POST_KEY,
            name=SUPPORT_POST_NAME,
            chunks=support_chunks,
            always_apply_other_tag=False,
            pinned=True,
        ),
    ]
    return publications, forum_publications


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


@contextlib.contextmanager
def _content_state_lock(state_path: Path) -> Any:
    """Prevent concurrent apply runs from racing one managed-content state."""
    lock_path = state_path.with_name(f"{state_path.name}.lock")
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT,
            0o600,
        )
        os.chmod(lock_path, 0o600)
    except OSError as error:
        raise DiscordAPIError(
            f"could not open content publisher lock {lock_path}: {error}"
        ) from error
    try:
        try:
            fcntl.flock(
                descriptor,
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
        except BlockingIOError as error:
            raise ManifestError(
                "another Discord content apply is already using "
                f"{state_path}"
            ) from error
        except OSError as error:
            raise DiscordAPIError(
                f"could not lock content publisher state {state_path}: "
                f"{error}"
            ) from error
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _validate_attachment_url(url: str, description: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    try:
        port = parsed.port
    except ValueError as error:
        raise DiscordAPIError(
            f"{description} has an unsafe Discord attachment URL"
        ) from error
    if (
        parsed.scheme != "https"
        or parsed.hostname not in ATTACHMENT_HOSTS
        or port not in {None, 443}
        or not parsed.path.startswith("/attachments/")
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise DiscordAPIError(
            f"{description} has an unsafe Discord attachment URL"
        )


class _AttachmentRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Allow attachment redirects only between approved Discord CDN URLs."""

    def __init__(self, description: str) -> None:
        super().__init__()
        self.description = description

    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> urllib.request.Request | None:
        _validate_attachment_url(new_url, self.description)
        return super().redirect_request(
            request,
            file_pointer,
            code,
            message,
            headers,
            new_url,
        )


def _download_attachment(
    url: str,
    target: Path,
    expected_size: int,
    description: str,
) -> str:
    """Download one signed Discord attachment and verify its exact byte count."""
    _validate_attachment_url(url, description)
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "CloudNow-Discord-Provisioner/1.0"},
    )
    opener = urllib.request.build_opener(
        _AttachmentRedirectHandler(description)
    )
    try:
        with opener.open(request, timeout=60) as response:
            final_url = str(response.geturl())
            _validate_attachment_url(final_url, description)
            descriptor = os.open(
                target,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            digest = hashlib.sha256()
            size = 0
            try:
                with os.fdopen(descriptor, "wb") as destination:
                    while True:
                        chunk = response.read(DOWNLOAD_CHUNK_SIZE)
                        if not chunk:
                            break
                        size += len(chunk)
                        if size > expected_size:
                            raise DiscordAPIError(
                                f"{description} exceeded its declared size"
                            )
                        destination.write(chunk)
                        digest.update(chunk)
                    destination.flush()
                    os.fsync(destination.fileno())
            except Exception:
                target.unlink(missing_ok=True)
                raise
    except (DiscordAPIError, ManifestError):
        target.unlink(missing_ok=True)
        raise
    except (OSError, urllib.error.URLError) as error:
        target.unlink(missing_ok=True)
        raise DiscordAPIError(
            f"could not back up {description}: {error}"
        ) from error
    if size != expected_size:
        target.unlink(missing_ok=True)
        raise DiscordAPIError(
            f"{description} was {size} bytes, expected {expected_size}"
        )
    return digest.hexdigest()


class ContentPublisher:
    """Reconcile publisher-owned Discord messages with guarded replacement."""

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
        replace_existing_content: bool = False,
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
        self.replace_existing_content = replace_existing_content
        self.state = dict(state or {})
        self.state_path = state_path
        self.rollback_dir = rollback_dir
        self.output = output
        self.actions: list[str] = []
        self.current_messages: dict[str, list[dict[str, Any]]] = {}
        self.help_forum: dict[str, Any] | None = None
        self.current_threads: dict[str, dict[str, Any]] = {}
        self.current_forum_messages: dict[str, list[dict[str, Any]]] = {}
        self.bot_user_id: str | None = None
        self.guild_channels: dict[str, dict[str, Any]] | None = None

    def _record(self, message: str) -> None:
        self.actions.append(message)
        prefix = "APPLY" if self.apply else "PLAN"
        self.output(f"{prefix}: {message}")

    def _reason(self, operation: str) -> str:
        return f"{self.audit_reason}: {operation}"[:512]

    def _verify_message_content_intent(self) -> None:
        application = self.client.request(
            "GET",
            "/oauth2/applications/@me",
        )
        if not isinstance(application, dict):
            raise DiscordAPIError(
                "Discord returned malformed bot application information"
            )
        raw_flags = application.get(
            "flags_new",
            application.get("flags", 0),
        )
        if isinstance(raw_flags, bool):
            raise DiscordAPIError(
                "Discord returned malformed bot application flags"
            )
        try:
            flags = int(raw_flags)
        except (TypeError, ValueError) as error:
            raise DiscordAPIError(
                "Discord returned malformed bot application flags"
            ) from error
        if flags < 0:
            raise DiscordAPIError(
                "Discord returned malformed bot application flags"
            )
        required = (
            GATEWAY_MESSAGE_CONTENT
            | GATEWAY_MESSAGE_CONTENT_LIMITED
        )
        if not flags & required:
            raise ManifestError(
                "--replace-existing-content requires Message Content Intent; "
                "enable it under Developer Portal > Bot > Privileged Gateway "
                "Intents before planning or applying deletion"
            )

    def _load_live_context(self) -> None:
        guild = self.client.request("GET", f"/guilds/{self.guild_id}")
        if (
            not isinstance(guild, dict)
            or str(guild.get("id", "")) != self.guild_id
        ):
            raise DiscordAPIError("Discord returned an unexpected guild")

        raw_channels = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/channels",
        )
        if not isinstance(raw_channels, list):
            raise DiscordAPIError(
                "Discord returned malformed guild channel inventory"
            )
        channels: dict[str, dict[str, Any]] = {}
        for index, raw_channel in enumerate(raw_channels):
            if not isinstance(raw_channel, dict):
                raise DiscordAPIError(
                    f"Discord returned malformed guild channel {index}"
                )
            channel_id = str(raw_channel.get("id", ""))
            if (
                not re.fullmatch(r"\d{17,20}", channel_id)
                or channel_id in channels
            ):
                raise DiscordAPIError(
                    "Discord returned unsafe guild channel inventory"
                )
            raw_guild_id = raw_channel.get("guild_id")
            if (
                raw_guild_id is not None
                and str(raw_guild_id) != self.guild_id
            ):
                raise DiscordAPIError(
                    f"Discord returned channel {channel_id} for another guild"
                )
            channels[channel_id] = dict(raw_channel)
        self.guild_channels = channels

        bot = self.client.request("GET", "/users/@me")
        bot_user_id = str(bot.get("id", "")) if isinstance(bot, dict) else ""
        if (
            not isinstance(bot, dict)
            or not re.fullmatch(r"\d{17,20}", bot_user_id)
            or bot.get("bot") is not True
        ):
            raise DiscordAPIError("Discord returned malformed bot identity")
        self.bot_user_id = bot_user_id

    def _bot_user_id(self) -> str:
        if self.bot_user_id is None:
            raise DiscordAPIError("Discord bot identity was not loaded")
        return self.bot_user_id

    def _validate_bot_owned_message(
        self,
        message: Mapping[str, Any],
        description: str,
    ) -> None:
        author = message.get("author")
        author_id = str(author.get("id", "")) if isinstance(author, dict) else ""
        if not re.fullmatch(r"\d{17,20}", author_id):
            raise DiscordAPIError(
                f"Discord returned malformed author for managed {description}"
            )
        if author_id != self._bot_user_id():
            raise ManifestError(
                f"content state binds managed {description} to a message not "
                "owned by the provisioning bot; refusing all publication"
            )

    def _validate_bot_owned_thread(
        self,
        thread: Mapping[str, Any],
        description: str,
    ) -> None:
        if "owner_id" not in thread:
            # Some thread payload shapes omit owner_id. The starter-message
            # author is still checked independently.
            return
        owner_id = str(thread.get("owner_id", ""))
        if not re.fullmatch(r"\d{17,20}", owner_id):
            raise DiscordAPIError(
                f"Discord returned malformed owner for managed {description}"
            )
        if owner_id != self._bot_user_id():
            raise ManifestError(
                f"content state binds managed {description} to a thread not "
                "owned by the provisioning bot; refusing all publication"
            )

    def _resources(self) -> dict[str, Any]:
        resources = self.state.setdefault("resources", {})
        if not isinstance(resources, dict):
            raise ManifestError("Discord content state has malformed resources")
        standard = resources.setdefault("standard_messages", {})
        forum = resources.setdefault("forum_posts", {})
        pending = resources.setdefault("pending_creates", {})
        if (
            not isinstance(standard, dict)
            or not isinstance(forum, dict)
            or not isinstance(pending, dict)
        ):
            raise ManifestError("Discord content state has malformed resources")
        return resources

    def _begin_pending_create(
        self,
        publication_key: str,
        record: Mapping[str, Any],
    ) -> None:
        pending = self._resources()["pending_creates"]
        desired = dict(record)
        existing = pending.get(publication_key)
        if existing is not None and existing != desired:
            raise ManifestError(
                f"unresolved create journal for {publication_key!r} does not "
                "match the requested Discord write"
            )
        if existing is None:
            pending[publication_key] = desired
            try:
                self._write_state()
            except DiscordAPIError:
                pending.pop(publication_key, None)
                raise

    def _finish_pending_create(self, publication_key: str) -> None:
        pending = self._resources()["pending_creates"]
        if publication_key not in pending:
            raise ManifestError(
                f"create journal for {publication_key!r} disappeared"
            )
        pending.pop(publication_key)
        self._write_state()

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
        channel_id = str(item["id"])
        if self.guild_channels is None:
            raise DiscordAPIError(
                "Discord guild channel inventory was not loaded"
            )
        live_channel = self.guild_channels.get(channel_id)
        if live_channel is None:
            raise ManifestError(
                f"core Discord state channel {key!r} ({channel_id}) is not a "
                f"live channel in guild {self.guild_id}; run provision.py "
                "--apply before publishing"
            )
        live_name = live_channel.get("name")
        if not isinstance(live_name, str) or live_name != expected_name:
            raise ManifestError(
                f"live Discord channel {channel_id} for {key!r} is named "
                f"{live_name!r}, expected {expected_name!r}; run provision.py "
                "--apply before publishing"
            )
        expected_type = PUBLISH_CHANNEL_TYPES.get(key)
        live_type = live_channel.get("type")
        if (
            expected_type is None
            or isinstance(live_type, bool)
            or live_type != expected_type
        ):
            raise ManifestError(
                f"live Discord channel {channel_id} for {key!r} has type "
                f"{live_type!r}, expected {expected_type!r}; run provision.py "
                "--apply before publishing"
            )
        return {"id": channel_id, "name": name}

    def _validate_core_channel_bindings(
        self,
        publications: Sequence[Publication],
    ) -> None:
        bound_ids: list[str] = []
        for publication in publications:
            channel = self._core_channel(
                publication.channel_key,
                publication.channel_key,
            )
            bound_ids.append(channel["id"])
        help_channel = self._core_channel("help", "help")
        bound_ids.append(help_channel["id"])
        if len(bound_ids) != len(set(bound_ids)):
            raise ManifestError(
                "core Discord state assigns one live channel to multiple "
                "published destinations"
            )

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
            message_id = str(raw["message_id"])
            if not re.fullmatch(r"\d{17,20}", message_id):
                raise ManifestError(
                    f"content state {description} chunk {index} has an invalid "
                    "message ID"
                )
            record = dict(raw)
            record["message_id"] = message_id
            result.append(record)
        message_ids = [str(item["message_id"]) for item in result]
        if len(message_ids) != len(set(message_ids)):
            raise ManifestError(
                f"content state {description} contains duplicate message IDs"
            )
        return result

    def _validate_state_bindings(
        self,
        publications: Sequence[Publication],
        forum_publications: Sequence[ForumPublication],
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
                self.output(
                    f"WARN: resetting {publication.key!r} content state because "
                    "provision.py now manages a different channel ID"
                )
                standard.pop(publication.key)
                continue
            records = self._chunk_records(item, publication.key)
            all_message_ids.extend(str(record["message_id"]) for record in records)

        forum = resources["forum_posts"]
        allowed_forum_keys = {
            publication.key for publication in forum_publications
        }
        unknown_forum = sorted(set(forum) - allowed_forum_keys)
        if unknown_forum:
            raise ManifestError(
                "content state contains unknown forum publication(s): "
                f"{', '.join(unknown_forum)}"
            )
        thread_ids: list[str] = []
        for publication in forum_publications:
            item = forum.get(publication.key)
            if item is None:
                continue
            if not isinstance(item, dict):
                raise ManifestError(
                    f"content state forum publication {publication.key!r} "
                    "is malformed"
                )
            help_channel = self._core_channel("help", "help")
            if str(item.get("forum_channel_id", "")) != help_channel["id"]:
                self.output(
                    f"WARN: resetting {publication.key!r} forum state because "
                    "provision.py now manages a different help forum ID"
                )
                forum.pop(publication.key)
                continue
            thread_id = str(item.get("thread_id", ""))
            if not re.fullmatch(r"\d{17,20}", thread_id):
                raise ManifestError(
                    f"content state forum publication {publication.key!r} "
                    "has an invalid thread ID"
                )
            thread_ids.append(thread_id)
            records = self._chunk_records(item, publication.key)
            if not records:
                raise ManifestError(
                    f"content state forum publication {publication.key!r} "
                    "has no starter message ID"
                )
            all_message_ids.extend(str(record["message_id"]) for record in records)

        if len(thread_ids) != len(set(thread_ids)):
            raise ManifestError(
                "content state assigns one thread ID to multiple forum "
                "publications"
            )
        if len(all_message_ids) != len(set(all_message_ids)):
            raise ManifestError(
                "content state assigns one message ID to multiple publications"
            )

        pending = resources["pending_creates"]
        publication_by_key = {
            publication.key: publication
            for publication in publications
        }
        forum_publication_by_key = {
            publication.key: publication
            for publication in forum_publications
        }
        unknown_pending = sorted(
            set(pending)
            - set(publication_by_key)
            - set(forum_publication_by_key)
        )
        if unknown_pending:
            raise ManifestError(
                "content state contains unknown pending publication(s): "
                f"{', '.join(unknown_pending)}"
            )
        for key, raw_pending in pending.items():
            if not isinstance(raw_pending, dict):
                raise ManifestError(
                    f"content state pending create {key!r} is malformed"
                )
            kind = raw_pending.get("kind")
            content_hash = raw_pending.get("content_sha256")
            chunk_index = raw_pending.get("chunk_index")
            if (
                not isinstance(content_hash, str)
                or not re.fullmatch(r"[0-9a-f]{64}", content_hash)
                or isinstance(chunk_index, bool)
                or not isinstance(chunk_index, int)
                or chunk_index < 0
            ):
                raise ManifestError(
                    f"content state pending create {key!r} is malformed"
                )
            if kind == "standard-message" and key in publication_by_key:
                expected_fields = {
                    "kind",
                    "channel_id",
                    "chunk_index",
                    "content_sha256",
                }
                channel = self._core_channel(
                    publication_by_key[key].channel_key,
                    publication_by_key[key].channel_key,
                )
                valid_target = (
                    str(raw_pending.get("channel_id", "")) == channel["id"]
                )
            elif kind == "forum-thread" and key in forum_publication_by_key:
                expected_fields = {
                    "kind",
                    "forum_channel_id",
                    "name",
                    "chunk_index",
                    "content_sha256",
                }
                publication = forum_publication_by_key[key]
                help_channel = self._core_channel("help", "help")
                valid_target = (
                    chunk_index == 0
                    and str(raw_pending.get("forum_channel_id", ""))
                    == help_channel["id"]
                    and raw_pending.get("name") == publication.name
                )
            elif kind == "forum-message" and key in forum_publication_by_key:
                expected_fields = {
                    "kind",
                    "thread_id",
                    "chunk_index",
                    "content_sha256",
                }
                item = forum.get(key)
                valid_target = (
                    isinstance(item, dict)
                    and str(raw_pending.get("thread_id", ""))
                    == str(item.get("thread_id", ""))
                )
            else:
                raise ManifestError(
                    f"content state pending create {key!r} has invalid kind"
                )
            if set(raw_pending) != expected_fields or not valid_target:
                raise ManifestError(
                    f"content state pending create {key!r} has unsafe binding"
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

    def _inspect_current(
        self,
        publications: Sequence[Publication],
        forum_publications: Sequence[ForumPublication],
    ) -> None:
        resources = self._resources()
        standard = resources["standard_messages"]
        for publication in publications:
            item = standard.get(publication.key)
            messages: list[dict[str, Any]] = []
            if isinstance(item, dict):
                retained_records: list[dict[str, Any]] = []
                for record in self._chunk_records(item, publication.key):
                    try:
                        message = self._get_message(
                            str(item["channel_id"]),
                            str(record["message_id"]),
                            publication.key,
                        )
                    except DiscordAPIError as error:
                        if error.status != 404:
                            raise
                        self.output(
                            "WARN: recovering deleted managed "
                            f"{publication.key} message "
                            f"{record['message_id']}"
                        )
                        continue
                    self._validate_bot_owned_message(
                        message,
                        f"{publication.key} message {record['message_id']}",
                    )
                    messages.append(message)
                    retained_records.append(record)
                item["chunks"] = retained_records
            self.current_messages[publication.key] = messages

        help_channel = self._core_channel("help", "help")
        help_forum = self.client.request(
            "GET",
            f"/channels/{help_channel['id']}",
        )
        if (
            not isinstance(help_forum, dict)
            or str(help_forum.get("id", "")) != help_channel["id"]
            or help_forum.get("type") != 15
        ):
            raise DiscordAPIError(
                "Discord returned an unexpected help forum"
            )
        self.help_forum = dict(help_forum)

        forum = resources["forum_posts"]
        for publication in forum_publications:
            item = forum.get(publication.key)
            messages: list[dict[str, Any]] = []
            self.current_forum_messages[publication.key] = messages
            if not isinstance(item, dict):
                continue
            thread_id = str(item["thread_id"])
            try:
                thread = self.client.request("GET", f"/channels/{thread_id}")
            except DiscordAPIError as error:
                if error.status != 404:
                    raise
                self.output(
                    "WARN: recovering deleted managed "
                    f"{publication.key} forum post {thread_id}"
                )
                forum.pop(publication.key)
                continue
            if (
                not isinstance(thread, dict)
                or str(thread.get("id", "")) != thread_id
            ):
                raise DiscordAPIError(
                    "Discord returned the wrong managed "
                    f"{publication.key} thread"
                )
            if str(thread.get("parent_id", "")) != str(item["forum_channel_id"]):
                raise DiscordAPIError(
                    f"managed {publication.key} thread belongs to a different "
                    "forum"
                )
            self._validate_bot_owned_thread(
                thread,
                f"{publication.key} forum post {thread_id}",
            )
            self.current_threads[publication.key] = dict(thread)
            records = self._chunk_records(item, publication.key)
            if str(records[0]["message_id"]) != thread_id:
                raise ManifestError(
                    f"content state forum publication {publication.key!r} "
                    "does not bind its Discord starter message"
                )
            retained_records = []
            for index, record in enumerate(records):
                try:
                    message = self._get_message(
                        thread_id,
                        str(record["message_id"]),
                        publication.key,
                    )
                except DiscordAPIError as error:
                    if error.status != 404:
                        raise
                    self.output(
                        "WARN: recovering deleted managed "
                        f"{publication.key} message "
                        f"{record['message_id']}"
                    )
                    if index == 0:
                        messages.clear()
                        retained_records.clear()
                        self.current_threads.pop(publication.key, None)
                        forum.pop(publication.key)
                        break
                    continue
                self._validate_bot_owned_message(
                    message,
                    f"{publication.key} message {record['message_id']}",
                )
                messages.append(message)
                retained_records.append(record)
            if publication.key in forum:
                item["chunks"] = retained_records

    @staticmethod
    def _message_is_pending_match(
        message: Mapping[str, Any],
        bot_user_id: str,
        content_hash: str,
    ) -> bool:
        author = message.get("author")
        return (
            isinstance(author, dict)
            and str(author.get("id", "")) == bot_user_id
            and isinstance(message.get("content"), str)
            and _content_hash(str(message["content"])) == content_hash
        )

    def _list_help_threads(self, help_channel_id: str) -> list[dict[str, Any]]:
        active = self.client.request(
            "GET",
            f"/guilds/{self.guild_id}/threads/active",
        )
        if not isinstance(active, dict) or not isinstance(
            active.get("threads"),
            list,
        ):
            raise DiscordAPIError(
                "Discord returned malformed active thread inventory"
            )
        raw_threads = list(active["threads"])
        before: str | None = None
        while True:
            query: dict[str, Any] = {"limit": 100}
            if before is not None:
                query["before"] = before
            path = (
                f"/channels/{help_channel_id}/threads/archived/public?"
                f"{urllib.parse.urlencode(query)}"
            )
            page = self.client.request("GET", path)
            if (
                not isinstance(page, dict)
                or not isinstance(page.get("threads"), list)
                or not isinstance(page.get("has_more"), bool)
                or len(page["threads"]) > 100
            ):
                raise DiscordAPIError(
                    "Discord returned malformed archived thread inventory"
                )
            raw_threads.extend(page["threads"])
            if not page["has_more"]:
                break
            if not page["threads"]:
                raise DiscordAPIError(
                    "Discord archived thread pagination did not advance"
                )
            metadata = page["threads"][-1].get("thread_metadata")
            next_before = (
                metadata.get("archive_timestamp")
                if isinstance(metadata, dict)
                else None
            )
            if (
                not isinstance(next_before, str)
                or not next_before
                or next_before == before
            ):
                raise DiscordAPIError(
                    "Discord archived thread pagination did not advance"
                )
            before = next_before

        threads: list[dict[str, Any]] = []
        seen_ids: set[str] = set()
        for index, raw_thread in enumerate(raw_threads):
            if not isinstance(raw_thread, dict):
                raise DiscordAPIError(
                    f"Discord returned malformed help thread {index}"
                )
            thread_id = str(raw_thread.get("id", ""))
            parent_id = str(raw_thread.get("parent_id", ""))
            if (
                not re.fullmatch(r"\d{17,20}", thread_id)
                or thread_id in seen_ids
            ):
                raise DiscordAPIError(
                    f"Discord returned unsafe help thread {index}"
                )
            seen_ids.add(thread_id)
            if parent_id == help_channel_id:
                threads.append(dict(raw_thread))
        return threads

    def _recover_pending_creates(
        self,
        publications: Sequence[Publication],
        forum_publications: Sequence[ForumPublication],
    ) -> None:
        resources = self._resources()
        pending = resources["pending_creates"]
        if not pending:
            return
        bot_user_id = self._bot_user_id()

        publication_by_key = {
            publication.key: publication
            for publication in publications
        }
        forum_by_key = {
            publication.key: publication
            for publication in forum_publications
        }
        help_threads: list[dict[str, Any]] | None = None

        for key in list(pending):
            record = pending[key]
            kind = str(record["kind"])
            matches: list[dict[str, Any]] = []
            if kind == "standard-message":
                channel_id = str(record["channel_id"])
                recorded = resources["standard_messages"].get(key)
                recorded_ids = {
                    str(item["message_id"])
                    for item in (
                        self._chunk_records(recorded, key)
                        if isinstance(recorded, dict)
                        else []
                    )
                }
                for message in self._list_channel_messages(
                    channel_id,
                    f"pending {key}",
                ):
                    if (
                        str(message["id"]) not in recorded_ids
                        and self._message_is_pending_match(
                            message,
                            bot_user_id,
                            str(record["content_sha256"]),
                        )
                    ):
                        matches.append(message)
            elif kind == "forum-thread":
                if help_threads is None:
                    help_threads = self._list_help_threads(
                        str(record["forum_channel_id"])
                    )
                bound_thread_ids = {
                    str(item.get("thread_id", ""))
                    for item in resources["forum_posts"].values()
                    if isinstance(item, dict)
                }
                for thread in help_threads:
                    thread_id = str(thread["id"])
                    if (
                        thread_id in bound_thread_ids
                        or str(thread.get("name", "")) != record["name"]
                    ):
                        continue
                    owner_id = thread.get("owner_id")
                    if (
                        owner_id is not None
                        and str(owner_id) != bot_user_id
                    ):
                        continue
                    try:
                        starter = self._get_message(
                            thread_id,
                            thread_id,
                            key,
                        )
                    except DiscordAPIError as error:
                        if error.status == 404:
                            continue
                        raise
                    if self._message_is_pending_match(
                        starter,
                        bot_user_id,
                        str(record["content_sha256"]),
                    ):
                        candidate = dict(starter)
                        candidate["_thread"] = thread
                        matches.append(candidate)
            elif kind == "forum-message":
                thread_id = str(record["thread_id"])
                recorded = resources["forum_posts"].get(key)
                recorded_ids = {
                    str(item["message_id"])
                    for item in (
                        self._chunk_records(recorded, key)
                        if isinstance(recorded, dict)
                        else []
                    )
                }
                for message in self._list_channel_messages(
                    thread_id,
                    f"pending {key}",
                ):
                    if (
                        str(message["id"]) not in recorded_ids
                        and self._message_is_pending_match(
                            message,
                            bot_user_id,
                            str(record["content_sha256"]),
                        )
                    ):
                        matches.append(message)
            else:
                raise ManifestError(
                    f"unsupported create journal kind {kind!r}"
                )

            if len(matches) > 1:
                raise ManifestError(
                    f"multiple bot-owned Discord objects match pending "
                    f"{key!r}; refusing ambiguous recovery"
                )
            if not matches:
                continue

            match = matches[0]
            chunk_index = int(record["chunk_index"])
            if kind == "standard-message":
                publication = publication_by_key[key]
                channel = self._core_channel(
                    publication.channel_key,
                    publication.channel_key,
                )
                item = resources["standard_messages"].setdefault(
                    key,
                    {"channel_id": channel["id"], "chunks": []},
                )
                records = self._chunk_records(item, key)
                if len(records) != chunk_index:
                    raise ManifestError(
                        f"pending {key!r} chunk index no longer matches state"
                    )
                records.append(
                    self._new_message_record(
                        str(match["id"]),
                        str(match["content"]),
                    )
                )
                item["chunks"] = records
            elif kind == "forum-thread":
                if key in resources["forum_posts"]:
                    raise ManifestError(
                        f"pending {key!r} forum thread is already bound"
                    )
                thread = match.pop("_thread")
                resources["forum_posts"][key] = {
                    "forum_channel_id": str(record["forum_channel_id"]),
                    "thread_id": str(thread["id"]),
                    "name": forum_by_key[key].name,
                    "chunks": [
                        self._new_message_record(
                            str(match["id"]),
                            str(match["content"]),
                        )
                    ],
                }
            else:
                item = resources["forum_posts"].get(key)
                if not isinstance(item, dict):
                    raise ManifestError(
                        f"pending {key!r} follow-up lost its forum binding"
                    )
                records = self._chunk_records(item, key)
                if len(records) != chunk_index:
                    raise ManifestError(
                        f"pending {key!r} chunk index no longer matches state"
                    )
                records.append(
                    self._new_message_record(
                        str(match["id"]),
                        str(match["content"]),
                    )
                )
                item["chunks"] = records
            self._record(
                f"adopt pending bot-owned {key} create {match['id']}"
            )
            self._finish_pending_create(key)

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
            "forum_posts": {
                key: {
                    "thread": {
                        field: thread.get(field)
                        for field in (
                            "id",
                            "parent_id",
                            "name",
                            "flags",
                            "applied_tags",
                        )
                    },
                    "messages": [
                        self._snapshot_message(message)
                        for message in self.current_forum_messages.get(key, [])
                    ],
                }
                for key, thread in self.current_threads.items()
            },
        }
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = self.rollback_dir / f"pre-content-apply-{timestamp}.json"
        _write_private_json(path, snapshot)
        self.output(f"SNAPSHOT: wrote redacted pre-apply content to {path}")

    def _write_state(self) -> None:
        if not self.apply or self.state_path is None:
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
        result = dict(message)
        self._validate_bot_owned_message(result, description)
        return result

    def _reconcile_standard(
        self,
        publication: Publication,
        *,
        reconcile_pin: bool = True,
    ) -> None:
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
                self._begin_pending_create(
                    publication.key,
                    {
                        "kind": "standard-message",
                        "channel_id": channel["id"],
                        "chunk_index": len(records),
                        "content_sha256": _content_hash(content),
                    },
                )
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
                self._finish_pending_create(publication.key)

        if (
            len(messages) > len(publication.chunks)
            and not self.replace_existing_content
        ):
            self.output(
                f"WARN: retaining {len(messages) - len(publication.chunks)} "
                f"obsolete managed {publication.key} chunk(s) because "
                "--replace-existing-content is not enabled"
            )

        if reconcile_pin:
            self._reconcile_standard_pin(publication)
        item["chunks"] = records

    def _reconcile_standard_pin(self, publication: Publication) -> None:
        messages = self.current_messages[publication.key]
        first = messages[0] if messages else None
        if first is not None and bool(first.get("pinned", False)):
            return
        self._record(f"pin first {publication.key} message")
        if self.replace_existing_content:
            self._record(f"delete generated {publication.key} pin notice")
        if not self.apply:
            return
        if first is None:
            raise DiscordAPIError(
                f"cannot pin missing first {publication.key} message"
            )
        channel = self._core_channel(
            publication.channel_key,
            publication.channel_key,
        )
        before_pin_ids: set[str] | None = None
        if self.replace_existing_content:
            before_pin_ids = {
                str(message["id"])
                for message in self._list_channel_messages(
                    channel["id"],
                    f"{publication.key} before pin",
                )
            }
        self.client.request(
            "PUT",
            f"/channels/{channel['id']}/messages/pins/{first['id']}",
            reason=self._reason(
                f"pin first {publication.key} content message"
            ),
        )
        first["pinned"] = True
        if before_pin_ids is not None:
            self._delete_generated_pin_notice(
                publication,
                channel,
                str(first["id"]),
                before_pin_ids,
            )

    def _delete_generated_pin_notice(
        self,
        publication: Publication,
        channel: Mapping[str, Any],
        pinned_message_id: str,
        before_pin_ids: set[str],
    ) -> None:
        """Delete only the type-6 notice created by this exact bot pin."""
        matches: list[dict[str, Any]] = []
        for attempt in range(PIN_NOTICE_LOOKUP_ATTEMPTS):
            matches = []
            for message in self._list_channel_messages(
                str(channel["id"]),
                f"{publication.key} after pin",
            ):
                message_id = str(message["id"])
                if message_id in before_pin_ids:
                    continue
                author = message.get("author")
                reference = message.get("message_reference")
                if (
                    message.get("type") == CHANNEL_PINNED_MESSAGE_TYPE
                    and isinstance(author, dict)
                    and str(author.get("id", "")) == self._bot_user_id()
                    and isinstance(reference, dict)
                    and str(reference.get("channel_id", ""))
                    == str(channel["id"])
                    and str(reference.get("message_id", ""))
                    == pinned_message_id
                ):
                    matches.append(message)
            if len(matches) > 1:
                raise DiscordAPIError(
                    f"Discord created multiple pin notices for "
                    f"{publication.key}; refusing automatic deletion"
                )
            if matches:
                break
            if attempt + 1 < PIN_NOTICE_LOOKUP_ATTEMPTS:
                time.sleep(PIN_NOTICE_RETRY_SECONDS)
        if not matches:
            raise DiscordAPIError(
                f"Discord did not expose the generated {publication.key} "
                "pin notice; refusing to claim exact publication"
            )
        notice_id = str(matches[0]["id"])
        try:
            self.client.request(
                "DELETE",
                f"/channels/{channel['id']}/messages/{notice_id}",
                reason=self._reason(
                    f"remove generated {publication.key} pin notice"
                ),
            )
        except DiscordAPIError as error:
            if error.status != 404:
                raise
            self.output(
                f"WARN: generated pin notice {notice_id} was already deleted"
            )

    def _other_tag_id(self) -> str:
        if self.help_forum is None:
            raise DiscordAPIError("managed help forum was not loaded")
        tags = self.help_forum.get("available_tags")
        if not isinstance(tags, list):
            raise DiscordAPIError(
                "Discord returned malformed tags for the help forum"
            )
        seen_ids: set[str] = set()
        matches: list[str] = []
        for index, tag in enumerate(tags):
            if not isinstance(tag, dict):
                raise DiscordAPIError(
                    f"Discord returned malformed help forum tag {index}"
                )
            tag_id = str(tag.get("id", ""))
            tag_name = tag.get("name")
            if (
                not re.fullmatch(r"\d{17,20}", tag_id)
                or not isinstance(tag_name, str)
                or not tag_name
            ):
                raise DiscordAPIError(
                    f"Discord returned malformed help forum tag {index}"
                )
            if tag_id in seen_ids:
                raise DiscordAPIError(
                    "Discord returned duplicate help forum tag IDs"
                )
            seen_ids.add(tag_id)
            if tag_name == OTHER_TAG_NAME:
                matches.append(tag_id)
        if len(matches) != 1:
            raise ManifestError(
                f"help forum must contain exactly one {OTHER_TAG_NAME!r} tag "
                "before publishing managed forum posts"
            )
        return matches[0]

    def _help_forum_requires_tag(self) -> bool:
        if self.help_forum is None:
            raise DiscordAPIError("managed help forum was not loaded")
        flags = self.help_forum.get("flags", 0)
        if not isinstance(flags, int):
            raise DiscordAPIError("Discord returned malformed help forum flags")
        return bool(flags & REQUIRE_TAG_FLAG)

    @staticmethod
    def _applied_tags(thread: Mapping[str, Any], description: str) -> list[str]:
        raw_tags = thread.get("applied_tags", [])
        if not isinstance(raw_tags, list):
            raise DiscordAPIError(
                f"Discord returned malformed applied tags for {description}"
            )
        tags: list[str] = []
        for raw_tag in raw_tags:
            tag_id = str(raw_tag)
            if not re.fullmatch(r"\d{17,20}", tag_id):
                raise DiscordAPIError(
                    f"Discord returned malformed applied tags for {description}"
                )
            tags.append(tag_id)
        if len(tags) != len(set(tags)):
            raise DiscordAPIError(
                f"Discord returned duplicate applied tags for {description}"
            )
        return tags

    def _desired_forum_tags(
        self,
        publication: ForumPublication,
    ) -> list[str]:
        if (
            publication.always_apply_other_tag
            or self._help_forum_requires_tag()
        ):
            return [self._other_tag_id()]
        return []

    def _create_forum_post(
        self,
        publication: ForumPublication,
        help_channel: Mapping[str, str],
        desired_tags: Sequence[str],
    ) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
        payload = {
            "name": publication.name,
            "message": {
                "content": publication.chunks[0],
                "allowed_mentions": ALLOWED_MENTIONS,
            },
        }
        if desired_tags:
            payload["applied_tags"] = list(desired_tags)
        created = self.client.request(
            "POST",
            f"/channels/{help_channel['id']}/threads",
            payload,
            reason=self._reason(
                f"create {publication.name} managed forum post"
            ),
        )
        if not isinstance(created, dict) or not created.get("id"):
            raise DiscordAPIError(
                f"Discord returned malformed created {publication.key} "
                "forum post"
            )
        thread = dict(created)
        thread_id = str(thread["id"])
        if not re.fullmatch(r"\d{17,20}", thread_id):
            raise DiscordAPIError(
                f"Discord returned an invalid created {publication.key} "
                "thread ID"
            )
        if thread.get("parent_id") is not None and (
            str(thread["parent_id"]) != help_channel["id"]
        ):
            raise DiscordAPIError(
                f"Discord created {publication.key} forum post in an "
                "unexpected forum"
            )
        self._validate_bot_owned_thread(
            thread,
            f"{publication.key} forum post {thread_id}",
        )
        applied_tags = self._applied_tags(thread, publication.key)
        if not set(desired_tags).issubset(applied_tags):
            raise DiscordAPIError(
                f"Discord did not apply the required tag to {publication.key}"
            )
        raw_message = thread.get("message")
        if isinstance(raw_message, dict) and raw_message.get("id"):
            starter = dict(raw_message)
            starter.setdefault("channel_id", thread_id)
        else:
            # Discord forum starter messages share the newly created thread
            # ID. Refetch instead of fabricating ownership data.
            starter = self._get_message(
                thread_id,
                thread_id,
                publication.key,
            )
        starter = self._validate_created_message(
            starter,
            thread_id,
            publication.key,
        )
        state_item = {
            "forum_channel_id": help_channel["id"],
            "thread_id": thread_id,
            "name": publication.name,
            "chunks": [
                self._new_message_record(
                    str(starter["id"]),
                    publication.chunks[0],
                )
            ],
        }
        return thread, starter, state_item

    def _verify_managed_forum_post(
        self,
        thread: Mapping[str, Any],
        publication: ForumPublication,
        help_channel_id: str,
        desired_tags: Sequence[str],
    ) -> None:
        self._validate_bot_owned_thread(
            thread,
            f"{publication.key} forum post",
        )
        thread_id = str(thread.get("id", ""))
        metadata = thread.get("thread_metadata")
        flags = thread.get("flags")
        if (
            not re.fullmatch(r"\d{17,20}", thread_id)
            or str(thread.get("parent_id", "")) != help_channel_id
            or str(thread.get("name", "")) != publication.name
            or not isinstance(flags, int)
            or bool(flags & PINNED_THREAD_FLAG) != publication.pinned
            or not isinstance(metadata, dict)
            or metadata.get("archived") is not False
            or metadata.get("locked") is not True
            or self._applied_tags(thread, publication.key)
            != list(desired_tags)
        ):
            raise DiscordAPIError(
                f"Discord did not converge managed {publication.key} forum post"
            )

    def _reconcile_forum_post(
        self,
        publication: ForumPublication,
    ) -> None:
        help_channel = self._core_channel("help", "help")
        desired_tags = self._desired_forum_tags(publication)
        resources = self._resources()
        forum = resources["forum_posts"]
        item = forum.get(publication.key)
        thread = self.current_threads.get(publication.key)
        messages = self.current_forum_messages[publication.key]

        if not isinstance(item, dict):
            self._record(f"create {publication.name!r} forum post")
            if self.apply:
                self._begin_pending_create(
                    publication.key,
                    {
                        "kind": "forum-thread",
                        "forum_channel_id": help_channel["id"],
                        "name": publication.name,
                        "chunk_index": 0,
                        "content_sha256": _content_hash(
                            publication.chunks[0]
                        ),
                    },
                )
                thread, starter, item = self._create_forum_post(
                    publication,
                    help_channel,
                    desired_tags,
                )
                forum[publication.key] = item
                self.current_threads[publication.key] = thread
                messages.append(starter)
                self._finish_pending_create(publication.key)
            else:
                for index in range(1, len(publication.chunks)):
                    self._record(
                        f"create {publication.key} follow-up chunk {index + 1}"
                    )
                if publication.pinned:
                    self._record(f"pin {publication.name!r} forum post")
                self._record(f"lock {publication.name!r} forum post")
                return

        if not isinstance(item, dict):
            raise DiscordAPIError(
                f"{publication.key} forum post state was not created"
            )
        records = self._chunk_records(item, publication.key)
        if thread is None:
            raise DiscordAPIError(
                f"managed {publication.key} forum post was not loaded"
            )
        thread_id = str(item["thread_id"])

        thread_payload: dict[str, Any] = {}
        if str(thread.get("name", "")) != publication.name:
            self._record(
                f"rename forum post to {publication.name!r}"
            )
            thread_payload["name"] = publication.name

        applied_tags = self._applied_tags(thread, publication.key)
        if applied_tags != desired_tags:
            if desired_tags == [self._other_tag_id()]:
                self._record(
                    f"apply exact {OTHER_TAG_NAME!r} tag to "
                    f"{publication.name!r}"
                )
            else:
                self._record(
                    f"clear managed tags from {publication.name!r}"
                )
            thread_payload["applied_tags"] = list(desired_tags)

        flags = thread.get("flags", 0)
        if not isinstance(flags, int):
            raise DiscordAPIError(
                f"Discord returned malformed flags for {publication.key}"
            )
        is_pinned = bool(flags & PINNED_THREAD_FLAG)
        if is_pinned != publication.pinned:
            operation = "pin" if publication.pinned else "unpin"
            self._record(f"{operation} {publication.name!r} forum post")
            if publication.pinned:
                thread_payload["flags"] = flags | PINNED_THREAD_FLAG
            else:
                thread_payload["flags"] = flags & ~PINNED_THREAD_FLAG

        metadata = thread.get("thread_metadata", {})
        if not isinstance(metadata, dict):
            raise DiscordAPIError(
                f"Discord returned malformed metadata for {publication.key}"
            )
        if metadata.get("archived"):
            self._record(f"unarchive {publication.name!r} forum post")
            thread_payload["archived"] = False
        if metadata.get("locked") is not True:
            self._record(f"lock {publication.name!r} forum post")
            thread_payload["locked"] = True

        if thread_payload and self.apply:
            updated = self.client.request(
                "PATCH",
                f"/channels/{thread_id}",
                thread_payload,
                reason=self._reason(
                    f"reconcile {publication.name} managed forum post"
                ),
            )
            if (
                not isinstance(updated, dict)
                or str(updated.get("id", "")) != thread_id
                or str(updated.get("parent_id", "")) != help_channel["id"]
            ):
                raise DiscordAPIError(
                    f"Discord returned malformed updated {publication.key} "
                    "forum post"
                )
            thread = dict(updated)
            self.current_threads[publication.key] = thread
        if self.apply or not thread_payload:
            self._verify_managed_forum_post(
                thread,
                publication,
                help_channel["id"],
                desired_tags,
            )

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
                                f"/channels/{thread_id}/messages/{message['id']}",
                                payload,
                            ),
                            thread_id,
                            publication.key,
                        )
                        messages[index] = message
                records[index]["content_sha256"] = _content_hash(content)
                continue

            self._record(
                f"create {publication.key} follow-up chunk {index + 1}"
            )
            if self.apply:
                self._begin_pending_create(
                    publication.key,
                    {
                        "kind": "forum-message",
                        "thread_id": thread_id,
                        "chunk_index": len(records),
                        "content_sha256": _content_hash(content),
                    },
                )
                message = self._validate_created_message(
                    self.client.request(
                        "POST",
                        f"/channels/{thread_id}/messages",
                        payload,
                    ),
                    thread_id,
                    publication.key,
                )
                messages.append(message)
                records.append(
                    self._new_message_record(str(message["id"]), content)
                )
                item["chunks"] = records
                self._finish_pending_create(publication.key)

        if (
            len(messages) > len(publication.chunks)
            and not self.replace_existing_content
        ):
            self.output(
                f"WARN: retaining {len(messages) - len(publication.chunks)} "
                f"obsolete managed {publication.key} chunk(s) because "
                "--replace-existing-content is not enabled"
            )
        item["chunks"] = records

    def _list_channel_messages(
        self,
        channel_id: str,
        description: str,
    ) -> list[dict[str, Any]]:
        messages: list[dict[str, Any]] = []
        seen_ids: set[str] = set()
        before: str | None = None
        while True:
            query: dict[str, Any] = {"limit": 100}
            if before is not None:
                query["before"] = before
            path = (
                f"/channels/{channel_id}/messages?"
                f"{urllib.parse.urlencode(query)}"
            )
            page = self.client.request("GET", path)
            if not isinstance(page, list) or len(page) > 100:
                raise DiscordAPIError(
                    f"Discord returned malformed message history for "
                    f"{description}"
                )
            for index, raw_message in enumerate(page):
                if not isinstance(raw_message, dict):
                    raise DiscordAPIError(
                        f"Discord returned malformed message {index} for "
                        f"{description}"
                    )
                message_id = str(raw_message.get("id", ""))
                if (
                    not re.fullmatch(r"\d{17,20}", message_id)
                    or str(raw_message.get("channel_id", "")) != channel_id
                    or message_id in seen_ids
                ):
                    raise DiscordAPIError(
                        f"Discord returned unsafe message history for "
                        f"{description}"
                    )
                seen_ids.add(message_id)
                messages.append(dict(raw_message))
            if len(page) < 100:
                break
            next_before = str(page[-1].get("id", ""))
            if next_before == before:
                raise DiscordAPIError(
                    f"Discord message pagination did not advance for "
                    f"{description}"
                )
            before = next_before
        return messages

    @staticmethod
    def _validate_recovery_message(
        message: Mapping[str, Any],
        channel_id: str,
        description: str,
    ) -> None:
        message_id = str(message.get("id", ""))
        message_type = message.get("type", 0)
        flags = message.get("flags", 0)
        if (
            not re.fullmatch(r"\d{17,20}", message_id)
            or str(message.get("channel_id", "")) != channel_id
            or not isinstance(message.get("content"), str)
            or not isinstance(message.get("embeds"), list)
            or not isinstance(message.get("attachments"), list)
            or not isinstance(message.get("components"), list)
            or isinstance(message_type, bool)
            or not isinstance(message_type, int)
            or isinstance(flags, bool)
            or not isinstance(flags, int)
        ):
            raise DiscordAPIError(
                f"Discord returned incomplete recovery data for {description}"
            )
        if message_type not in DELETABLE_MESSAGE_TYPES:
            raise ManifestError(
                f"{description} has non-deletable Discord message type "
                f"{message_type}; remove or retain it manually before exact "
                "replacement"
            )
        if message.get("thread") is not None or flags & HAS_THREAD_MESSAGE_FLAG:
            raise ManifestError(
                f"{description} owns a Discord thread; automatic replacement "
                "refuses to delete a source message without archiving its "
                "separate thread history"
            )
        for field in ("sticker_items", "message_snapshots"):
            value = message.get(field, [])
            if not isinstance(value, list):
                raise DiscordAPIError(
                    f"Discord returned malformed {field} for {description}"
                )
        poll = message.get("poll")
        if poll is not None and not isinstance(poll, dict):
            raise DiscordAPIError(
                f"Discord returned malformed poll for {description}"
            )

    @classmethod
    def _stable_recovery_value(cls, value: Any) -> Any:
        if isinstance(value, dict):
            return {
                str(key): cls._stable_recovery_value(item)
                for key, item in sorted(
                    value.items(),
                    key=lambda pair: str(pair[0]),
                )
            }
        if isinstance(value, list):
            return [cls._stable_recovery_value(item) for item in value]
        if isinstance(value, str):
            parsed = urllib.parse.urlsplit(value)
            if (
                parsed.scheme == "https"
                and parsed.hostname in ATTACHMENT_HOSTS
            ):
                return urllib.parse.urlunsplit(
                    (
                        parsed.scheme,
                        parsed.netloc,
                        parsed.path,
                        "",
                        "",
                    )
                )
        return value

    @classmethod
    def _recovery_fingerprint(cls, message: Mapping[str, Any]) -> str:
        normalized = cls._stable_recovery_value(dict(message))
        return hashlib.sha256(
            json.dumps(
                normalized,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode("utf-8")
        ).hexdigest()

    @staticmethod
    def _candidate_key(
        candidate: Mapping[str, Any],
    ) -> tuple[str, str, str, str]:
        return (
            str(candidate["kind"]),
            str(candidate["publication"]),
            str(candidate["channel_id"]),
            str(candidate["message"]["id"]),
        )

    def _replacement_candidates(
        self,
        publications: Sequence[Publication],
        forum_publications: Sequence[ForumPublication],
    ) -> list[dict[str, Any]]:
        resources = self._resources()
        standard = resources["standard_messages"]
        candidates: list[dict[str, Any]] = []
        for publication in publications:
            channel = self._core_channel(
                publication.channel_key,
                publication.channel_key,
            )
            item = standard.get(publication.key)
            if item is None:
                records: list[dict[str, Any]] = []
            elif isinstance(item, dict):
                records = self._chunk_records(item, publication.key)
            else:
                raise ManifestError(
                    f"managed publication {publication.key!r} has malformed "
                    "state"
                )
            desired_ids = {
                str(record["message_id"])
                for record in records[: len(publication.chunks)]
            }
            obsolete_ids = {
                str(record["message_id"])
                for record in records[len(publication.chunks) :]
            }
            if not publication.authoritative:
                messages_by_id = {
                    str(message["id"]): message
                    for message in self.current_messages[publication.key]
                }
                for record in records[len(publication.chunks) :]:
                    message_id = str(record["message_id"])
                    message = messages_by_id.get(message_id)
                    if message is None:
                        raise DiscordAPIError(
                            f"managed {publication.key} state references an "
                            "unloaded obsolete message"
                        )
                    self._validate_recovery_message(
                        message,
                        channel["id"],
                        f"message {message_id} in #{channel['name']}",
                    )
                    candidates.append(
                        {
                            "kind": "standard-obsolete-managed",
                            "publication": publication.key,
                            "channel_id": channel["id"],
                            "channel_name": channel["name"],
                            "message": message,
                        }
                    )
                continue
            history = self._list_channel_messages(
                channel["id"],
                publication.key,
            )
            history_ids = {str(message["id"]) for message in history}
            missing_managed = sorted(
                (desired_ids | obsolete_ids) - history_ids
            )
            if missing_managed:
                raise DiscordAPIError(
                    f"Discord message history for {publication.key} omitted "
                    "publisher-owned message(s); refusing replacement"
                )
            for message in history:
                message_id = str(message["id"])
                if (
                    message_id in obsolete_ids
                    or (
                        publication.authoritative
                        and message_id not in desired_ids
                    )
                ):
                    self._validate_recovery_message(
                        message,
                        channel["id"],
                        f"message {message_id} in #{channel['name']}",
                    )
                    candidates.append(
                        {
                            "kind": (
                                "standard-obsolete-managed"
                                if message_id in obsolete_ids
                                else "standard-unmanaged"
                            ),
                            "publication": publication.key,
                            "channel_id": channel["id"],
                            "channel_name": channel["name"],
                            "message": message,
                        }
                    )

        forum = resources["forum_posts"]
        for publication in forum_publications:
            item = forum.get(publication.key)
            if item is None:
                # Fresh plans have no real Discord thread ID yet. No
                # publisher-owned obsolete follow-up can exist.
                continue
            if not isinstance(item, dict):
                raise ManifestError(
                    f"managed forum publication {publication.key!r} has "
                    "malformed state"
                )
            records = self._chunk_records(item, publication.key)
            obsolete_records = records[len(publication.chunks) :]
            messages_by_id = {
                str(message["id"]): message
                for message in self.current_forum_messages[publication.key]
            }
            for record in obsolete_records:
                message_id = str(record["message_id"])
                message = messages_by_id.get(message_id)
                if message is None:
                    raise DiscordAPIError(
                        f"managed {publication.key} state references an "
                        "unloaded obsolete message"
                    )
                self._validate_recovery_message(
                    message,
                    str(item["thread_id"]),
                    f"message {message_id} in {publication.name!r}",
                )
                candidates.append(
                    {
                        "kind": "forum-obsolete-managed",
                        "publication": publication.key,
                        "channel_id": str(item["thread_id"]),
                        "channel_name": publication.name,
                        "message": message,
                    }
                )
        return candidates

    def _refresh_replacement_candidates(
        self,
        publications: Sequence[Publication],
        forum_publications: Sequence[ForumPublication],
        expected: Sequence[Mapping[str, Any]],
    ) -> list[dict[str, Any]]:
        refreshed = self._replacement_candidates(
            publications,
            forum_publications,
        )
        publication_by_key = {
            publication.key: publication
            for publication in publications
        }
        for candidate in refreshed:
            should_refetch = (
                candidate["kind"] == "forum-obsolete-managed"
                or (
                    candidate["kind"] == "standard-obsolete-managed"
                    and not publication_by_key[
                        str(candidate["publication"])
                    ].authoritative
                )
            )
            if not should_refetch:
                continue
            message = self._get_message(
                str(candidate["channel_id"]),
                str(candidate["message"]["id"]),
                str(candidate["publication"]),
            )
            self._validate_recovery_message(
                message,
                str(candidate["channel_id"]),
                f"message {message['id']} in "
                f"{candidate['channel_name']!r}",
            )
            candidate["message"] = message

        expected_by_key = {
            self._candidate_key(candidate): candidate
            for candidate in expected
        }
        refreshed_by_key = {
            self._candidate_key(candidate): candidate
            for candidate in refreshed
        }
        if (
            len(expected_by_key) != len(expected)
            or len(refreshed_by_key) != len(refreshed)
            or set(expected_by_key) != set(refreshed_by_key)
        ):
            raise DiscordAPIError(
                "replacement candidates changed after backup; refusing all "
                "message deletion"
            )
        for key, candidate in expected_by_key.items():
            if self._recovery_fingerprint(
                candidate["message"]
            ) != self._recovery_fingerprint(
                refreshed_by_key[key]["message"]
            ):
                raise DiscordAPIError(
                    f"replacement message {key[3]} changed after backup; "
                    "refusing all message deletion"
                )
        return [
            refreshed_by_key[self._candidate_key(candidate)]
            for candidate in expected
        ]

    @staticmethod
    def _attachment_url_key(value: str) -> str | None:
        parsed = urllib.parse.urlsplit(value)
        if (
            parsed.scheme != "https"
            or parsed.hostname not in ATTACHMENT_HOSTS
            or not parsed.path.startswith("/attachments/")
        ):
            return None
        return urllib.parse.urlunsplit(
            (
                parsed.scheme,
                parsed.netloc,
                parsed.path,
                "",
                "",
            )
        )

    def _attachment_specs(
        self,
        candidates: Sequence[Mapping[str, Any]],
    ) -> list[dict[str, Any]]:
        specs_by_id: dict[str, dict[str, Any]] = {}
        recognized_urls: set[str] = set()
        all_values: list[Any] = []

        def walk_attachments(value: Any, source_message_id: str) -> None:
            if isinstance(value, dict):
                raw_attachments = value.get("attachments")
                if raw_attachments is not None:
                    if not isinstance(raw_attachments, list):
                        raise DiscordAPIError(
                            "Discord returned malformed nested attachments "
                            f"for message {source_message_id}"
                        )
                    for index, attachment in enumerate(raw_attachments):
                        if not isinstance(attachment, dict):
                            raise DiscordAPIError(
                                "Discord returned malformed attachment "
                                f"{index} for message {source_message_id}"
                            )
                        attachment_id = str(attachment.get("id", ""))
                        filename = attachment.get("filename")
                        size = attachment.get("size")
                        url = attachment.get("url")
                        if (
                            not re.fullmatch(r"\d{17,20}", attachment_id)
                            or not isinstance(filename, str)
                            or not filename
                            or isinstance(size, bool)
                            or not isinstance(size, int)
                            or size < 0
                            or not isinstance(url, str)
                        ):
                            raise DiscordAPIError(
                                "Discord returned unsafe attachment "
                                f"{index} for message {source_message_id}"
                            )
                        description = (
                            f"attachment {attachment_id} from message "
                            f"{source_message_id}"
                        )
                        _validate_attachment_url(url, description)
                        for field in ("url", "proxy_url"):
                            raw_url = attachment.get(field)
                            if isinstance(raw_url, str):
                                key = self._attachment_url_key(raw_url)
                                if key is not None:
                                    recognized_urls.add(key)
                        spec = {
                            "message_id": source_message_id,
                            "attachment_id": attachment_id,
                            "filename": filename,
                            "declared_size": size,
                            "url": url,
                            "description": description,
                        }
                        prior = specs_by_id.get(attachment_id)
                        if prior is not None and (
                            prior["declared_size"] != size
                            or self._attachment_url_key(str(prior["url"]))
                            != self._attachment_url_key(url)
                        ):
                            raise DiscordAPIError(
                                f"Discord returned conflicting attachment "
                                f"{attachment_id}"
                            )
                        specs_by_id.setdefault(attachment_id, spec)
                for nested in value.values():
                    walk_attachments(nested, source_message_id)
            elif isinstance(value, list):
                for nested in value:
                    walk_attachments(nested, source_message_id)

        for candidate in candidates:
            message = candidate["message"]
            all_values.append(message)
            walk_attachments(message, str(message["id"]))

        def inspect_urls(value: Any) -> None:
            if isinstance(value, dict):
                for nested in value.values():
                    inspect_urls(nested)
            elif isinstance(value, list):
                for nested in value:
                    inspect_urls(nested)
            elif isinstance(value, str):
                key = self._attachment_url_key(value)
                if key is not None and key not in recognized_urls:
                    raise ManifestError(
                        "replacement candidate contains Discord attachment "
                        "media without durable size metadata; preserve or "
                        "remove that rich message manually"
                    )

        for value in all_values:
            inspect_urls(value)
        return list(specs_by_id.values())

    def _write_replacement_snapshot(
        self,
        candidates: Sequence[Mapping[str, Any]],
    ) -> None:
        if self.rollback_dir is None:
            raise ManifestError(
                "--replace-existing-content with --apply requires a rollback "
                "directory"
        )
        timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        attachment_specs = self._attachment_specs(candidates)

        attachment_backups: list[dict[str, Any]] = []
        attachment_directory = self.rollback_dir / (
            f"pre-content-replacement-{timestamp}.attachments"
        )
        if attachment_specs:
            try:
                attachment_directory.mkdir(
                    parents=True,
                    mode=0o700,
                    exist_ok=False,
                )
                os.chmod(attachment_directory, 0o700)
            except OSError as error:
                raise DiscordAPIError(
                    "could not create private attachment backup directory "
                    f"{attachment_directory}: {error}"
                ) from error
            for spec in attachment_specs:
                backup_name = (
                    f"{spec['message_id']}-{spec['attachment_id']}.bin"
                )
                target = attachment_directory / backup_name
                digest = _download_attachment(
                    str(spec["url"]),
                    target,
                    int(spec["declared_size"]),
                    str(spec["description"]),
                )
                attachment_backups.append(
                    {
                        "message_id": spec["message_id"],
                        "attachment_id": spec["attachment_id"],
                        "filename": spec["filename"],
                        "size": spec["declared_size"],
                        "sha256": digest,
                        "local_path": (
                            f"{attachment_directory.name}/{backup_name}"
                        ),
                    }
                )
            try:
                descriptor = os.open(attachment_directory, os.O_RDONLY)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            except OSError as error:
                raise DiscordAPIError(
                    "could not make attachment backup directory durable "
                    f"{attachment_directory}: {error}"
                ) from error

        snapshot = {
            "snapshot_version": 1,
            "kind": "discord-content-replacement",
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "guild_id": self.guild_id,
            "note": (
                "Sensitive pre-deletion snapshot. Unlike normal content "
                "snapshots, full message payloads and attachment bytes are "
                "retained for manual recovery. Discord cannot recreate original "
                "authors, timestamps, or reactions. Keep this owner-only bundle "
                "private."
            ),
            "deleted_messages": [dict(candidate) for candidate in candidates],
            "attachment_backups": attachment_backups,
        }
        path = self.rollback_dir / (
            f"pre-content-replacement-{timestamp}.json"
        )
        _write_private_json(path, snapshot)
        self.output(
            "SENSITIVE SNAPSHOT: wrote pre-deletion message payloads and "
            f"{len(attachment_backups)} attachment backup(s) to {path}"
        )

    def _prune_deleted_managed_record(
        self,
        candidate: Mapping[str, Any],
    ) -> None:
        kind = str(candidate["kind"])
        if kind == "standard-unmanaged":
            return
        if kind not in {
            "standard-obsolete-managed",
            "forum-obsolete-managed",
        }:
            raise ManifestError(
                f"unknown replacement candidate kind {kind!r}"
            )
        resources = self._resources()
        group_name = (
            "standard_messages"
            if kind == "standard-obsolete-managed"
            else "forum_posts"
        )
        group = resources[group_name]
        publication_key = str(candidate["publication"])
        item = group.get(publication_key)
        if not isinstance(item, dict):
            raise ManifestError(
                f"managed publication {publication_key!r} disappeared from "
                "content state during replacement"
            )
        message_id = str(candidate["message"]["id"])
        records = self._chunk_records(item, publication_key)
        retained = [
            record
            for record in records
            if str(record["message_id"]) != message_id
        ]
        if len(retained) != len(records) - 1:
            raise ManifestError(
                f"deleted managed message {message_id} was not uniquely bound "
                "in content state"
            )
        item["chunks"] = retained
        self._write_state()

    def _delete_replacement_candidates(
        self,
        candidates: Sequence[Mapping[str, Any]],
    ) -> None:
        for candidate in candidates:
            message = candidate["message"]
            message_id = str(message["id"])
            channel_id = str(candidate["channel_id"])
            if candidate["kind"] == "standard-unmanaged":
                description = (
                    f"delete unmanaged message {message_id} from "
                    f"#{candidate['channel_name']}"
                )
            elif candidate["kind"] == "standard-obsolete-managed":
                description = (
                    f"delete obsolete managed message {message_id} from "
                    f"#{candidate['channel_name']}"
                )
            else:
                description = (
                    f"delete obsolete managed message {message_id} from "
                    f"{candidate['channel_name']!r} forum post"
                )
            self._record(description)
            if self.apply:
                try:
                    self.client.request(
                        "DELETE",
                        f"/channels/{channel_id}/messages/{message_id}",
                        reason=self._reason(
                            "replace unmanaged content in "
                            f"#{candidate['channel_name']}"
                        ),
                    )
                except DiscordAPIError as error:
                    if error.status != 404:
                        raise
                    self.output(
                        f"WARN: message {message_id} was already deleted"
                    )
                self._prune_deleted_managed_record(candidate)

    def _verify_authoritative_standard_channels(
        self,
        publications: Sequence[Publication],
    ) -> None:
        resources = self._resources()
        standard = resources["standard_messages"]
        for publication in publications:
            if not publication.authoritative:
                continue
            item = standard.get(publication.key)
            if not isinstance(item, dict):
                raise DiscordAPIError(
                    f"managed {publication.key} state disappeared before "
                    "authoritative verification"
                )
            records = self._chunk_records(item, publication.key)
            desired_ids = [str(record["message_id"]) for record in records]
            if (
                len(desired_ids) != len(publication.chunks)
                or len(set(desired_ids)) != len(desired_ids)
            ):
                raise DiscordAPIError(
                    f"managed {publication.key} state is not exact after "
                    "publication"
                )
            channel = self._core_channel(
                publication.channel_key,
                publication.channel_key,
            )
            actual_by_id = {
                str(message["id"]): message
                for message in self._list_channel_messages(
                    channel["id"],
                    f"{publication.key} final verification",
                )
            }
            desired_id_set = set(desired_ids)
            if set(actual_by_id) != desired_id_set:
                raise DiscordAPIError(
                    f"authoritative channel #{channel['name']} changed during "
                    "publication; retained the unexpected content without "
                    "deleting it"
                )
            for index, (message_id, content) in enumerate(
                zip(desired_ids, publication.chunks)
            ):
                message = actual_by_id[message_id]
                if message.get("content") != content:
                    raise DiscordAPIError(
                        f"authoritative channel #{channel['name']} content "
                        "changed during publication; refusing to claim exact "
                        "publication"
                    )
                if index == 0 and message.get("pinned") is not True:
                    raise DiscordAPIError(
                        f"authoritative channel #{channel['name']} was "
                        "unpinned during publication; refusing to claim exact "
                        "publication"
                    )

    def run(self) -> list[str]:
        publications, forum_publications = load_publications(
            self.content_dir,
            self.appeal_method,
        )
        if (
            self.apply
            and self.replace_existing_content
            and self.rollback_dir is None
        ):
            raise ManifestError(
                "--replace-existing-content with --apply requires a rollback "
                "directory"
            )
        self._load_live_context()
        self._validate_core_channel_bindings(publications)
        self._validate_state_bindings(publications, forum_publications)
        if self.replace_existing_content:
            self._verify_message_content_intent()

        self._recover_pending_creates(
            publications,
            forum_publications,
        )
        self._validate_state_bindings(publications, forum_publications)
        self._inspect_current(publications, forum_publications)
        replacement_candidates: list[dict[str, Any]] = []
        if self.replace_existing_content:
            for publication in forum_publications:
                self._desired_forum_tags(publication)
            replacement_candidates = self._replacement_candidates(
                publications,
                forum_publications,
            )
        if self.apply:
            # Prove the managed-state destination is writable before the first
            # Discord mutation. This also persists any safe 404 recovery.
            self._write_state()
            self._write_snapshot()
            if self.replace_existing_content and replacement_candidates:
                self._write_replacement_snapshot(replacement_candidates)

        for publication in publications:
            self._reconcile_standard(
                publication,
                reconcile_pin=not self.replace_existing_content,
            )
        # Discord currently permits one pinned post per forum. Always reconcile
        # desired unpins first so migrations free that slot before a desired pin.
        forum_reconciliation_order = sorted(
            forum_publications,
            key=lambda publication: publication.pinned,
        )
        for publication in forum_reconciliation_order:
            self._reconcile_forum_post(publication)
        if self.replace_existing_content:
            if self.apply:
                replacement_candidates = (
                    self._refresh_replacement_candidates(
                        publications,
                        forum_publications,
                        replacement_candidates,
                    )
                )
            self._delete_replacement_candidates(replacement_candidates)
            for publication in publications:
                self._reconcile_standard_pin(publication)
            if self.apply:
                self._verify_authoritative_standard_channels(publications)
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
        "--replace-existing-content",
        action="store_true",
        help=(
            "make authoritative managed content exact after reconciliation by "
            "deleting non-desired messages, plus obsolete recorded chunks from "
            "non-authoritative starters and managed help posts; unrelated "
            "writable-channel and forum content is never deleted, dry-run "
            "remains non-mutating, and --apply writes a private pre-deletion "
            "recovery bundle"
        ),
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
        help="directory for snapshots and sensitive replacement recovery bundles",
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
        lock_context = (
            _content_state_lock(args.state)
            if args.apply
            else contextlib.nullcontext()
        )
        with lock_context:
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
                replace_existing_content=args.replace_existing_content,
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
