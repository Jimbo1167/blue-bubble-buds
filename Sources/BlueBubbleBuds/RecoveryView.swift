import SwiftUI

struct RecoveryView: View {
    let chatId: Int
    let chatName: String
    let message: TopMessage

    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var result: RecoveryService.Result?
    @State private var errorMessage: String?
    @State private var trace: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if result == nil && !running {
                explainer
            } else if running {
                progressPane
            } else if let r = result {
                resultPane(r)
            }

            Spacer()

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if result == nil {
                    Button("Start recovery") {
                        Task { await run() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
                } else {
                    Button("Try again") {
                        result = nil
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
    }

    // MARK: - panes

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Recover missing attachments", systemImage: "icloud.and.arrow.down")
                .font(.title3).fontWeight(.semibold)
            Text("Uses Messages.app to trigger iCloud re-downloads — no entitlement bypass needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What will happen")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Blue Bubble Buds activates Messages.app.")
                step(2, "It opens the chat **\(chatName)**.")
                step(3, "It searches for a snippet of the target message so Messages scrolls to it — this materializes the cell, which triggers imagent to fetch any missing attachments from CloudKit.")
                step(4, "We poll chat.db for up to 30 seconds and report how many attachments got recovered.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Target message").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text("\(message.reactionCount)")
                        .font(.title3).fontWeight(.bold)
                        .foregroundStyle(.orange)
                        .frame(width: 30, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(message.sender).fontWeight(.medium)
                            Text(message.datetime ?? message.date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let t = message.text, !t.isEmpty {
                            Text(t).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        } else {
                            Text("(no text — will navigate to chat only, not a specific message)")
                                .font(.caption).italic().foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Text("The first time you run this, macOS will ask to grant Accessibility to Blue Bubble Buds. Without it, we can still activate Messages — you'll just need to do the search manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").font(.callout).foregroundStyle(.secondary).frame(width: 18)
            Text(.init(text)).font(.callout)
        }
    }

    private var progressPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Recovery running — don't click in Messages while this runs.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(trace.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .frame(maxHeight: .infinity)
                .onChange(of: trace.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultPane(_ r: RecoveryService.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if r.accessibilityDenied {
                Label("Automation permission missing", systemImage: "hand.raised.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("macOS blocks third-party apps from controlling other apps unless you approve it. The error 'Not authorized to send Apple events to System Events' means we got denied (or the approval dialog was dismissed).")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Fix:").font(.callout).fontWeight(.medium)
                Text("**1.** Reset the denial below, **OR** open System Settings → Privacy & Security → **Automation** → Blue Bubble Buds → toggle on **System Events** and **Messages**.\n**2.** Retry the recovery — macOS will prompt fresh, click **OK** this time.")
                    .font(.callout)
                HStack {
                    Button("Reset permission prompts") {
                        resetAutomationPermissions()
                    }
                    Button("Open Automation settings") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
            } else if r.recovered > 0 {
                Label("Recovered \(r.recovered) attachment\(r.recovered == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("Before: \(r.purgedBefore) purged · After: \(r.purgedAfter) purged")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(r.timedOut ? "No change detected in 30s" : "Nothing to recover", systemImage: "clock")
                    .font(.headline).foregroundStyle(.orange)
                Text("Messages was driven but chat.db's purged-attachment count didn't drop (before=\(r.purgedBefore), after=\(r.purgedAfter)). See the trace below for what actually happened.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let err = r.appleScriptError {
                Text("AppleScript error: \(err)")
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()

            DisclosureGroup("Execution trace (\(r.trace.count) steps)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(r.trace.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            if let e = errorMessage {
                Divider()
                Text("Error: \(e)")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func resetAutomationPermissions() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.github.jimbo1167.bluebubblebuds"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "AppleEvents", bundleId]
        try? p.run()
        p.waitUntilExit()
    }

    private func run() async {
        running = true
        errorMessage = nil
        result = nil
        trace = []
        do {
            let r = try await RecoveryService.recover(
                chatId: chatId,
                chatDisplayName: chatName,
                messageSnippet: message.text,
                progress: { line in
                    Task { @MainActor in trace.append(line) }
                }
            )
            result = r
        } catch {
            errorMessage = error.localizedDescription
            result = RecoveryService.Result(
                purgedBefore: 0, purgedAfter: 0, recovered: 0,
                accessibilityDenied: false, timedOut: true,
                trace: trace, appleScriptOutput: "", appleScriptError: error.localizedDescription
            )
        }
        running = false
    }
}
