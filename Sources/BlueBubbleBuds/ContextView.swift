import SwiftUI

struct ContextView: View {
    let chatId: Int
    let targetRowid: Int

    @Environment(\.dismiss) private var dismiss
    @State private var payload: ContextPayload?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if loading {
                    ProgressView("Loading context…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    VStack(spacing: 10) {
                        Text("Couldn't load context").font(.headline)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if let p = payload {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(p.messages) { m in
                                    ContextMessageBubble(message: m)
                                        .id(m.rowid)
                                }
                            }
                            .padding(20)
                        }
                        .onAppear {
                            withAnimation {
                                proxy.scrollTo(p.targetRowid, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Message context").font(.title3).fontWeight(.semibold)
                Text(payload?.chatName ?? "…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            payload = try await CLIRunner.context(chatId: chatId, rowid: targetRowid)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

private struct ContextMessageBubble: View {
    let message: ContextMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.isFromMe { Spacer(minLength: 40) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !message.isFromMe {
                        Text(message.sender).font(.caption).fontWeight(.medium)
                    }
                    Text(message.datetime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if message.isFromMe {
                        Text("me").font(.caption).fontWeight(.medium)
                    }
                }

                bubbleContent
                    .padding(10)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: message.isFromMe ? .topLeading : .topTrailing) {
                        if message.isTarget {
                            Image(systemName: "star.circle.fill")
                                .foregroundStyle(.orange)
                                .offset(x: message.isFromMe ? -8 : 8, y: -8)
                                .help("Target message")
                        }
                    }

                if message.reactionCount > 0 {
                    Text("\(message.reactionCount) reaction\(message.reactionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !message.isFromMe { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imgURL = message.firstImageURL {
                AsyncImage(url: imgURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .frame(maxWidth: 320, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    default:
                        ProgressView().frame(width: 240, height: 120)
                    }
                }
            }

            if let text = message.text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(message.isTarget ? .primary : .secondary)
            } else if message.balloonBundleId == "com.apple.messages.URLBalloonProvider" {
                Label("URL preview card", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !message.attachments.isEmpty {
                Label(message.attachments.first?.name ?? "Attachment", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if message.firstImageURL == nil {
                Text("(no content)").font(.caption).foregroundStyle(.tertiary).italic()
            }
        }
    }

    private var bubbleColor: Color {
        if message.isTarget {
            return .orange.opacity(0.22)
        }
        return message.isFromMe
            ? Color.accentColor.opacity(0.22)
            : Color.secondary.opacity(0.12)
    }
}
