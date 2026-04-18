#!/usr/bin/env python3
"""Build names.json from the macOS Contacts AddressBook.

Joins all contact sources to the handles that appear in chat.db, so the
resulting file only contains names for people you've actually messaged.
"""

from __future__ import annotations

import json
import re
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

CHAT_DB = Path.home() / "Library" / "Messages" / "chat.db"
AB_ROOT = Path.home() / "Library" / "Application Support" / "AddressBook"
OUT = Path(__file__).with_name("names.json")


def normalize_phone(raw: str) -> str | None:
    """Collapse a raw phone number to E.164 assuming +1 default (US/Canada)."""
    if not raw:
        return None
    digits = re.sub(r"\D", "", raw)
    if not digits:
        return None
    if len(digits) == 10:
        return "+1" + digits
    if len(digits) == 11 and digits.startswith("1"):
        return "+" + digits
    if raw.startswith("+"):
        return "+" + digits
    # Fallback — may not match iMessage format, but include it
    return "+" + digits


def display_name(first: str | None, last: str | None, org: str | None) -> str | None:
    parts = [p for p in (first, last) if p]
    if parts:
        return " ".join(parts)
    return org or None


def load_contacts() -> dict[str, str]:
    """handle (phone or email) -> display name, across all AddressBook sources."""
    mapping: dict[str, str] = {}
    dbs = list(AB_ROOT.rglob("AddressBook-v22.abcddb"))
    for src in dbs:
        tmp = Path(tempfile.gettempdir()) / f"ab_{src.parent.name}.db"
        shutil.copy2(src, tmp)
        conn = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            # people
            people = {
                r["Z_PK"]: display_name(r["ZFIRSTNAME"], r["ZLASTNAME"], r["ZORGANIZATION"])
                for r in conn.execute(
                    "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD"
                )
            }
            # phones
            for r in conn.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER"):
                name = people.get(r["ZOWNER"])
                normalized = normalize_phone(r["ZFULLNUMBER"] or "")
                if name and normalized:
                    mapping.setdefault(normalized, name)
            # emails
            for r in conn.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"):
                name = people.get(r["ZOWNER"])
                addr = (r["ZADDRESS"] or "").strip().lower()
                if name and addr:
                    mapping.setdefault(addr, name)
        finally:
            conn.close()
    return mapping


def load_chat_handles() -> set[str]:
    """All handles that appear in chat.db (phone numbers + emails)."""
    tmp = Path(tempfile.gettempdir()) / "bbb_chat_for_handles.db"
    shutil.copy2(CHAT_DB, tmp)
    conn = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
    try:
        rows = conn.execute("SELECT DISTINCT id FROM handle").fetchall()
    finally:
        conn.close()
    return {r[0] for r in rows if r[0]}


def main() -> None:
    contacts = load_contacts()
    handles = load_chat_handles()

    # Match: exact for phone (E.164) and for email (lowercase)
    result: dict[str, str] = {}
    unmatched: list[str] = []
    for h in sorted(handles):
        key = h.lower() if "@" in h else h
        name = contacts.get(key)
        if name:
            result[h] = name
        else:
            unmatched.append(h)

    OUT.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"Wrote {len(result)} matches to {OUT}")
    print(f"Handles with no contact match: {len(unmatched)} (left as-is)")
    if unmatched[:5]:
        print("  e.g.", ", ".join(unmatched[:5]))


if __name__ == "__main__":
    sys.exit(main())
