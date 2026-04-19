#!/usr/bin/env python3
"""Blue Bubble Buds — iMessage group-chat reaction analyzer.

Supports human-readable text output (default) and JSON output (--json).
The JSON schema is documented at the bottom of this file and is the
contract the SwiftUI app consumes.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from statistics import median
from typing import Any

DEFAULT_DB = Path.home() / "Library" / "Messages" / "chat.db"
NAMES_FILE = Path(__file__).with_name("names.json")

REACTION_LABELS = {
    2000: "love",
    2001: "like",
    2002: "dislike",
    2003: "laugh",
    2004: "emphasize",
    2005: "question",
    2006: "emoji",           # iOS 18+ custom-emoji tapback
    2007: "tapback_sticker", # sticker applied via press-and-hold reaction menu
    1000: "stuck_sticker",   # standalone sticker dragged onto a message
}
REACTION_GLYPHS = {
    2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂",
    2004: "‼️", 2005: "❓", 2006: "✨", 2007: "🧩", 1000: "📌",
}

APPLE_EPOCH_OFFSET = int(datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp())


def decode_typedstream_text(blob: bytes | None) -> str | None:
    """Extract the primary NSString from Apple's typedstream attributedBody.

    Modern iMessage stores the rendered message text as an attributed
    string blob, not in the `text` column. The blob is a typedstream
    (legacy NSArchiver format). We find the first NSString and its
    length-prefixed UTF-8 payload.
    """
    if not blob or not blob.startswith(b"\x04\x0b"):
        return None
    idx = blob.find(b"NSString")
    if idx < 0:
        return None
    i = idx + len(b"NSString")
    while i < len(blob):
        if blob[i] == 0x2B:  # '+' precedes length-prefixed content
            mark = blob[i + 1]
            if mark == 0x81:
                length = int.from_bytes(blob[i + 2 : i + 4], "little")
                start = i + 4
            elif mark == 0x82:
                length = int.from_bytes(blob[i + 2 : i + 6], "little")
                start = i + 6
            elif mark == 0x83:
                length = int.from_bytes(blob[i + 2 : i + 10], "little")
                start = i + 10
            else:
                length = mark
                start = i + 2
            if 0 < length <= len(blob) - start:
                try:
                    return blob[start : start + length].decode("utf-8")
                except UnicodeDecodeError:
                    return None
            return None
        i += 1
    return None


def best_text(text_col: str | None, attributed_body: bytes | None) -> str | None:
    """Pick the most informative text for a message.

    - If text column is non-empty and not just the object-replacement char,
      use it.
    - Otherwise try decoding attributedBody.
    - If both produce only the placeholder, return None.
    """
    obj_replacement = "\ufffc"
    if text_col and text_col.strip().replace(obj_replacement, "").strip():
        return text_col.replace("\n", " ")
    decoded = decode_typedstream_text(attributed_body)
    if decoded and decoded.strip().replace(obj_replacement, "").strip():
        return decoded.replace("\n", " ")
    return None


def load_db(path: Path) -> sqlite3.Connection:
    tmp = Path(tempfile.gettempdir()) / "blue_bubble_buds_chat.db"
    shutil.copy2(path, tmp)
    conn = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def load_names() -> dict[str, str]:
    if NAMES_FILE.exists():
        return json.loads(NAMES_FILE.read_text())
    return {}


def apple_ns_to_dt(ns: int) -> datetime:
    return datetime.fromtimestamp(ns / 1e9 + APPLE_EPOCH_OFFSET, tz=timezone.utc)


ACTIVE_REACTIONS_CTE = """
WITH chat_msgs AS (
    SELECT m.guid AS guid, m.ROWID AS rowid
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    WHERE cmj.chat_id = :chat_id
),
normalized AS (
    SELECT
        m.ROWID,
        m.handle_id,
        m.is_from_me,
        m.associated_message_type,
        m.date,
        CASE
            WHEN m.associated_message_guid LIKE 'bp:%'
                THEN substr(m.associated_message_guid, 4)
            WHEN m.associated_message_guid LIKE 'p:%'
                THEN substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1)
            ELSE m.associated_message_guid
        END AS target_guid
    FROM message m
    WHERE m.associated_message_type BETWEEN 2000 AND 3007
      AND m.associated_message_guid IS NOT NULL
),
scoped AS (
    SELECT n.*
    FROM normalized n
    JOIN chat_msgs cm ON cm.guid = n.target_guid
),
ranked AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY s.handle_id, s.is_from_me, s.target_guid
            ORDER BY s.date DESC, s.ROWID DESC
        ) AS rn
    FROM scoped s
),
active AS (
    SELECT *
    FROM ranked
    WHERE rn = 1
      AND associated_message_type BETWEEN 2000 AND 2007
)
"""


def all_handle_labels(conn: sqlite3.Connection) -> dict[int, str]:
    names = load_names()
    rows = conn.execute("SELECT ROWID AS handle_id, id AS handle FROM handle").fetchall()
    return {r["handle_id"]: names.get(r["handle"], r["handle"]) for r in rows}


def current_chat_members(conn: sqlite3.Connection, chat_id: int) -> dict[int, str]:
    labels = all_handle_labels(conn)
    rows = conn.execute(
        "SELECT handle_id FROM chat_handle_join WHERE chat_id = ?",
        (chat_id,),
    ).fetchall()
    return {r["handle_id"]: labels[r["handle_id"]] for r in rows if r["handle_id"] in labels}


def chat_name(conn: sqlite3.Connection, chat_id: int) -> str:
    row = conn.execute(
        "SELECT COALESCE(NULLIF(display_name, ''), chat_identifier) AS name FROM chat WHERE ROWID = ?",
        (chat_id,),
    ).fetchone()
    return row["name"] if row else f"chat#{chat_id}"


def person_key(is_me: int, handle_id: int | None) -> tuple[int, int]:
    return (1, 0) if is_me else (0, handle_id or 0)


# ---------- data collection ----------

def collect_chats(conn: sqlite3.Connection, limit: int) -> list[dict]:
    names_map = load_names()
    rows = conn.execute(
        """
        SELECT
            c.ROWID AS chat_id,
            c.display_name AS display_name,
            c.chat_identifier AS chat_identifier,
            COUNT(DISTINCT chj.handle_id) AS members,
            COUNT(DISTINCT cmj.message_id) AS messages
        FROM chat c
        JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
        JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
        WHERE c.style = 43
        GROUP BY c.ROWID
        HAVING members >= 2
        ORDER BY messages DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()

    out = []
    for r in rows:
        member_handles = [
            h["id"]
            for h in conn.execute(
                "SELECT h.id FROM chat_handle_join chj "
                "JOIN handle h ON h.ROWID = chj.handle_id "
                "WHERE chj.chat_id = ? ORDER BY h.id",
                (r["chat_id"],),
            ).fetchall()
        ]
        out.append({
            "chat_id": r["chat_id"],
            "display_name": r["display_name"] or None,
            "chat_identifier": r["chat_identifier"],
            "member_count": r["members"],
            "message_count": r["messages"],
            "members": [names_map.get(h, h) for h in member_handles],
            "member_handles": member_handles,
        })
    return out


def collect_analysis(
    conn: sqlite3.Connection,
    chat_id: int,
    since_ns: int | None = None,
    until_ns: int | None = None,
) -> dict[str, Any]:
    current = current_chat_members(conn, chat_id)
    # Convert ns bounds to datetime for display / filtering display labels
    since_label = None
    if since_ns is not None:
        since_label = apple_ns_to_dt(since_ns).astimezone().strftime("%Y-%m-%d")
    all_labels = all_handle_labels(conn)

    def name_for(is_me: int, handle_id: int | None) -> str:
        if is_me:
            return "me"
        if not handle_id:
            return "unknown"
        return all_labels.get(handle_id, f"handle#{handle_id}")

    # Active tapbacks (2000-2007). Each event's sticker UTI (if applicable)
    # is joined so we can detect Live Photo stickers (public.heics).
    # associated_message_emoji carries the actual emoji for type 2006 custom
    # tapbacks (iOS 18+).
    reactions = list(conn.execute(
        ACTIVE_REACTIONS_CTE
        + """
        SELECT
            a.handle_id AS reactor_handle_id,
            a.is_from_me AS reactor_is_me,
            a.associated_message_type AS rtype,
            a.date AS rdate,
            target.handle_id AS target_handle_id,
            target.is_from_me AS target_is_me,
            target.text AS target_text,
            target.date AS target_date,
            (SELECT associated_message_emoji FROM message WHERE ROWID = a.ROWID) AS emoji_char,
            (SELECT att.uti
             FROM message_attachment_join maj
             JOIN attachment att ON att.ROWID = maj.attachment_id
             WHERE maj.message_id = a.ROWID AND att.is_sticker = 1
             LIMIT 1) AS sticker_uti
        FROM active a
        JOIN message target ON target.guid = a.target_guid
        """,
        {"chat_id": chat_id},
    ).fetchall())

    # Type 1000 = stuck stickers (dragged onto a message). Additive, not deduped.
    # rtype=1000 is preserved so we can break stuck vs tapback apart.
    stuck_stickers = conn.execute(
        """
        SELECT
            stuck.handle_id AS reactor_handle_id,
            stuck.is_from_me AS reactor_is_me,
            1000 AS rtype,
            stuck.date AS rdate,
            target.handle_id AS target_handle_id,
            target.is_from_me AS target_is_me,
            target.text AS target_text,
            target.date AS target_date,
            NULL AS emoji_char,
            att.uti AS sticker_uti
        FROM message stuck
        JOIN chat_message_join cmj ON cmj.message_id = stuck.ROWID
        JOIN message target ON target.guid = (
            CASE WHEN stuck.associated_message_guid LIKE 'bp:%'
                THEN substr(stuck.associated_message_guid, 4)
                WHEN stuck.associated_message_guid LIKE 'p:%'
                THEN substr(stuck.associated_message_guid, instr(stuck.associated_message_guid, '/') + 1)
                ELSE stuck.associated_message_guid END
        )
        LEFT JOIN message_attachment_join maj ON maj.message_id = stuck.ROWID
        LEFT JOIN attachment att ON att.ROWID = maj.attachment_id AND att.is_sticker = 1
        WHERE cmj.chat_id = :chat_id
          AND stuck.associated_message_type = 1000
          AND stuck.associated_message_guid IS NOT NULL
        """,
        {"chat_id": chat_id},
    ).fetchall()
    reactions.extend(stuck_stickers)

    given: dict[tuple[int, int], int] = defaultdict(int)
    received: dict[tuple[int, int], int] = defaultdict(int)
    by_type: dict[tuple[int, int], dict[int, int]] = defaultdict(lambda: defaultdict(int))
    received_by_type: dict[tuple[int, int], dict[int, int]] = defaultdict(lambda: defaultdict(int))
    pairwise: dict[tuple[int, int], dict[tuple[int, int], int]] = defaultdict(lambda: defaultdict(int))
    weekly: dict[tuple[int, int], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    stuck_count: dict[tuple[int, int], int] = defaultdict(int)
    tapback_sticker_count: dict[tuple[int, int], int] = defaultdict(int)
    live_count: dict[tuple[int, int], int] = defaultdict(int)
    # Custom-emoji tallies per person (given and received)
    emoji_given: dict[tuple[int, int], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    emoji_received: dict[tuple[int, int], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    # Sticker PATH tallies are computed lazily via the `top-stickers` subcommand
    # so the main analyze query stays fast. The aggregate COUNTS are still
    # computed upfront via by_type.

    for r in reactions:
        # Apply time filter (at the reaction event's own date)
        if since_ns is not None and r["rdate"] < since_ns:
            continue
        if until_ns is not None and r["rdate"] > until_ns:
            continue
        reactor = person_key(r["reactor_is_me"], r["reactor_handle_id"])
        target = person_key(r["target_is_me"], r["target_handle_id"])
        given[reactor] += 1
        received[target] += 1
        by_type[reactor][r["rtype"]] += 1
        received_by_type[target][r["rtype"]] += 1
        pairwise[reactor][target] += 1
        weekly[reactor][apple_ns_to_dt(r["rdate"]).strftime("%Y-W%V")] += 1
        if r["rtype"] == 1000:
            stuck_count[reactor] += 1
        elif r["rtype"] == 2007:
            tapback_sticker_count[reactor] += 1
        # Live Photo stickers have UTI 'public.heics' (HEIC sequence)
        if r["rtype"] in (1000, 2007) and r["sticker_uti"] == "public.heics":
            live_count[reactor] += 1
        # Custom-emoji payload lives on 2006 tapbacks in associated_message_emoji
        if r["rtype"] == 2006 and r["emoji_char"]:
            emoji_given[reactor][r["emoji_char"]] += 1
            emoji_received[target][r["emoji_char"]] += 1

    # Top-reacted messages counts both active tapbacks AND stuck stickers.
    # Top-reacted messages: filter the reaction events by the time window, not
    # the target message's date. (A recent reaction on an old message should
    # count when filter = "last week".)
    time_filter_active = since_ns is not None or until_ns is not None
    active_time_filter = ""
    stuck_time_filter = ""
    params = {"chat_id": chat_id}
    if since_ns is not None:
        active_time_filter += " AND date >= :since_ns "
        stuck_time_filter  += " AND m.date >= :since_ns "
        params["since_ns"] = since_ns
    if until_ns is not None:
        active_time_filter += " AND date <= :until_ns "
        stuck_time_filter  += " AND m.date <= :until_ns "
        params["until_ns"] = until_ns

    top_rows = conn.execute(
        ACTIVE_REACTIONS_CTE
        + f""",
        stuck AS (
            SELECT
                CASE WHEN m.associated_message_guid LIKE 'bp:%'
                     THEN substr(m.associated_message_guid, 4)
                     WHEN m.associated_message_guid LIKE 'p:%'
                     THEN substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1)
                     ELSE m.associated_message_guid END AS target_guid
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = :chat_id
              AND m.associated_message_type = 1000
              AND m.associated_message_guid IS NOT NULL
              {stuck_time_filter}
        ),
        filtered_active AS (
            SELECT target_guid FROM active WHERE 1=1 {active_time_filter}
        ),
        all_events AS (
            SELECT target_guid FROM filtered_active
            UNION ALL
            SELECT target_guid FROM stuck
        )
        SELECT
            target.ROWID AS target_rowid,
            target.guid AS target_guid,
            target.text AS target_text,
            target.attributedBody AS target_attributed,
            target.date AS target_date,
            target.handle_id AS target_handle_id,
            target.is_from_me AS target_is_me,
            COUNT(*) AS n
        FROM all_events e
        JOIN message target ON target.guid = e.target_guid
        GROUP BY target.ROWID
        ORDER BY n DESC
        LIMIT 10
        """,
        params,
    ).fetchall()

    # Stickers on visual media: includes BOTH tapback stickers (2007) and
    # stuck stickers (type 1000). Visual media = image/video attachments,
    # URL preview cards, and #images GIFs.
    img_sticker_rows = conn.execute(
        ACTIVE_REACTIONS_CTE
        + f""",
        stuck AS (
            SELECT m.handle_id, m.is_from_me, m.ROWID,
                CASE WHEN m.associated_message_guid LIKE 'bp:%'
                     THEN substr(m.associated_message_guid, 4)
                     WHEN m.associated_message_guid LIKE 'p:%'
                     THEN substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1)
                     ELSE m.associated_message_guid END AS target_guid
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = :chat_id
              AND m.associated_message_type = 1000
              AND m.associated_message_guid IS NOT NULL
              {stuck_time_filter}
        ),
        all_stickers AS (
            SELECT handle_id, is_from_me, ROWID, target_guid
            FROM active WHERE associated_message_type = 2007 {active_time_filter}
            UNION ALL
            SELECT handle_id, is_from_me, ROWID, target_guid FROM stuck
        )
        SELECT
            a.handle_id AS reactor_handle_id,
            a.is_from_me AS reactor_is_me,
            COUNT(*) AS n
        FROM all_stickers a
        JOIN message target ON target.guid = a.target_guid
        WHERE (
            -- URL preview cards (Reddit/Twitter/YouTube/news/etc.)
            target.balloon_bundle_id = 'com.apple.messages.URLBalloonProvider'
            -- GIF-picker extension
            OR target.balloon_bundle_id LIKE '%#images%'
            -- Any image/video attachment, including NULL-mime attachments caught by extension
            OR EXISTS (
                SELECT 1
                FROM message_attachment_join maj
                JOIN attachment att ON att.ROWID = maj.attachment_id
                WHERE maj.message_id = target.ROWID
                  AND (
                    att.mime_type LIKE 'image/%'
                    OR att.mime_type LIKE 'video/%'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.heic'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.heif'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.jpg'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.jpeg'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.png'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.gif'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.webp'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.mov'
                    OR lower(COALESCE(att.filename, att.transfer_name, '')) GLOB '*.mp4'
                  )
            )
          )
        GROUP BY a.is_from_me, a.handle_id
        ORDER BY n DESC
        """,
        params,
    ).fetchall()

    member_first_msg = dict(conn.execute(
        """
        SELECT m.handle_id, MIN(m.date) AS first_date
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ? AND m.handle_id IS NOT NULL AND m.is_from_me = 0
        GROUP BY m.handle_id
        """,
        (chat_id,),
    ).fetchall())
    me_first_row = conn.execute(
        """
        SELECT MIN(m.date) AS first_date
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ? AND m.is_from_me = 1
        """,
        (chat_id,),
    ).fetchone()
    me_first_msg = me_first_row["first_date"] if me_first_row else None

    def eligible_msg_count(person: tuple[int, int]) -> int:
        is_me_flag, hid = person
        first = me_first_msg if is_me_flag else member_first_msg.get(hid)
        if first is None:
            return 0
        # Denominator window: the later of (join date) and (filter since);
        # the earlier of (now) and (filter until).
        effective_start = max(first, since_ns) if since_ns is not None else first
        time_extra = ""
        qparams = [chat_id, effective_start, hid, is_me_flag]
        if until_ns is not None:
            time_extra = " AND m.date <= ? "
            qparams.append(until_ns)
        row = conn.execute(
            f"""
            SELECT COUNT(*) AS n
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ?
              AND m.date >= ?
              AND NOT (COALESCE(m.handle_id,0) = ? AND m.is_from_me = ?)
              AND m.associated_message_type NOT BETWEEN 2000 AND 3007
              {time_extra}
            """,
            qparams,
        ).fetchone()
        return row["n"]

    def rank(counts: dict[tuple[int, int], int]) -> list[dict]:
        return [
            {"person": name_for(*p), "count": n}
            for p, n in sorted(counts.items(), key=lambda x: -x[1])
            if n > 0
        ]

    reactions_given = rank(given)
    reactions_received = rank(received)

    def top_emojis(counts: dict[str, int], n: int = 3) -> list[dict]:
        return [
            {"emoji": e, "count": c}
            for e, c in sorted(counts.items(), key=lambda x: -x[1])[:n]
        ]

    by_type_out = []
    for person, _ in sorted(given.items(), key=lambda x: -x[1]):
        is_me, hid = person
        row = {"person": name_for(*person), "handle_id": hid, "is_from_me": bool(is_me)}
        for tcode, label in REACTION_LABELS.items():
            row[label] = by_type[person].get(tcode, 0)
        row["total"] = sum(by_type[person].values())
        row["top_custom_emojis"] = top_emojis(emoji_given[person])
        by_type_out.append(row)

    received_by_type_out = []
    for person, _ in sorted(received.items(), key=lambda x: -x[1]):
        is_me, hid = person
        row = {"person": name_for(*person), "handle_id": hid, "is_from_me": bool(is_me)}
        for tcode, label in REACTION_LABELS.items():
            row[label] = received_by_type[person].get(tcode, 0)
        row["total"] = sum(received_by_type[person].values())
        row["top_custom_emojis"] = top_emojis(emoji_received[person])
        received_by_type_out.append(row)

    sticker_leaderboard = rank({
        p: by_type[p].get(2007, 0) + by_type[p].get(1000, 0) for p in by_type
    })
    stuck_sticker_leaderboard = rank(stuck_count)
    tapback_sticker_leaderboard = rank(tapback_sticker_count)
    live_sticker_leaderboard = rank(live_count)
    emoji_leaderboard = rank({p: by_type[p].get(2006, 0) for p in by_type})

    stickers_on_images = [
        {"person": name_for(r["reactor_is_me"], r["reactor_handle_id"]), "count": r["n"]}
        for r in img_sticker_rows
    ]

    reaction_rate = []
    for person, count in sorted(given.items(), key=lambda x: -x[1]):
        elig = eligible_msg_count(person)
        reaction_rate.append({
            "person": name_for(*person),
            "reactions": count,
            "eligible_messages": elig,
            "per_100": round((count / elig * 100) if elig else 0.0, 2),
        })

    pair_out = []
    for reactor, targets in pairwise.items():
        for target, n in targets.items():
            if reactor == target:
                continue
            pair_out.append({
                "reactor": name_for(*reactor),
                "target": name_for(*target),
                "count": n,
            })
    pair_out.sort(key=lambda x: -x["count"])

    all_weeks = sorted({wk for counts in weekly.values() for wk in counts})
    recent_weeks = all_weeks[-12:]
    weekly_series = {
        "weeks": recent_weeks,
        "series": [
            {
                "person": name_for(*person),
                "counts": [weekly[person].get(wk, 0) for wk in recent_weeks],
            }
            for person, _ in sorted(given.items(), key=lambda x: -x[1])
        ],
    }

    top_messages = []
    for r in top_rows:
        attachments = conn.execute(
            """
            SELECT att.filename, att.transfer_name, att.mime_type, att.uti,
                   att.is_sticker
            FROM message_attachment_join maj
            JOIN attachment att ON att.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            """,
            (r["target_rowid"],),
        ).fetchall()
        parent = conn.execute(
            "SELECT balloon_bundle_id FROM message WHERE ROWID = ?",
            (r["target_rowid"],),
        ).fetchone()
        # Local time for date display (was UTC — could be off by a day)
        dt_local = apple_ns_to_dt(r["target_date"]).astimezone()
        top_messages.append({
            "rowid": r["target_rowid"],
            "sender": name_for(r["target_is_me"], r["target_handle_id"]),
            "date": dt_local.strftime("%Y-%m-%d"),
            "datetime": dt_local.strftime("%Y-%m-%d %H:%M"),
            "guid": r["target_guid"],
            "text": best_text(r["target_text"], r["target_attributed"]),
            "reaction_count": r["n"],
            "balloon_bundle_id": parent["balloon_bundle_id"] if parent else None,
            "has_ghost_attachment": (r["target_text"] or "").strip() == "\ufffc" and not attachments,
            "attachments": [
                {
                    "path": (a["filename"] or "").replace("~", str(Path.home()), 1) or None,
                    "name": a["transfer_name"],
                    "mime_type": a["mime_type"],
                    "uti": a["uti"],
                    "is_sticker": bool(a["is_sticker"]),
                }
                for a in attachments
            ],
        })

    # Quiet-friend detector uses its own intrinsic time window (recent 4w vs
    # prior 26w baseline). Disable when the user has a time filter active —
    # the semantics don't compose.
    now = datetime.now(timezone.utc)
    recent_cutoff = now - timedelta(weeks=4)
    baseline_start = now - timedelta(weeks=30)
    quiet_friends: list[dict] = []
    if not time_filter_active:
        for person, _ in given.items():
            recent = 0
            baseline_by_wk: dict[str, int] = defaultdict(int)
            for r in reactions:
                if person_key(r["reactor_is_me"], r["reactor_handle_id"]) != person:
                    continue
                dt = apple_ns_to_dt(r["rdate"])
                if dt >= recent_cutoff:
                    recent += 1
                elif baseline_start <= dt:
                    baseline_by_wk[dt.strftime("%Y-W%V")] += 1
            if not baseline_by_wk:
                continue
            baseline_median = median(baseline_by_wk.values())
            if baseline_median < 2:
                continue
            recent_per_week = recent / 4
            if recent_per_week < 0.5 * baseline_median:
                quiet_friends.append({
                    "person": name_for(*person),
                    "baseline_per_week": round(baseline_median, 2),
                    "recent_per_week": round(recent_per_week, 2),
                    "drop_pct": round(100 * (1 - recent_per_week / baseline_median), 1),
                })
        quiet_friends.sort(key=lambda x: -x["drop_pct"])

    return {
        "chat_id": chat_id,
        "chat_name": chat_name(conn, chat_id),
        "member_count": len(current),
        "time_filter": {
            "active": time_filter_active,
            "since": since_label,
            "since_ns": since_ns,
            "until_ns": until_ns,
        },
        "reactions_given": reactions_given,
        "reactions_received": reactions_received,
        "by_type": by_type_out,
        "received_by_type": received_by_type_out,
        "sticker_leaderboard": sticker_leaderboard,
        "stuck_sticker_leaderboard": stuck_sticker_leaderboard,
        "tapback_sticker_leaderboard": tapback_sticker_leaderboard,
        "live_sticker_leaderboard": live_sticker_leaderboard,
        "emoji_leaderboard": emoji_leaderboard,
        "stickers_on_visual_media": stickers_on_images,
        "reaction_rate": reaction_rate,
        "pairwise": pair_out[:50],
        "weekly_series": weekly_series,
        "top_messages": top_messages,
        "quiet_friends": quiet_friends,
    }


def collect_top_stickers(
    conn: sqlite3.Connection,
    chat_id: int,
    handle_id: int,
    is_from_me: bool,
    rtype: int,            # 2007 = tapback, 1000 = stuck
    direction: str = "given",  # "given" or "received"
    limit: int = 5,
) -> dict[str, Any]:
    """Return a person's top sticker paths for one (chat, type, direction)."""
    handle_match = "m.handle_id = ?" if not is_from_me else "m.is_from_me = 1"
    params: list[Any] = [chat_id]

    if rtype == 2007:
        # Tapback stickers: scope via the active-reactions CTE.
        sql = ACTIVE_REACTIONS_CTE + """
            SELECT
                COALESCE(att.transfer_name, att.filename) AS sticker_key,
                MAX(att.filename) AS path,
                COUNT(*) AS n
            FROM active a
            JOIN message target ON target.guid = a.target_guid
            JOIN message_attachment_join maj ON maj.message_id = a.ROWID
            -- No is_sticker filter: tapback (2007) and stuck-sticker (1000)
            -- rows ARE sticker messages by definition. The is_sticker attachment
            -- flag is unreliable — often 0 or NULL for legitimate stickers.
            JOIN attachment att ON att.ROWID = maj.attachment_id
            WHERE a.associated_message_type = 2007
        """
        if direction == "given":
            sql += " AND " + ("a.is_from_me = 1" if is_from_me else "a.handle_id = :handle_id")
        else:
            sql += " AND " + ("target.is_from_me = 1" if is_from_me else "target.handle_id = :handle_id")
        sql += " GROUP BY sticker_key ORDER BY n DESC LIMIT :limit"
        cur = conn.execute(sql, {"chat_id": chat_id, "handle_id": handle_id, "limit": limit})
    else:  # 1000 stuck sticker
        sql = """
            SELECT
                COALESCE(att.transfer_name, att.filename) AS sticker_key,
                MAX(att.filename) AS path,
                COUNT(*) AS n
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN message target ON target.guid = (
                CASE WHEN m.associated_message_guid LIKE 'bp:%' THEN substr(m.associated_message_guid, 4)
                     WHEN m.associated_message_guid LIKE 'p:%' THEN substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1)
                     ELSE m.associated_message_guid END
            )
            JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            -- No is_sticker filter: tapback (2007) and stuck-sticker (1000)
            -- rows ARE sticker messages by definition. The is_sticker attachment
            -- flag is unreliable — often 0 or NULL for legitimate stickers.
            JOIN attachment att ON att.ROWID = maj.attachment_id
            WHERE cmj.chat_id = :chat_id
              AND m.associated_message_type = 1000
        """
        if direction == "given":
            sql += " AND " + ("m.is_from_me = 1" if is_from_me else "m.handle_id = :handle_id")
        else:
            sql += " AND " + ("target.is_from_me = 1" if is_from_me else "target.handle_id = :handle_id")
        sql += " GROUP BY sticker_key ORDER BY n DESC LIMIT :limit"
        cur = conn.execute(sql, {"chat_id": chat_id, "handle_id": handle_id, "limit": limit})

    stickers = [
        {"path": (r["path"] or "").replace("~", str(Path.home()), 1), "count": r["n"]}
        for r in cur.fetchall() if r["path"]
    ]
    return {"chat_id": chat_id, "handle_id": handle_id, "is_from_me": is_from_me,
            "rtype": rtype, "direction": direction, "stickers": stickers}


def collect_context(
    conn: sqlite3.Connection,
    chat_id: int,
    target_rowid: int,
    before: int = 12,
    after: int = 12,
) -> dict[str, Any]:
    """Fetch messages surrounding a target message (for a contextual view).

    Excludes reaction/sticker messages (types in 1000, 2000-3007) from the
    thread view — they're counted as reaction badges on the target message
    but aren't themselves content.
    """
    all_labels = all_handle_labels(conn)

    def name_for(is_me: int, handle_id: int | None) -> str:
        if is_me:
            return "me"
        if not handle_id:
            return "unknown"
        return all_labels.get(handle_id, f"handle#{handle_id}")

    target = conn.execute(
        "SELECT ROWID, guid, date FROM message WHERE ROWID = ?",
        (target_rowid,),
    ).fetchone()
    if not target:
        return {"error": f"message {target_rowid} not found"}

    target_date = target["date"]

    # Fetch messages before and after the target, within the chat.
    # Exclude tapback/sticker rows (they're reactions, not content).
    before_rows = conn.execute(
        """
        SELECT m.ROWID, m.guid, m.handle_id, m.is_from_me, m.date, m.text,
               m.attributedBody, m.balloon_bundle_id
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ?
          AND m.date < ?
          AND m.associated_message_type = 0
        ORDER BY m.date DESC
        LIMIT ?
        """,
        (chat_id, target_date, before),
    ).fetchall()
    target_row = conn.execute(
        """
        SELECT m.ROWID, m.guid, m.handle_id, m.is_from_me, m.date, m.text,
               m.attributedBody, m.balloon_bundle_id
        FROM message m WHERE m.ROWID = ?
        """,
        (target_rowid,),
    ).fetchone()
    after_rows = conn.execute(
        """
        SELECT m.ROWID, m.guid, m.handle_id, m.is_from_me, m.date, m.text,
               m.attributedBody, m.balloon_bundle_id
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ?
          AND m.date > ?
          AND m.associated_message_type = 0
        ORDER BY m.date ASC
        LIMIT ?
        """,
        (chat_id, target_date, after),
    ).fetchall()

    ordered = list(reversed(before_rows)) + [target_row] + list(after_rows)

    def enrich(row: sqlite3.Row) -> dict[str, Any]:
        if row is None:
            return None
        atts = conn.execute(
            """
            SELECT att.filename, att.transfer_name, att.mime_type, att.uti, att.is_sticker
            FROM message_attachment_join maj
            JOIN attachment att ON att.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
            """,
            (row["ROWID"],),
        ).fetchall()
        # Count reactions on this message (tapbacks + stuck stickers)
        rxn = conn.execute(
            """
            SELECT COUNT(*) AS n
            FROM message r
            WHERE r.associated_message_guid IN ('bp:' || ?, 'p:0/' || ?, 'p:1/' || ?, 'p:2/' || ?)
              AND (r.associated_message_type BETWEEN 2000 AND 2007 OR r.associated_message_type = 1000)
            """,
            (row["guid"], row["guid"], row["guid"], row["guid"]),
        ).fetchone()["n"]
        dt_local = apple_ns_to_dt(row["date"]).astimezone()
        return {
            "rowid": row["ROWID"],
            "guid": row["guid"],
            "sender": name_for(row["is_from_me"], row["handle_id"]),
            "is_from_me": bool(row["is_from_me"]),
            "datetime": dt_local.strftime("%Y-%m-%d %H:%M"),
            "date": dt_local.strftime("%Y-%m-%d"),
            "is_target": row["ROWID"] == target_rowid,
            "text": best_text(row["text"], row["attributedBody"]),
            "balloon_bundle_id": row["balloon_bundle_id"],
            "reaction_count": rxn,
            "attachments": [
                {
                    "path": (a["filename"] or "").replace("~", str(Path.home()), 1) or None,
                    "name": a["transfer_name"],
                    "mime_type": a["mime_type"],
                    "uti": a["uti"],
                    "is_sticker": bool(a["is_sticker"]),
                }
                for a in atts
            ],
        }

    messages = [enrich(r) for r in ordered if r is not None]

    return {
        "chat_id": chat_id,
        "chat_name": chat_name(conn, chat_id),
        "target_rowid": target_rowid,
        "messages": messages,
    }


def collect_stats(conn: sqlite3.Connection, chat_id: int) -> dict[str, Any]:
    all_labels = all_handle_labels(conn)

    def name_for(is_me: int, handle_id: int | None) -> str:
        if is_me:
            return "me"
        if not handle_id:
            return "unknown"
        return all_labels.get(handle_id, f"handle#{handle_id}")

    dr = conn.execute(
        """
        SELECT MIN(m.date) AS first, MAX(m.date) AS last, COUNT(*) AS total
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ?
        """,
        (chat_id,),
    ).fetchone()

    split = conn.execute(
        """
        SELECT
            SUM(CASE WHEN m.associated_message_type BETWEEN 2000 AND 3007 THEN 1 ELSE 0 END) AS tapback_rows,
            SUM(CASE WHEN m.associated_message_type BETWEEN 2000 AND 3007 THEN 0 ELSE 1 END) AS real_msgs
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ?
        """,
        (chat_id,),
    ).fetchone()

    active_total = conn.execute(
        ACTIVE_REACTIONS_CTE + "SELECT COUNT(*) AS n FROM active",
        {"chat_id": chat_id},
    ).fetchone()["n"]

    sender_rows = conn.execute(
        """
        SELECT m.handle_id, m.is_from_me AS is_me, COUNT(*) AS n
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ?
          AND m.associated_message_type NOT BETWEEN 2000 AND 3007
        GROUP BY m.is_from_me, m.handle_id
        ORDER BY n DESC
        """,
        (chat_id,),
    ).fetchall()

    dist = conn.execute(
        ACTIVE_REACTIONS_CTE
        + """
        SELECT n_reactions, COUNT(*) AS n_messages
        FROM (
            SELECT target_guid, COUNT(*) AS n_reactions
            FROM active
            GROUP BY target_guid
        )
        GROUP BY n_reactions
        ORDER BY n_reactions
        """,
        {"chat_id": chat_id},
    ).fetchall()

    self_rx = conn.execute(
        ACTIVE_REACTIONS_CTE
        + """
        SELECT a.is_from_me AS reactor_is_me, a.handle_id AS reactor_handle_id, COUNT(*) AS n
        FROM active a
        JOIN message target ON target.guid = a.target_guid
        WHERE (a.is_from_me = target.is_from_me)
          AND (a.handle_id IS target.handle_id)
        GROUP BY a.is_from_me, a.handle_id
        ORDER BY n DESC
        """,
        {"chat_id": chat_id},
    ).fetchall()

    orphans = conn.execute(
        """
        WITH all_tapbacks AS (
            SELECT
                m.ROWID AS rowid,
                CASE
                    WHEN m.associated_message_guid LIKE 'bp:%'
                        THEN substr(m.associated_message_guid, 4)
                    WHEN m.associated_message_guid LIKE 'p:%'
                        THEN substr(m.associated_message_guid, instr(m.associated_message_guid, '/') + 1)
                    ELSE m.associated_message_guid
                END AS target_guid
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = :chat_id
              AND m.associated_message_type BETWEEN 2000 AND 3007
              AND m.associated_message_guid IS NOT NULL
        )
        SELECT COUNT(*) AS n
        FROM all_tapbacks t
        LEFT JOIN message target ON target.guid = t.target_guid
        WHERE target.ROWID IS NULL
        """,
        {"chat_id": chat_id},
    ).fetchone()["n"]

    total_msgs = sum(r["n"] for r in sender_rows)
    reacted_msgs = sum(r["n_messages"] for r in dist)

    return {
        "chat_id": chat_id,
        "chat_name": chat_name(conn, chat_id),
        "date_range": {
            "first": apple_ns_to_dt(dr["first"]).strftime("%Y-%m-%d") if dr["first"] else None,
            "last": apple_ns_to_dt(dr["last"]).strftime("%Y-%m-%d") if dr["last"] else None,
        },
        "totals": {
            "all_rows": dr["total"],
            "real_messages": split["real_msgs"],
            "tapback_rows": split["tapback_rows"],
            "active_tapbacks": active_total,
            "churn_events": (split["tapback_rows"] - active_total) if split["tapback_rows"] else 0,
        },
        "messages_per_sender": [
            {"person": name_for(r["is_me"], r["handle_id"]), "count": r["n"]}
            for r in sender_rows
        ],
        "reaction_distribution": [
            {"reactions_on_message": r["n_reactions"], "message_count": r["n_messages"]}
            for r in dist
        ],
        "reaction_coverage": {
            "reacted_messages": reacted_msgs,
            "total_messages": total_msgs,
            "pct": round(100 * reacted_msgs / total_msgs, 1) if total_msgs else 0.0,
        },
        "self_reactions": [
            {"person": name_for(r["reactor_is_me"], r["reactor_handle_id"]), "count": r["n"]}
            for r in self_rx
        ],
        "orphan_tapbacks": orphans,
    }


# ---------- text rendering ----------

def section(title: str) -> None:
    print(f"\n=== {title} ===")


def render_list_chats_text(chats: list[dict]) -> None:
    for c in chats:
        label = c["display_name"] or "(no title)"
        print(f"[{c['chat_id']}]  {label}")
        print(f"    {c['member_count']} members · {c['message_count']} messages")
        print(f"    with: {', '.join(c['members'])}")
        print()


def render_analysis_text(d: dict) -> None:
    print(f"Chat: {d['chat_name']}  (chat_id={d['chat_id']}, {d['member_count']} current members)")

    section("1. Reactions GIVEN per person")
    for r in d["reactions_given"]:
        print(f"  {r['person']:<25} {r['count']:>5}")

    section("2. Reactions RECEIVED per person")
    for r in d["reactions_received"]:
        print(f"  {r['person']:<25} {r['count']:>5}")

    section("3. Breakdown by reaction type (rows = reactor)")
    types = list(REACTION_LABELS.values())
    header = f"  {'':<25}" + "".join(f"{t:>10}" for t in types) + f"{'total':>10}"
    print(header)
    for r in d["by_type"]:
        cells = "".join(f"{r.get(t, 0):>10}" for t in types)
        print(f"  {r['person']:<25}{cells}{r['total']:>10}")

    section("3b. Sticker leaderboard (stuck + tapback combined)")
    if d["sticker_leaderboard"]:
        for r in d["sticker_leaderboard"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  No sticker activity in this chat.")

    section("3b-i. Stuck stickers (dragged onto messages, type 1000)")
    if d["stuck_sticker_leaderboard"]:
        for r in d["stuck_sticker_leaderboard"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  None.")

    section("3b-ii. Tapback stickers (applied via reaction menu, type 2007)")
    if d["tapback_sticker_leaderboard"]:
        for r in d["tapback_sticker_leaderboard"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  None.")

    section("3b-iii. Live Photo stickers (animated, public.heics)")
    if d["live_sticker_leaderboard"]:
        for r in d["live_sticker_leaderboard"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  No Live Photo stickers in this chat.")

    section("3c. Custom-emoji leaderboard (iOS 18+)")
    if d["emoji_leaderboard"]:
        for r in d["emoji_leaderboard"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  No custom-emoji reactions in this chat.")

    section("3d. Stickers on visual media (photos + videos, by extension)")
    if d["stickers_on_visual_media"]:
        for r in d["stickers_on_visual_media"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  No sticker reactions on visual media in this chat.")

    section("4. Reaction rate (reactions per 100 eligible messages)")
    for r in d["reaction_rate"]:
        print(f"  {r['person']:<25} {r['reactions']:>5} / {r['eligible_messages']:>6} msgs  =  {r['per_100']:>6.2f} per 100")

    section("5. Pairwise affinity (reactor → target sender, top 15)")
    for p in d["pairwise"][:15]:
        print(f"  {p['reactor']:<20} → {p['target']:<20} {p['count']:>5}")

    section("6. Time series (reactions per week per person, last 12 weeks)")
    weeks = d["weekly_series"]["weeks"]
    print(f"  {'':<20}" + "".join(f"{wk[-3:]:>5}" for wk in weeks))
    for s in d["weekly_series"]["series"]:
        cells = "".join(f"{n:>5}" for n in s["counts"])
        print(f"  {s['person']:<20}{cells}")

    section("7. Top 10 most-reacted-to messages")
    for m in d["top_messages"]:
        text = (m["text"] or "(attachment/empty)")[:80]
        print(f"  {m['reaction_count']:>3} reactions  {m['date']}  {m['sender']:<20} {text}")

    section("8. Quiet Friend detector (recent 4w vs. prior 26w baseline)")
    if d["quiet_friends"]:
        for q in d["quiet_friends"]:
            print(f"  {q['person']:<25} baseline {q['baseline_per_week']:>5.1f}/wk → "
                  f"recent {q['recent_per_week']:>5.2f}/wk  (↓ {q['drop_pct']:.0f}%)  (check in!)")
    else:
        print("  No quiet friends detected. Everyone's still engaged.")


def render_stats_text(d: dict) -> None:
    print(f"Chat: {d['chat_name']}  (chat_id={d['chat_id']})")
    print(f"Date range: {d['date_range']['first']}  →  {d['date_range']['last']}")
    t = d["totals"]
    print(f"Total rows in chat: {t['all_rows']:,}  (includes tapbacks)")
    print(f"Real messages: {t['real_messages']:,}")
    print(f"Tapback rows (raw add+remove events): {t['tapback_rows']:,}")
    print(f"Active tapbacks (net state): {t['active_tapbacks']:,}")
    if t["tapback_rows"]:
        pct = 100 * t["churn_events"] / t["tapback_rows"]
        print(f"  → {t['churn_events']:,} events ({pct:.1f}%) were removed or overwritten")

    section("Messages sent per person (real messages only)")
    total = sum(r["count"] for r in d["messages_per_sender"])
    for r in d["messages_per_sender"]:
        pct = 100 * r["count"] / total if total else 0
        print(f"  {r['person']:<25} {r['count']:>7,}  ({pct:5.1f}%)")

    section("Distribution of reactions per reacted message")
    for r in d["reaction_distribution"]:
        print(f"  {r['reactions_on_message']} reaction(s):  {r['message_count']:,} messages")
    cov = d["reaction_coverage"]
    print(f"  Coverage: {cov['reacted_messages']:,} of {cov['total_messages']:,} messages "
          f"got at least one reaction ({cov['pct']:.1f}%)")

    section("Self-reactions (reacting to your own message)")
    if d["self_reactions"]:
        for r in d["self_reactions"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  None — nobody reacts to their own messages.")

    section("Orphan tapbacks (target message not found in chat)")
    print(f"  {d['orphan_tapbacks']} tapbacks point to a target we can't find.")


# ---------- CLI ----------

def main() -> int:
    ap = argparse.ArgumentParser(description="Blue Bubble Buds — iMessage reaction analyzer")
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help="Path to chat.db")
    ap.add_argument("--json", action="store_true", help="Emit JSON instead of text")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list-chats", help="List group chats ranked by message count")
    p_list.add_argument("--limit", type=int, default=50)

    p_an = sub.add_parser("analyze", help="Analyze reactions for one chat")
    p_an.add_argument("chat_id", type=int)
    p_an.add_argument("--since", type=str, default=None,
                      help="ISO date (YYYY-MM-DD) — only include reactions on/after this date")
    p_an.add_argument("--until", type=str, default=None,
                      help="ISO date (YYYY-MM-DD) — only include reactions on/before this date")

    p_st = sub.add_parser("stats", help="Validation totals for a chat")
    p_st.add_argument("chat_id", type=int)

    p_ctx = sub.add_parser("context", help="Messages surrounding a target message")
    p_ctx.add_argument("chat_id", type=int)
    p_ctx.add_argument("rowid", type=int)
    p_ctx.add_argument("--before", type=int, default=12)
    p_ctx.add_argument("--after", type=int, default=12)

    p_ts = sub.add_parser("top-stickers", help="Top N sticker paths for a person in a chat")
    p_ts.add_argument("chat_id", type=int)
    p_ts.add_argument("handle_id", type=int, help="0 for self")
    p_ts.add_argument("--me", action="store_true", help="Match on is_from_me=1 (self)")
    p_ts.add_argument("--rtype", type=int, choices=[2007, 1000], required=True,
                      help="2007=tapback sticker, 1000=stuck sticker")
    p_ts.add_argument("--direction", choices=["given", "received"], default="given")
    p_ts.add_argument("--limit", type=int, default=5)

    args = ap.parse_args()
    conn = load_db(args.db)
    try:
        if args.cmd == "list-chats":
            data = collect_chats(conn, args.limit)
            if args.json:
                print(json.dumps({"chats": data}, indent=2, ensure_ascii=False))
            else:
                render_list_chats_text(data)
        elif args.cmd == "analyze":
            def iso_to_apple_ns(s: str | None) -> int | None:
                if not s: return None
                dt = datetime.fromisoformat(s)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc).astimezone()
                return int((dt.timestamp() - APPLE_EPOCH_OFFSET) * 1e9)
            data = collect_analysis(conn, args.chat_id,
                                    since_ns=iso_to_apple_ns(args.since),
                                    until_ns=iso_to_apple_ns(args.until))
            if args.json:
                print(json.dumps(data, indent=2, ensure_ascii=False))
            else:
                render_analysis_text(data)
        elif args.cmd == "stats":
            data = collect_stats(conn, args.chat_id)
            if args.json:
                print(json.dumps(data, indent=2, ensure_ascii=False))
            else:
                render_stats_text(data)
        elif args.cmd == "top-stickers":
            data = collect_top_stickers(
                conn, args.chat_id, args.handle_id, args.me,
                args.rtype, args.direction, args.limit,
            )
            if args.json:
                print(json.dumps(data, indent=2, ensure_ascii=False))
            else:
                for s in data["stickers"]:
                    print(f"  {s['count']:>3}x {s['path']}")
        elif args.cmd == "context":
            data = collect_context(conn, args.chat_id, args.rowid, args.before, args.after)
            if args.json:
                print(json.dumps(data, indent=2, ensure_ascii=False))
            else:
                for m in data.get("messages", []):
                    marker = " ← TARGET" if m["is_target"] else ""
                    text = (m["text"] or "(no text)")[:100]
                    print(f"[{m['datetime']}] {m['sender']:<20} ({m['reaction_count']} rxn) {text}{marker}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
