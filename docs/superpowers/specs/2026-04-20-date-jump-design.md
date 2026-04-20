# Jump to Date — Design

Pick a date for a specific group chat and scroll through the messages sent
around that time. Infinite scroll in both directions.

## Goal

Give the user a way to land anywhere in a group chat's history by date and
drift forward or backward through messages from there. The existing
`ContextView` sheet already does the static "show me ~25 messages around
this one" shape for a clicked top-message; this feature extends that to
arbitrary dates with open-ended scrolling.

## Entry point

A "Jump to date…" button in the `AnalysisView` header, adjacent to the
existing Find-in-Messages button. Clicking it opens a sheet
(`DateBrowserView`) — the same sheet pattern `ContextView` uses today.

## UX

- The sheet's header has a `DatePicker` (`.date` only, default = today) and,
  once a date is chosen, a secondary label "Nearest message: <resolved
  date>" shown only when the resolved date differs from the pick.
- The body is a vertically-scrolling `LazyVStack` of message bubbles
  rendered identically to `ContextView` today.
- On initial load the anchor message is centered and starred (reusing the
  `isTarget` visual from `ContextView`).
- Scrolling near the top edge prepends an older batch. Scrolling near the
  bottom edge appends a newer batch. Small "Loading more…" indicators sit
  above/below while fetches are in flight.
- Re-picking a date resets the feed with a new anchor.
- If the chat has zero messages, the body shows "No messages in this chat."

## Anchor resolution

For a picked date `D`:

- Convert `D` to Apple-ns `target_ns` using the same helper
  `analyze --since` uses today (the inline `iso_to_apple_ns` in
  `main()` — to be promoted to module scope so `collect_browse` can
  reuse it).
- Nearest message in either direction, measured by
  `abs(message.date − target_ns)`.
- Ties broken by lower rowid first.
- If the chat has messages but `D` is before the first or after the last,
  the anchor clamps to the first/last message. The `resolved_date` label
  surfaces this honestly.
- Since the user picks a day-only date and the feed is infinite-scroll,
  the exact hour interpretation of `D` isn't user-visible — the nearest
  message is the nearest message.

## Scroll / pagination model

- Initial window: 25 messages before + 25 after the anchor (anchor
  included once, in between) — matches the visual density of the
  existing `ContextView` (12+12) roughly scaled up for the open-ended
  feed.
- Pagination batch size: 50 per call.
- "Near edge" trigger: when the user scrolls within 10 rows of the top or
  bottom of the current list, fire a fetch.
- Concurrent-fetch guard: one in-flight fetch per edge at a time. Second
  triggers while the first is running are dropped.
- Pagination excludes the edge rowid itself from the returned batch — the
  client already has it — so no de-duping is needed.
- When a fetch returns fewer than `limit` rows, that edge is marked
  exhausted and no further fetches happen on that side.

### Preserving scroll position on prepend

A `LazyVStack` inside a `ScrollView` on macOS does **not** keep the
currently-visible rows pinned when new rows are inserted above — without
explicit handling the content shifts down and the reader gets jerked.
This is the feature's whole texture, so the plan must handle it.

Primary approach (macOS 14+, available): bind the scroll position with
`.scrollPosition(id: $scrollAnchor, anchor: .top)`. Before firing the
prepend fetch, read the current first-visible rowid into
`scrollAnchor`. After `messages` is updated with the prepended batch,
SwiftUI keeps the row with that id pinned to the top of the viewport —
the new rows grow above it and the user sees no jump.

Fallback (if `scrollPosition(id:)` proves flaky on real content):
`ScrollViewReader` + capture the pre-prepend first-visible rowid →
update `messages` → call
`proxy.scrollTo(capturedRowid, anchor: .top)` inside
`withTransaction(Transaction(animation: nil))` so the reposition is
frame-coincident with the data change.

Append (bottom) doesn't need anchoring — new rows grow below the
viewport and the user can scroll into them on their own cadence.

### Same-date tiebreak for pagination

Raw timestamps can collide (messages posted in the same nanosecond —
rare but real in bulk auto-replies or re-added drafts). The anchor-
resolution rule tiebreaks by lower `ROWID`, and pagination must use
the same lexicographic `(date, ROWID)` comparator so tied messages
don't fall into a hole between batches.

- **Before-rowid pagination:**
  `WHERE m.date < edge.date OR (m.date = edge.date AND m.ROWID < edge.ROWID)`
- **After-rowid pagination:**
  `WHERE m.date > edge.date OR (m.date = edge.date AND m.ROWID > edge.ROWID)`
- **Date-mode "before-anchor" half:**
  `WHERE m.date < anchor.date OR (m.date = anchor.date AND m.ROWID < anchor.ROWID)`
- **Date-mode "after-anchor" half:**
  `WHERE m.date > anchor.date OR (m.date = anchor.date AND m.ROWID > anchor.ROWID)`

Orderings are `(date, ROWID)` in the query's natural direction so
ordering and filtering use the same key.

## Backend — Python CLI

### New subcommand: `browse`

Three mutually-exclusive anchor flags; all modes return the same JSON shape.

```
browse <chat_id> --date YYYY-MM-DD [--before N] [--after N]
browse <chat_id> --before-rowid R --limit N
browse <chat_id> --after-rowid R --limit N
```

Argparse enforces exactly one of `--date`, `--before-rowid`, `--after-rowid`.
`--before` and `--after` default to 50 for the date mode; `--limit`
defaults to 50 for pagination modes.

### `collect_browse(conn, chat_id, *, date=None, before_rowid=None, after_rowid=None, before=50, after=50, limit=50)`

Lives in `cli/blue_bubble_buds.py` alongside `collect_context`. The
`enrich()` closure inside `collect_context` is promoted to a module-scope
helper so `collect_browse` can reuse it:

```python
def _enrich_message(conn, row, all_labels, target_rowid=None):
    # same body as today's enrich(), with the name_for logic inlined
    # against the passed all_labels (preserving the "me" / "unknown" /
    # "handle#N" / known-label branches from collect_context's current
    # name_for closure).
    ...
```

`collect_context` calls `_enrich_message(conn, row, all_labels,
target_rowid=target_rowid)`; `collect_browse` calls
`_enrich_message(conn, row, all_labels, target_rowid=anchor_rowid)` (or
`None` for pagination modes, which will simply mark every row
`is_target=False`). The `is_from_me` / `handle_id` → name mapping must
survive the refactor — today's `name_for` closure handles three
branches (is_me → "me"; no handle_id → "unknown"; else
`all_labels.get(handle_id, f"handle#{handle_id}")`) and all three need
to be preserved inline.

**Date mode:**

1. Convert `date` (YYYY-MM-DD) to `target_ns` via the shared
   `iso_to_apple_ns` helper (see Anchor resolution).
2. Query the anchor rowid:
   ```sql
   SELECT m.ROWID, m.date
   FROM message m
   JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
   WHERE cmj.chat_id = ?
     AND m.associated_message_type = 0
   ORDER BY ABS(m.date - ?) ASC, m.ROWID ASC
   LIMIT 1
   ```
3. If no row (empty chat), return `{chat_id, chat_name, anchor_rowid: null,
   resolved_date: null, messages: []}`.
4. Otherwise fetch the "before-anchor" half ordered DESC LIMIT `before`
   (then reversed in Python to oldest-first), the anchor row, and the
   "after-anchor" half ordered ASC LIMIT `after`. Both halves use the
   lexicographic `(date, ROWID)` comparator from the "Same-date tiebreak
   for pagination" section above — see that section for the exact
   `WHERE` / `ORDER BY`.

**Before-rowid mode:**

Fetch up to `limit` rows in the chat strictly older than the edge,
ordered DESC by `(date, ROWID)` LIMIT `limit`, then reversed in Python
so the returned list is oldest-first. The `WHERE` clause is the
lexicographic comparator — see "Same-date tiebreak for pagination"
above. `anchor_rowid` and `resolved_date` are `null`.

**After-rowid mode:**

Fetch up to `limit` rows strictly newer than the edge, ordered ASC by
`(date, ROWID)` LIMIT `limit`. Same tiebreak source as above.
`anchor_rowid` and `resolved_date` are `null`.

All modes filter `associated_message_type = 0` (same rule
`collect_context` uses) so tapbacks and stickers don't clutter the feed.

### Return shape

```json
{
  "chat_id": 42,
  "chat_name": "Buds",
  "anchor_rowid": 1234,
  "resolved_date": "2024-04-12",
  "messages": [ /* same shape as ContextPayload.messages */ ]
}
```

- `anchor_rowid` and `resolved_date` are `null` in the two pagination
  modes (`--before-rowid`, `--after-rowid`).
- `resolved_date` is the local-timezone **day** of the anchor message
  (the message actually found), formatted `YYYY-MM-DD`. It is NOT an
  echo of the picked date — its whole purpose is to show when the
  two differ.
- `messages[]` is always oldest-first in every mode.

## Swift client

### New models (`Models.swift`)

```swift
struct BrowsePayload: Decodable {
    let chatId: Int
    let chatName: String
    let anchorRowid: Int?
    let resolvedDate: String?
    let messages: [ContextMessage]
    // CodingKeys: snake_case
}
```

Reuses the existing `ContextMessage` type verbatim.

### `CLIRunner` additions

```swift
static func browseByDate(chatId: Int, date: String, before: Int = 50,
                         after: Int = 50) async throws -> BrowsePayload
static func browsePage(chatId: Int, edgeRowid: Int,
                       direction: BrowseDirection,
                       limit: Int = 50) async throws -> BrowsePayload
```

`BrowseDirection` is a tiny enum: `.before`, `.after`.

### Shared bubble view (small refactor)

The bubble rendering currently lives as `private struct ContextMessageBubble`
in `ContextView.swift:76-165`. Extract it into a file-level `MessageBubble`
view (new file `Sources/BlueBubbleBuds/MessageBubble.swift`) so both
`ContextView` and `DateBrowserView` can use it. This is targeted — no
unrelated refactoring — and justified because the new view needs identical
rendering and duplicating 90 lines of bubble code would rot quickly.

### `DateBrowserView`

New file `Sources/BlueBubbleBuds/DateBrowserView.swift`. State:

```swift
@State private var pickedDate: Date = Date()
@State private var messages: [ContextMessage] = []
@State private var anchorRowid: Int?
@State private var resolvedDate: String?
@State private var scrollAnchor: Int?     // bound by .scrollPosition(id:)
@State private var loadingInitial = false
@State private var loadingTop = false
@State private var loadingBottom = false
@State private var topExhausted = false
@State private var bottomExhausted = false
@State private var topFetchError: String?
@State private var bottomFetchError: String?
@State private var initialError: String?
```

Behaviour:

- **Submit date / re-pick:** Reset all of `messages = []`,
  `anchorRowid = nil`, `resolvedDate = nil`, `topExhausted = false`,
  `bottomExhausted = false`, `topFetchError = nil`,
  `bottomFetchError = nil`, `initialError = nil`. Set
  `loadingInitial = true`, call `browseByDate`, populate `messages` +
  anchor. After data loads, set `scrollAnchor = anchorRowid` so the
  scroll lands on the anchor row.
- **Prepend:** when the first rendered bubble's `.onAppear` fires and
  `!topExhausted && !loadingTop && topFetchError == nil`:
  1. Capture `let savedTop = messages.first!.rowid`.
  2. Set `loadingTop = true`.
  3. Call `browsePage(.before, edgeRowid: savedTop)`.
  4. Prepend the result. If result count `< 50`, set
     `topExhausted = true`.
  5. Keep `scrollAnchor = savedTop` (no change — `.scrollPosition(id:)`
     keeps that row pinned to `.top`, so the new rows grow above
     without visual jump).
  6. Clear `loadingTop`.
- **Append:** symmetric for `messages.last` and `bottomExhausted`. No
  scroll-anchor manipulation needed for append.
- The near-edge trigger uses `.onAppear` on the first/last rendered
  bubble, which is the standard SwiftUI idiom for `LazyVStack`-based
  infinite scroll and doesn't require GeometryReader.

### Error handling in the sheet

Three separate error surfaces so a mid-scroll failure doesn't nuke 300
already-loaded messages:

- `initialError` — the first `browseByDate` call failed. Full-sheet
  error view with a Retry button, as `ContextView` does today.
- `topFetchError` / `bottomFetchError` — a pagination call failed.
  Render an inline "Couldn't load older messages. Tap to retry." (or
  "newer") strip at the relevant edge of the message list. Tapping
  clears the error flag and triggers a new fetch. `messages` stays
  intact.

### `AnalysisView` change

Add a "Jump to date…" button to the header area next to Find-in-Messages.
Presents `DateBrowserView(chat:)` as a `.sheet`. No changes to existing
analysis rendering.

## Error handling (summary)

- CLI non-zero exit or decode error bubbles up via the existing
  `CLIError` machinery.
- Initial `browseByDate` failure → full-sheet error + Retry (identical
  to today's `ContextView`).
- Mid-scroll `browsePage` failure → inline edge retry strip, messages
  preserved. See "Error handling in the sheet" above.
- Network not applicable (all local).
- Malformed date in the picker is impossible (`DatePicker` guarantees
  validity).

## Testing

No Swift unit tests exist in the project today, so new tests are Python-side.

**Python tests** (`cli/tests/test_browse.py`, new file; project has no
existing tests — adding a minimal pytest setup is in-scope since the
feature needs it):

- Fixture: tiny in-memory SQLite with `message`, `chat`, `chat_message_join`
  tables and ~20 known messages across two chats.
- `collect_browse(date)` with date exactly on a message → that message is
  anchor; window is symmetric.
- `collect_browse(date)` with date between two messages → nearest one is
  anchor; tiebreak at exact midpoint picks lower rowid.
- `collect_browse(date)` and pagination: when two messages share the
  same `date` nanosecond, the lexicographic `(date, ROWID)` comparator
  partitions them correctly across batches — no row appears in both
  sides of the boundary, and no tied row is silently dropped.
- `collect_browse(date)` with date before the first message → anchor is
  first message.
- `collect_browse(date)` with date after the last → anchor is last.
- `collect_browse(date)` on an empty chat → `anchor_rowid` is null,
  `messages` is empty.
- `collect_browse(before_rowid=R, limit=5)` → returns 5 older messages,
  none with `rowid == R`, ordered oldest-first.
- `collect_browse(after_rowid=R, limit=5)` → 5 newer, none equal to R,
  ordered oldest-first (same as `messages[]` invariant elsewhere).
- `collect_browse(before_rowid=first_rowid)` → empty list (exhausted).
- `collect_browse(after_rowid=last_rowid)` → empty list (exhausted).
- `collect_browse` with `associated_message_type != 0` rows interleaved →
  those rows are excluded.

**Manual smoke** on a real chat:

1. Open sheet, pick a date in the middle of the chat's history — anchor
   is visible and starred, 50 messages on each side render.
2. Scroll up fast — older batch loads, no dupes at the seam.
3. Scroll down fast — newer batch loads, no dupes at the seam.
4. Keep scrolling up until exhausted — top stops loading silently.
5. Pick a new date — feed resets, old state discarded.
6. Pick a date before chat started — anchor is first message,
   `resolved_date` label appears.
7. Pick today on a chat inactive for years — anchor is last message,
   `resolved_date` label appears.

## Out of scope

- Remembering last-picked date across sessions.
- Date-range windows (pick start + end, show everything between).
- Search within the browse sheet.
- Keyboard shortcuts to jump the anchor by ±1 day.
- Jumping to date from other entry points (e.g. a global search bar).

All of these are additive and can be built later without touching the
`browse` CLI shape.
