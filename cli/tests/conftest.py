"""pytest fixtures for the CLI tests.

Builds an in-memory SQLite DB with just enough of the chat.db schema to
exercise collect_context and collect_browse. Timestamps are hand-picked
Apple nanoseconds; the specific wall-clock dates they map to don't matter.
"""
from __future__ import annotations

import sqlite3
from typing import Iterable

import pytest


def _schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            display_name TEXT,
            chat_identifier TEXT,
            style INTEGER
        );
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            guid TEXT,
            handle_id INTEGER,
            is_from_me INTEGER DEFAULT 0,
            date INTEGER,
            text TEXT,
            attributedBody BLOB,
            balloon_bundle_id TEXT,
            associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT
        );
        CREATE TABLE chat_message_join (
            chat_id INTEGER,
            message_id INTEGER
        );
        CREATE TABLE chat_handle_join (
            chat_id INTEGER,
            handle_id INTEGER
        );
        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY,
            filename TEXT,
            transfer_name TEXT,
            mime_type TEXT,
            uti TEXT,
            is_sticker INTEGER DEFAULT 0
        );
        CREATE TABLE message_attachment_join (
            message_id INTEGER,
            attachment_id INTEGER
        );
        """
    )


def _insert_messages(
    conn: sqlite3.Connection,
    chat_id: int,
    rows: Iterable[tuple[int, int, int, str, int]],
) -> None:
    """rows: (rowid, handle_id, is_from_me, text, date_ns)"""
    for rowid, handle_id, is_me, text, date_ns in rows:
        conn.execute(
            "INSERT INTO message (ROWID, guid, handle_id, is_from_me, date, text, "
            "associated_message_type) VALUES (?, ?, ?, ?, ?, ?, 0)",
            (rowid, f"guid-{rowid}", handle_id, is_me, date_ns, text),
        )
        conn.execute(
            "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
            (chat_id, rowid),
        )


@pytest.fixture
def db() -> sqlite3.Connection:
    """In-memory DB with two chats.

    chat 1 ("Buds"): 8 messages, rowids 101-108, dates spaced 100ns apart
    starting at 1_000_000_000.
    chat 2 ("Empty"): no messages.
    handle 1 = "alice", handle 2 = "bob".
    """
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    _schema(conn)

    conn.execute(
        "INSERT INTO chat (ROWID, display_name, chat_identifier, style) "
        "VALUES (1, 'Buds', 'chat-buds', 43)"
    )
    conn.execute(
        "INSERT INTO chat (ROWID, display_name, chat_identifier, style) "
        "VALUES (2, 'Empty', 'chat-empty', 43)"
    )
    conn.execute("INSERT INTO handle (ROWID, id) VALUES (1, 'alice')")
    conn.execute("INSERT INTO handle (ROWID, id) VALUES (2, 'bob')")
    conn.execute(
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1), (1, 2)"
    )

    base = 1_000_000_000
    _insert_messages(
        conn,
        1,
        [
            (101, 1, 0, "msg one",   base + 0),
            (102, 2, 0, "msg two",   base + 100),
            (103, 0, 1, "msg three", base + 200),
            (104, 1, 0, "msg four",  base + 300),
            (105, 2, 0, "msg five",  base + 400),
            (106, 1, 0, "msg six",   base + 500),
            (107, 0, 1, "msg seven", base + 600),
            (108, 2, 0, "msg eight", base + 700),
        ],
    )
    conn.commit()
    return conn


@pytest.fixture
def db_with_tied_dates() -> sqlite3.Connection:
    """In-memory DB where messages 201 and 202 share the exact same date_ns."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    _schema(conn)
    conn.execute(
        "INSERT INTO chat (ROWID, display_name, chat_identifier, style) "
        "VALUES (1, 'Tied', 'chat-tied', 43)"
    )
    conn.execute("INSERT INTO handle (ROWID, id) VALUES (1, 'alice')")
    conn.execute(
        "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)"
    )
    base = 2_000_000_000
    _insert_messages(
        conn,
        1,
        [
            (201, 1, 0, "tied-early", base + 100),
            (202, 1, 0, "tied-late",  base + 100),  # same date as 201
            (203, 1, 0, "after",      base + 200),
        ],
    )
    conn.commit()
    return conn


@pytest.fixture
def db_two_chats_with_messages() -> sqlite3.Connection:
    """In-memory DB where BOTH chats have messages.

    chat 1 "Alpha": rowids 301-303
    chat 2 "Beta":  rowids 311-313
    Used to verify pagination from a rowid in chat A, with chat_id=A,
    doesn't bleed into chat B's messages.
    """
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    _schema(conn)
    conn.execute(
        "INSERT INTO chat (ROWID, display_name, chat_identifier, style) "
        "VALUES (1, 'Alpha', 'chat-alpha', 43), "
        "(2, 'Beta', 'chat-beta', 43)"
    )
    conn.execute("INSERT INTO handle (ROWID, id) VALUES (1, 'alice')")
    conn.execute(
        "INSERT INTO chat_handle_join (chat_id, handle_id) "
        "VALUES (1, 1), (2, 1)"
    )
    base = 3_000_000_000
    _insert_messages(conn, 1, [
        (301, 1, 0, "alpha-1", base + 0),
        (302, 1, 0, "alpha-2", base + 100),
        (303, 1, 0, "alpha-3", base + 200),
    ])
    _insert_messages(conn, 2, [
        (311, 1, 0, "beta-1", base + 50),
        (312, 1, 0, "beta-2", base + 150),
        (313, 1, 0, "beta-3", base + 250),
    ])
    conn.commit()
    return conn
