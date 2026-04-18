# Blue Bubble Buds

Local macOS app that analyzes your iMessage group-chat reactions — who cheers, who's gone quiet, who slaps stickers on everything. Headline feature: a **Quiet Friend detector** that flags members whose engagement has dropped sharply from their own baseline, so you know who to check in on.

**Graduated from [The Crucible](https://github.com/Jimbo1167/the-crucible) seed [blue-bubble-buds](https://github.com/Jimbo1167/the-crucible/tree/main/seeds/blue-bubble-buds) on 2026-04-18.**

## Status

Phase A (personal-use): in progress. SwiftUI app shells out to a Python CLI.

## Architecture

```
┌─────────────────────┐       ┌──────────────────────┐
│   SwiftUI app       │─shell→│  cli/blue_bubble_buds │
│   (macOS 14+)       │ JSON  │   .py (Python 3.12+)  │
└─────────────────────┘       └──────────┬────────────┘
                                         │ read-only
                                         ▼
                       ~/Library/Messages/chat.db (TCC-protected)
```

Phase B will rewrite the CLI in Swift and bundle it inside the signed `.app` to avoid subprocess Full Disk Access edge cases. For Phase A we run from source.

## Prerequisites

- macOS 14+ (Sonoma or later)
- Python 3.12+
- Swift 5.9+ (ships with Xcode 15+ or Command Line Tools)
- **Full Disk Access** granted to your terminal app:
  `System Settings → Privacy & Security → Full Disk Access → (+) your terminal`

## Quick Start

```sh
# 1. Generate names.json from your macOS Contacts (optional but recommended)
python3 cli/build_names.py

# 2. Explore in the CLI
python3 cli/blue_bubble_buds.py list-chats
python3 cli/blue_bubble_buds.py analyze <chat_id>
python3 cli/blue_bubble_buds.py stats <chat_id>

# 3. Launch the SwiftUI app
swift run
```

## CLI

| Command | Purpose |
| --- | --- |
| `list-chats [--limit N]` | Top group chats ranked by message count |
| `analyze <chat_id>` | Full 8-section reaction report |
| `stats <chat_id>` | Validation totals — date range, message counts, churn, orphans |

Add `--json` to any command to emit machine-readable JSON. This is the contract the SwiftUI app consumes.

## The 8 Analytics

1. Reactions given per person
2. Reactions received per person
3. Breakdown by reaction type (love / like / dislike / laugh / emphasize / question / iOS 18+ custom emoji / sticker)
4. Reaction rate (per 100 eligible messages, accounts for when each person joined the chat)
5. Pairwise affinity (who reacts to whom most)
6. Weekly time series (last 12 weeks per person)
7. Top 10 most-reacted-to messages of all time
8. **Quiet Friend detector** — recent 4-week avg vs. prior 26-week median, flags >50% drops

Plus dedicated leaderboards for sticker reactions, custom-emoji reactions, and stickers-on-images specifically.

## Privacy

- All analysis happens locally — nothing leaves your machine.
- `cli/names.json` is generated from your Contacts and is **gitignored**.
- The app opens `chat.db` read-only via a temp-file copy (no WAL lock risk).
