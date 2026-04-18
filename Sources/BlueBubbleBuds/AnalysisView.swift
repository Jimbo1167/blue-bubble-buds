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
        VStack(alignment: .leading, spacing: 6) {
            Text("Top 10 most-reacted-to messages").font(.title3).fontWeight(.semibold)
            ForEach(a.topMessages) { m in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(m.reactionCount)")
                        .fontWeight(.bold)
                        .frame(width: 32, alignment: .trailing)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(m.sender).fontWeight(.medium)
                            Text(m.date).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(m.text ?? "(attachment/empty)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
