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
    2006: "emoji",       # iOS 18+ custom-emoji tapback
    2007: "sticker",     # sticker applied as a reaction
}
REACTION_GLYPHS = {
    2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂",
    2004: "‼️", 2005: "❓", 2006: "✨", 2007: "🧩",
}

APPLE_EPOCH_OFFSET = int(datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp())


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


def collect_analysis(conn: sqlite3.Connection, chat_id: int) -> dict[str, Any]:
    current = current_chat_members(conn, chat_id)
    all_labels = all_handle_labels(conn)

    def name_for(is_me: int, handle_id: int | None) -> str:
        if is_me:
            return "me"
        if not handle_id:
            return "unknown"
        return all_labels.get(handle_id, f"handle#{handle_id}")

    reactions = conn.execute(
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
            target.date AS target_date
        FROM active a
        JOIN message target ON target.guid = a.target_guid
        """,
        {"chat_id": chat_id},
    ).fetchall()

    given: dict[tuple[int, int], int] = defaultdict(int)
    received: dict[tuple[int, int], int] = defaultdict(int)
    by_type: dict[tuple[int, int], dict[int, int]] = defaultdict(lambda: defaultdict(int))
    pairwise: dict[tuple[int, int], dict[tuple[int, int], int]] = defaultdict(lambda: defaultdict(int))
    weekly: dict[tuple[int, int], dict[str, int]] = defaultdict(lambda: defaultdict(int))

    for r in reactions:
        reactor = person_key(r["reactor_is_me"], r["reactor_handle_id"])
        target = person_key(r["target_is_me"], r["target_handle_id"])
        given[reactor] += 1
        received[target] += 1
        by_type[reactor][r["rtype"]] += 1
        pairwise[reactor][target] += 1
        weekly[reactor][apple_ns_to_dt(r["rdate"]).strftime("%Y-W%V")] += 1

    top_rows = conn.execute(
        ACTIVE_REACTIONS_CTE
        + """
        SELECT
            target.ROWID AS target_rowid,
            target.text AS target_text,
            target.date AS target_date,
            target.handle_id AS target_handle_id,
            target.is_from_me AS target_is_me,
            COUNT(*) AS n
        FROM active a
        JOIN message target ON target.guid = a.target_guid
        GROUP BY target.ROWID
        ORDER BY n DESC
        LIMIT 10
        """,
        {"chat_id": chat_id},
    ).fetchall()

    img_sticker_rows = conn.execute(
        ACTIVE_REACTIONS_CTE
        + """
        SELECT
            a.handle_id AS reactor_handle_id,
            a.is_from_me AS reactor_is_me,
            COUNT(DISTINCT a.ROWID) AS n
        FROM active a
        JOIN message target ON target.guid = a.target_guid
        JOIN message_attachment_join maj ON maj.message_id = target.ROWID
        JOIN attachment att ON att.ROWID = maj.attachment_id
        WHERE a.associated_message_type = 2007
          AND att.mime_type LIKE 'image/%'
        GROUP BY a.is_from_me, a.handle_id
        ORDER BY n DESC
        """,
        {"chat_id": chat_id},
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
        row = conn.execute(
            """
            SELECT COUNT(*) AS n
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ?
              AND m.date >= ?
              AND NOT (COALESCE(m.handle_id,0) = ? AND m.is_from_me = ?)
              AND m.associated_message_type NOT BETWEEN 2000 AND 3007
            """,
            (chat_id, first, hid, is_me_flag),
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

    by_type_out = []
    for person, _ in sorted(given.items(), key=lambda x: -x[1]):
        row = {"person": name_for(*person)}
        for tcode, label in REACTION_LABELS.items():
            row[label] = by_type[person].get(tcode, 0)
        row["total"] = sum(by_type[person].values())
        by_type_out.append(row)

    sticker_leaderboard = rank({p: by_type[p].get(2007, 0) for p in by_type})
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

    top_messages = [
        {
            "sender": name_for(r["target_is_me"], r["target_handle_id"]),
            "date": apple_ns_to_dt(r["target_date"]).strftime("%Y-%m-%d"),
            "text": (r["target_text"] or "").replace("\n", " ") or None,
            "reaction_count": r["n"],
        }
        for r in top_rows
    ]

    now = datetime.now(timezone.utc)
    recent_cutoff = now - timedelta(weeks=4)
    baseline_start = now - timedelta(weeks=30)
    quiet_friends: list[dict] = []
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
        "reactions_given": reactions_given,
        "reactions_received": reactions_received,
        "by_type": by_type_out,
        "sticker_leaderboard": sticker_leaderboard,
        "emoji_leaderboard": emoji_leaderboard,
        "stickers_on_images": stickers_on_images,
        "reaction_rate": reaction_rate,
        "pairwise": pair_out[:50],
        "weekly_series": weekly_series,
        "top_messages": top_messages,
        "quiet_friends": quiet_friends,
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

    section("3b. Sticker-only leaderboard")
    if d["sticker_leaderboard"]:
        for r in d["sticker_leaderboard"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  No sticker reactions in this chat.")

    section("3c. Custom-emoji leaderboard (iOS 18+)")
    if d["emoji_leaderboard"]:
        for r in d["emoji_leaderboard"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  No custom-emoji reactions in this chat.")

    section("3d. Stickers-on-IMAGES leaderboard")
    if d["stickers_on_images"]:
        for r in d["stickers_on_images"]:
            print(f"  {r['person']:<25} {r['count']:>5}")
    else:
        print("  No sticker reactions on image messages in this chat.")

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

    p_st = sub.add_parser("stats", help="Validation totals for a chat")
    p_st.add_argument("chat_id", type=int)

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
            data = collect_analysis(conn, args.chat_id)
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
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
