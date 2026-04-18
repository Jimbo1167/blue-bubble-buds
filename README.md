# Blue Bubble Buds

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey.svg)

Local macOS app that analyzes your iMessage group-chat reactions — who cheers, who's gone quiet, who slaps stickers on everything. Headline feature: a **Quiet Friend detector** that flags members whose engagement has dropped sharply from their own baseline, so you know who to check in on.

> Not affiliated with Apple. iMessage, Messages, and related marks are trademarks of Apple Inc. This tool only reads your own local `chat.db` file read-only.

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
- **Full Disk Access** granted to whichever binary reads `chat.db` — your terminal while in dev mode, and the installed `.app` after building (see [Full Disk Access](#full-disk-access) below)

## Quick Start

**Option A — Install as a double-clickable macOS app (recommended):**

```sh
# (Optional, one-time) Set up stable code signing so FDA grants survive rebuilds.
bash scripts/setup-signing.sh

# Generate names.json from your Contacts (optional but much nicer output).
python3 cli/build_names.py

# Build the .app and install it to /Applications.
bash scripts/build-app.sh --install
```

After install, launch from Spotlight (⌘Space → "Blue Bubble Buds"), Launchpad, or `/Applications`. Drag it to your Dock if you want one-click access.

First launch: macOS Gatekeeper may warn — right-click the app → **Open** → confirm. After that, normal double-clicks work.

**Option B — Run from source (dev mode):**

```sh
python3 cli/build_names.py          # optional
swift run                           # launches the app
python3 cli/blue_bubble_buds.py list-chats
python3 cli/blue_bubble_buds.py analyze <chat_id>
python3 cli/blue_bubble_buds.py stats <chat_id>
```

## Full Disk Access

macOS protects `~/Library/Messages/chat.db` behind Full Disk Access (FDA). You need to grant it once to whatever binary is reading the database:

- **Installed app (Option A):** `System Settings → Privacy & Security → Full Disk Access → (+) Blue Bubble Buds.app`
- **Dev mode (Option B):** grant FDA to your terminal application (Terminal, iTerm, Ghostty, etc.)

### Why the one-time signing setup matters

By default, ad-hoc-signed apps get a new code signature every time you rebuild, which causes macOS to drop the FDA grant. `scripts/setup-signing.sh` creates a stable self-signed `Blue Bubble Buds Dev` identity so the Designated Requirement stays constant across rebuilds — grant FDA once and it persists.

If you already have an Apple Development or Developer ID certificate in your keychain, `build-app.sh` will prefer that automatically; you can skip `setup-signing.sh`.

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
- `cli/build_names.py` reads the AddressBook SQLite files under `~/Library/Application Support/AddressBook/` (also read-only, also via a temp copy).

## Maintainer notes

Regenerating the app icon requires Pillow:

```sh
python3 -m pip install --user Pillow
python3 scripts/build-icon.py
iconutil -c icns Resources/AppIcon.iconset
```

End users never need Pillow — the `.icns` is checked in.

## License

[MIT](LICENSE) © James Schindler
