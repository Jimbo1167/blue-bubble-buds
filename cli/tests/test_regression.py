"""Guardrail for the current collect_context shape before it's refactored."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import blue_bubble_buds as bbb


def test_collect_context_shape(db):
    out = bbb.collect_context(db, chat_id=1, target_rowid=104, before=2, after=2)
    assert out["chat_id"] == 1
    assert out["chat_name"] == "Buds"
    assert out["target_rowid"] == 104
    rowids = [m["rowid"] for m in out["messages"]]
    assert rowids == [102, 103, 104, 105, 106]
    target = next(m for m in out["messages"] if m["is_target"])
    assert target["rowid"] == 104
    assert target["text"] == "msg four"
    assert target["sender"] == "alice"   # handle_id=1 -> "alice"


def test_collect_context_me_sender(db):
    out = bbb.collect_context(db, chat_id=1, target_rowid=103, before=0, after=0)
    assert len(out["messages"]) == 1
    assert out["messages"][0]["sender"] == "me"
    assert out["messages"][0]["is_from_me"] is True
