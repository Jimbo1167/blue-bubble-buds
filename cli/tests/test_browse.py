"""Tests for collect_browse."""
import sys
from pathlib import Path
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import blue_bubble_buds as bbb


def _rowids(out):
    return [m["rowid"] for m in out["messages"]]


# ---------- date mode ----------

def test_date_mode_empty_chat(db):
    # chat 2 has no messages
    out = bbb.collect_browse(db, chat_id=2, date="2024-01-01", before=5, after=5)
    assert out["chat_id"] == 2
    assert out["chat_name"] == "Empty"
    assert out["anchor_rowid"] is None
    assert out["resolved_date"] is None
    assert out["messages"] == []


def test_date_mode_anchors_to_nearest_message(db):
    # Pick a date whose apple-ns is closest to rowid 104 (base+300).
    # We can't hand-build a YYYY-MM-DD that matches the synthetic ns values
    # exactly, so instead: call collect_browse with the ISO date for an
    # anchor we know exists. Here we use any valid date — the fixture's
    # messages are all clustered around apple-ns ~1e9, which corresponds
    # to a date in ~2001. So we pick a date far later: the anchor should
    # clamp to the LAST message (rowid 108) in that case.
    out = bbb.collect_browse(db, chat_id=1, date="2030-01-01", before=3, after=3)
    assert out["anchor_rowid"] == 108
    # Window: 3 before + anchor + 0 after (no messages after 108)
    assert _rowids(out) == [105, 106, 107, 108]


def test_date_mode_clamps_before_first(db):
    # A date earlier than any message (our messages sit near year 2001) →
    # anchor is the earliest message (rowid 101).
    out = bbb.collect_browse(db, chat_id=1, date="1990-01-01", before=3, after=3)
    assert out["anchor_rowid"] == 101
    # Window: 0 before + anchor + 3 after
    assert _rowids(out) == [101, 102, 103, 104]


def test_date_mode_returns_resolved_date(db):
    out = bbb.collect_browse(db, chat_id=1, date="2030-01-01", before=0, after=0)
    # resolved_date is the local-tz day of the anchor message, not an echo
    # of the picked date.
    assert out["resolved_date"] is not None
    assert out["resolved_date"] != "2030-01-01"
    # Shape is YYYY-MM-DD.
    assert len(out["resolved_date"]) == 10
    assert out["resolved_date"][4] == "-" and out["resolved_date"][7] == "-"


def test_date_mode_marks_anchor_as_target(db):
    out = bbb.collect_browse(db, chat_id=1, date="2030-01-01", before=2, after=0)
    targets = [m for m in out["messages"] if m["is_target"]]
    assert len(targets) == 1
    assert targets[0]["rowid"] == out["anchor_rowid"]


# ---------- mode validation ----------


def test_no_mode_provided_raises(db):
    with pytest.raises(ValueError, match="exactly one of date, before_rowid, after_rowid"):
        bbb.collect_browse(db, chat_id=1)


def test_multiple_modes_provided_raises(db):
    with pytest.raises(ValueError, match="exactly one of date, before_rowid, after_rowid"):
        bbb.collect_browse(db, chat_id=1, date="2024-01-01", before_rowid=101)


# ---------- before-rowid pagination ----------

def test_before_rowid_returns_older_batch(db):
    out = bbb.collect_browse(db, chat_id=1, before_rowid=106, limit=3)
    assert out["anchor_rowid"] is None
    assert out["resolved_date"] is None
    # Older than 106, max 3 rows, oldest-first
    assert _rowids(out) == [103, 104, 105]


def test_before_rowid_excludes_edge(db):
    out = bbb.collect_browse(db, chat_id=1, before_rowid=106, limit=10)
    assert 106 not in _rowids(out)


def test_before_rowid_from_oldest_is_empty(db):
    out = bbb.collect_browse(db, chat_id=1, before_rowid=101, limit=10)
    assert out["messages"] == []


def test_before_rowid_unknown_rowid_returns_empty(db):
    out = bbb.collect_browse(db, chat_id=1, before_rowid=99999, limit=10)
    assert out["messages"] == []
