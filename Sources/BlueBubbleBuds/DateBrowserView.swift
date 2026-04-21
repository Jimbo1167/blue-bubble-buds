import SwiftUI

struct DateBrowserView: View {
    let chat: ChatSummary

    @Environment(\.dismiss) private var dismiss
    @State private var pickedDate: Date = Date()
    @State private var messages: [ContextMessage] = []
    @State private var anchorRowid: Int?
    @State private var resolvedDate: String?
    @State private var scrollAnchor: Int?
    @State private var loadingInitial = false
    @State private var initialError: String?
    @State private var hasLoadedOnce = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if loadingInitial {
                    ProgressView("Loading messages…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = initialError {
                    errorView(err)
                } else if hasLoadedOnce && messages.isEmpty {
                    emptyView
                } else if !messages.isEmpty {
                    messageList
                } else {
                    promptView
                }
            }
        }
        .frame(minWidth: 640, minHeight: 600)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Jump to date").font(.title3).fontWeight(.semibold)
                Text(chat.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            DatePicker(
                "",
                selection: $pickedDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .onChange(of: pickedDate) { _, _ in
                Task { await loadInitial() }
            }
            if let resolved = resolvedDate,
               let pickedISO = DateBrowserView.iso(from: pickedDate),
               resolved != pickedISO {
                Text("Nearest: \(resolved)")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(messages) { m in
                    MessageBubble(message: m)
                }
            }
            .scrollTargetLayout()
            .padding(20)
        }
        // .top anchor is what makes the prepend-preservation trick in
        // Task 13 work: writing scrollAnchor = savedTop after prepending
        // pins that row at the top of the viewport so new rows grow above
        // without a visible jump.
        .scrollPosition(id: $scrollAnchor, anchor: .top)
    }

    private var promptView: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Pick a date to jump to").font(.title3)
            Text("Use the picker above — we'll anchor to the nearest message.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left").font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No messages in this chat.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ err: String) -> some View {
        VStack(spacing: 10) {
            Text("Couldn't load messages").font(.headline)
            Text(err).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Retry") { Task { await loadInitial() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func loadInitial() async {
        // Reset all state fresh — per spec: picked-date change wipes
        // messages, anchor, resolved date, and both edge exhaustion/error
        // flags (flags land in Task 13).
        loadingInitial = true
        initialError = nil
        messages = []
        anchorRowid = nil
        resolvedDate = nil
        scrollAnchor = nil

        guard let iso = DateBrowserView.iso(from: pickedDate) else {
            initialError = "Couldn't format date"
            loadingInitial = false
            return
        }

        do {
            let payload = try await CLIRunner.browseByDate(
                chatId: chat.chatId, date: iso, before: 25, after: 25
            )
            messages = payload.messages
            anchorRowid = payload.anchorRowid
            resolvedDate = payload.resolvedDate
            scrollAnchor = payload.anchorRowid
        } catch {
            initialError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        loadingInitial = false
        hasLoadedOnce = true
    }

    static func iso(from date: Date) -> String? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
