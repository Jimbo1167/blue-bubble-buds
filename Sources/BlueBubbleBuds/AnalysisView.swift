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
        VStack(alignment: .leading, spacing: 6) {
            Text("By reaction type").font(.title3).fontWeight(.semibold)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Person").gridColumnAlignment(.leading)
                    Text("❤️"); Text("👍"); Text("👎"); Text("😂")
                    Text("‼️"); Text("❓"); Text("✨"); Text("👆"); Text("📌"); Text("Total")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(a.byType) { r in
                    GridRow {
                        Text(r.person).gridColumnAlignment(.leading)
                        Text("\(r.love)").monospacedDigit()
                        Text("\(r.like)").monospacedDigit()
                        Text("\(r.dislike)").monospacedDigit()
                        Text("\(r.laugh)").monospacedDigit()
                        Text("\(r.emphasize)").monospacedDigit()
                        Text("\(r.question)").monospacedDigit()
                        Text("\(r.emoji)").monospacedDigit()
                        Text("\(r.tapbackSticker)").monospacedDigit()
                        Text("\(r.stuckSticker)").monospacedDigit()
                        Text("\(r.total)").fontWeight(.medium).monospacedDigit()
                    }
                }
            }
        }
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
            Text("Top 10 most-reacted-to messages").font(.title3).fontWeight(.semibold)
            ForEach(a.topMessages) { m in
                TopMessageRow(message: m)
            }
        }
    }
}

private struct TopMessageRow: View {
    let message: TopMessage
    @State private var enlarged = false

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
