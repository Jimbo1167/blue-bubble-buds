import SwiftUI

struct AnalysisView: View {
    let chat: ChatSummary

    @State private var analysis: AnalysisPayload?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Analyzing \(chat.label)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = error {
                VStack(spacing: 12) {
                    Text("Analysis failed").font(.headline)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
                .padding()
            } else if let a = analysis {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header(a)
                        quietFriendsSection(a)
                        leaderboardSection("Reactions given", rows: a.reactionsGiven)
                        leaderboardSection("Reactions received", rows: a.reactionsReceived)
                        typeBreakdownSection(a)
                        leaderboardSection("🧩 Sticker champs (stuck + tapback combined)", rows: a.stickerLeaderboard)
                        leaderboardSection("📌 Stuck stickers (dragged onto messages)", rows: a.stuckStickerLeaderboard)
                        leaderboardSection("👆 Tapback stickers (reaction menu)", rows: a.tapbackStickerLeaderboard)
                        leaderboardSection("🎞️ Live Photo stickers (animated)", rows: a.liveStickerLeaderboard)
                        leaderboardSection("✨ Custom-emoji champs", rows: a.emojiLeaderboard)
                        leaderboardSection("📷🧩 Stickers on photos/videos", rows: a.stickersOnVisualMedia)
                        rateSection(a)
                        pairwiseSection(a)
                        weeklySection(a)
                        topMessagesSection(a)
                    }
                    .padding(24)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            analysis = try await CLIRunner.analyze(chatId: chat.chatId)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    // MARK: - sections

    private func header(_ a: AnalysisPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(a.chatName).font(.largeTitle).fontWeight(.bold)
            Text("\(a.memberCount) current members · chat_id \(a.chatId)")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func quietFriendsSection(_ a: AnalysisPayload) -> some View {
        if !a.quietFriends.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Quiet Friend Alerts", systemImage: "exclamationmark.bubble")
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(.orange)
                ForEach(a.quietFriends) { q in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(q.person).font(.headline).frame(minWidth: 180, alignment: .leading)
                        Text("baseline \(q.baselinePerWeek, specifier: "%.1f")/wk")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text("recent \(q.recentPerWeek, specifier: "%.2f")/wk")
                            .foregroundStyle(.secondary)
                        Text("↓\(q.dropPct, specifier: "%.0f")%")
                            .foregroundStyle(.orange).fontWeight(.medium)
                        Spacer()
                        Text("check in!").italic().foregroundStyle(.orange)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func leaderboardSection(_ title: String, rows: [PersonCount]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3).fontWeight(.semibold)
            if rows.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                let max = rows.map(\.count).max() ?? 1
                ForEach(rows) { r in
                    HStack(spacing: 8) {
                        Text(r.person).frame(width: 200, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.tint.opacity(0.35))
                                .frame(width: geo.size.width * CGFloat(r.count) / CGFloat(max))
                        }
                        .frame(height: 10)
                        Text("\(r.count)").frame(width: 60, alignment: .trailing).monospacedDigit()
                    }
                }
            }
        }
    }

    private func typeBreakdownSection(_ a: AnalysisPayload) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            legend
            SortableByTypeTable(
                title: "Reactions GIVEN by reaction type",
                subtitle: "Who gives each reaction — click a column to sort.",
                rows: a.byType,
                chatId: a.chatId,
                direction: "given"
            )
            SortableByTypeTable(
                title: "Reactions RECEIVED by reaction type",
                subtitle: "Who gets each reaction on their messages — click 😂 to find the chat's funniest person.",
                rows: a.receivedByType,
                chatId: a.chatId,
                direction: "received"
            )
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Column legend").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow { Text("❤️ love  ·  👍 like  ·  👎 dislike  ·  😂 laugh  ·  ‼️ emphasize  ·  ❓ question").font(.caption2) }
                GridRow { Text("✨ custom-emoji tapback (iOS 18+) — any emoji via the reaction menu; top emojis shown in each cell").font(.caption2).foregroundStyle(.secondary) }
                GridRow { Text("👆 tapback sticker — sticker applied via the reaction menu").font(.caption2).foregroundStyle(.secondary) }
                GridRow { Text("📌 stuck sticker — sticker dragged and dropped directly onto a message").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rateSection(_ a: AnalysisPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reaction rate (per 100 eligible messages)").font(.title3).fontWeight(.semibold)
            ForEach(a.reactionRate) { r in
                HStack {
                    Text(r.person).frame(width: 200, alignment: .leading)
                    Text("\(r.reactions) / \(r.eligibleMessages)")
                        .foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text("\(r.per100, specifier: "%.2f")").fontWeight(.medium).monospacedDigit()
                }
            }
        }
    }

    private func pairwiseSection(_ a: AnalysisPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top reactor → target pairs").font(.title3).fontWeight(.semibold)
            ForEach(a.pairwise.prefix(15), id: \.id) { p in
                HStack {
                    Text(p.reactor).frame(width: 160, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(p.target).frame(width: 160, alignment: .leading)
                    Spacer()
                    Text("\(p.count)").monospacedDigit()
                }
            }
        }
    }

    private func weeklySection(_ a: AnalysisPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last 12 weeks (reactions/week)").font(.title3).fontWeight(.semibold)
            Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 2) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(a.weeklySeries.weeks, id: \.self) { wk in
                        Text(String(wk.suffix(3))).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(a.weeklySeries.series) { s in
                    GridRow {
                        Text(s.person).gridColumnAlignment(.leading).font(.caption)
                        ForEach(Array(s.counts.enumerated()), id: \.offset) { _, n in
                            Text("\(n)").font(.caption).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func topMessagesSection(_ a: AnalysisPayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top 10 most-reacted-to messages")
                .font(.title3).fontWeight(.semibold)
            Text("Click a row to see surrounding conversation.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(a.topMessages) { m in
                TopMessageRow(message: m, chatId: a.chatId)
            }
        }
    }
}

private struct SortableByTypeTable: View {
    let title: String
    let subtitle: String
    let rows: [ByTypeRow]
    let chatId: Int
    let direction: String

    enum SortKey: String, CaseIterable {
        case person, love, like, dislike, laugh, emphasize, question, emoji, tapback, stuck, total

        var label: String {
            switch self {
            case .person:    return "Person"
            case .love:      return "❤️"
            case .like:      return "👍"
            case .dislike:   return "👎"
            case .laugh:     return "😂"
            case .emphasize: return "‼️"
            case .question:  return "❓"
            case .emoji:     return "✨"
            case .tapback:   return "👆"
            case .stuck:     return "📌"
            case .total:     return "Total"
            }
        }

        var help: String {
            switch self {
            case .person:    return "Sort by name"
            case .love:      return "Sort by love reactions"
            case .like:      return "Sort by like reactions"
            case .dislike:   return "Sort by dislike reactions"
            case .laugh:     return "Sort by laugh reactions"
            case .emphasize: return "Sort by emphasize reactions"
            case .question:  return "Sort by question reactions"
            case .emoji:     return "Sort by custom-emoji reactions"
            case .tapback:   return "Sort by tapback stickers"
            case .stuck:     return "Sort by stuck stickers"
            case .total:     return "Sort by total"
            }
        }
    }

    @State private var sortKey: SortKey = .total
    @State private var ascending: Bool = false

    private func valueForSort(_ row: ByTypeRow, _ key: SortKey) -> Int {
        switch key {
        case .person:    return 0  // handled separately
        case .love:      return row.love
        case .like:      return row.like
        case .dislike:   return row.dislike
        case .laugh:     return row.laugh
        case .emphasize: return row.emphasize
        case .question:  return row.question
        case .emoji:     return row.emoji
        case .tapback:   return row.tapbackSticker
        case .stuck:     return row.stuckSticker
        case .total:     return row.total
        }
    }

    private var sorted: [ByTypeRow] {
        if sortKey == .person {
            return rows.sorted { ascending ? $0.person < $1.person : $0.person > $1.person }
        }
        return rows.sorted {
            let a = valueForSort($0, sortKey)
            let b = valueForSort($1, sortKey)
            return ascending ? a < b : a > b
        }
    }

    private func headerCell(for key: SortKey) -> some View {
        let active = sortKey == key
        return Button {
            if sortKey == key {
                ascending.toggle()
            } else {
                sortKey = key
                ascending = false  // numeric columns default descending
                if key == .person { ascending = true }
            }
        } label: {
            HStack(spacing: 2) {
                Text(key.label)
                if active {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.caption)
            .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(key.help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3).fontWeight(.semibold)
            Text(subtitle)
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    headerCell(for: .person).gridColumnAlignment(.leading)
                    headerCell(for: .love)
                    headerCell(for: .like)
                    headerCell(for: .dislike)
                    headerCell(for: .laugh)
                    headerCell(for: .emphasize)
                    headerCell(for: .question)
                    headerCell(for: .emoji)
                    headerCell(for: .tapback)
                    headerCell(for: .stuck)
                    headerCell(for: .total)
                }
                ForEach(sorted) { r in
                    GridRow {
                        Text(r.person).gridColumnAlignment(.leading)
                        cell(r.love,      highlighted: sortKey == .love)
                        cell(r.like,      highlighted: sortKey == .like)
                        cell(r.dislike,   highlighted: sortKey == .dislike)
                        cell(r.laugh,     highlighted: sortKey == .laugh)
                        cell(r.emphasize, highlighted: sortKey == .emphasize)
                        cell(r.question,  highlighted: sortKey == .question)
                        emojiCell(r)
                        stickerCell(r, count: r.tapbackSticker, rtype: 2007,
                                    highlighted: sortKey == .tapback, label: "Tapback stickers")
                        stickerCell(r, count: r.stuckSticker, rtype: 1000,
                                    highlighted: sortKey == .stuck, label: "Stuck stickers")
                        cell(r.total,     highlighted: sortKey == .total, bold: true)
                    }
                }
            }
        }
    }

    private func cell(_ n: Int, highlighted: Bool, bold: Bool = false) -> some View {
        Text("\(n)")
            .monospacedDigit()
            .fontWeight(bold ? .medium : .regular)
            .foregroundStyle(highlighted ? Color.accentColor : .primary)
    }

    private func emojiCell(_ r: ByTypeRow) -> some View {
        let highlighted = sortKey == .emoji
        let tops = r.topCustomEmojis.prefix(3).map(\.emoji).joined()
        return HStack(spacing: 3) {
            if !tops.isEmpty {
                Text(tops).font(.system(size: 10))
            }
            Text("\(r.emoji)")
                .monospacedDigit()
                .foregroundStyle(highlighted ? Color.accentColor : .primary)
        }
        .help(r.topCustomEmojis.map { "\($0.emoji) ×\($0.count)" }.joined(separator: "  "))
    }

    @ViewBuilder
    private func stickerCell(_ row: ByTypeRow, count: Int, rtype: Int, highlighted: Bool, label: String) -> some View {
        StickerPopoverCell(
            chatId: chatId,
            row: row,
            count: count,
            rtype: rtype,
            direction: direction,
            highlighted: highlighted,
            label: label
        )
    }
}

private struct StickerPopoverCell: View {
    let chatId: Int
    let row: ByTypeRow
    let count: Int
    let rtype: Int
    let direction: String
    let highlighted: Bool
    let label: String

    @State private var showPopover = false

    var body: some View {
        Button {
            if count > 0 { showPopover.toggle() }
        } label: {
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(highlighted ? Color.accentColor : .primary)
                .underline(count > 0, color: .accentColor.opacity(0.4))
        }
        .buttonStyle(.plain)
        .help(count == 0 ? "No stickers" : "Click to see top \(label.lowercased())")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            StickerPopoverContent(
                title: label,
                chatId: chatId,
                handleId: row.handleId,
                isFromMe: row.isFromMe,
                rtype: rtype,
                direction: direction
            )
        }
    }
}

private struct StickerPopoverContent: View {
    let title: String
    let chatId: Int
    let handleId: Int
    let isFromMe: Bool
    let rtype: Int
    let direction: String

    @State private var stickers: [StickerCount] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading top stickers…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: 80)
            } else if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            } else if stickers.isEmpty {
                Text("No stickers recorded.").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Top \(stickers.count) most-used")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(stickers) { s in
                        VStack(spacing: 4) {
                            AsyncImage(url: s.fileURL) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().scaledToFit()
                                        .frame(width: 72, height: 72)
                                case .failure:
                                    Image(systemName: "photo.badge.exclamationmark")
                                        .font(.title)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 72, height: 72)
                                default:
                                    ProgressView().frame(width: 72, height: 72)
                                }
                            }
                            Text("×\(s.count)")
                                .font(.caption2).fontWeight(.medium)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 220)
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            stickers = try await CLIRunner.topStickers(
                chatId: chatId,
                handleId: handleId,
                isFromMe: isFromMe,
                rtype: rtype,
                direction: direction
            )
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

private struct TopMessageRow: View {
    let message: TopMessage
    let chatId: Int
    @State private var enlarged = false
    @State private var showingContext = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(message.reactionCount)")
                .font(.title3).fontWeight(.bold)
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(message.sender).fontWeight(.medium)
                    Text(message.datetime ?? message.date).font(.caption).foregroundStyle(.secondary)
                    kindBadge
                    Spacer()
                    actionButtons
                }

                contentBody
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            if message.rowid != nil { showingContext = true }
        }
        .sheet(isPresented: $showingContext) {
            if let rowid = message.rowid {
                ContextView(chatId: chatId, targetRowid: rowid)
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let imgURL = message.firstImageURL {
            Button { enlarged.toggle() } label: {
                AsyncImage(url: imgURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .frame(maxHeight: enlarged ? 360 : 140)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        fallbackLabel("Image unavailable")
                    default:
                        ProgressView().frame(height: 80)
                    }
                }
            }
            .buttonStyle(.plain)
        } else if message.balloonBundleId == "com.apple.messages.URLBalloonProvider" {
            urlCardPlaceholder
        } else if let text = message.text, !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .textSelection(.enabled)
        } else if message.hasGhostAttachment {
            fallbackLabel("Attachment no longer cached (iCloud Photos / cleanup)")
        } else if !message.attachments.isEmpty {
            fallbackLabel(message.attachments.first?.name ?? message.kindLabel)
        } else {
            Text("(no content)").foregroundStyle(.tertiary).italic()
        }
    }

    private var actionButtons: some View {
        Button {
            revealInMessages()
        } label: {
            Label("Find", systemImage: "magnifyingglass")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("""
              Activate Messages.app and search for this message.
              First use: macOS will prompt for Accessibility permission
              (System Settings → Privacy & Security → Accessibility).
              Without Accessibility: search text is copied to clipboard —
              press ⌘F then ⌘V in Messages manually.
              """)
    }

    /// Best search string for finding this specific message in Messages.app.
    private var searchQuery: String {
        if let text = message.text, !text.isEmpty {
            // First 40 printable chars of the body — narrow enough to
            // uniquely identify most top-reacted messages.
            return String(text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message.sender
    }

    private func revealInMessages() {
        let q = searchQuery
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(q, forType: .string)

        // Activate Messages.app, and if Accessibility is granted, run
        // ⌘F → ⌘V → Return to execute the search automatically.
        let script = """
        tell application "Messages" to activate
        delay 0.3
        try
          tell application "System Events"
            tell process "Messages"
              keystroke "f" using command down
              delay 0.15
              keystroke "v" using command down
              delay 0.1
              key code 36
            end tell
          end tell
        end try
        """
        if let s = NSAppleScript(source: script) {
            var err: NSDictionary?
            s.executeAndReturnError(&err)
        }
    }

    private var kindBadge: some View {
        Text(message.kindLabel)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.tint.opacity(0.2), in: Capsule())
            .foregroundStyle(.tint)
    }

    private var urlCardPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.circle.fill").foregroundStyle(.tint)
            Text("URL preview card (open chat in Messages.app to view)").font(.callout)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func fallbackLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private extension Color {
    static let tint = Color.accentColor
}
