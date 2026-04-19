import Foundation
import os.log

/// Drives Messages.app to materialize a specific message so imagent's
/// entitled process triggers CloudKit re-downloads of its attachments.
///
/// We never bypass Apple's entitlement checks — we just use AppleScript to
/// point the legitimate Messages client at the right spot.
enum RecoveryService {

    private static let logger = Logger(subsystem: "family.schindler.bluebubblebuds", category: "recovery")

    struct Result {
        let purgedBefore: Int
        let purgedAfter: Int
        let recovered: Int
        let accessibilityDenied: Bool
        let timedOut: Bool
        let trace: [String]         // step-by-step what actually happened
        let appleScriptOutput: String
        let appleScriptError: String?
    }

    enum Strategy {
        case searchForMessage    // ⌘F in Messages — needs Spotlight index to be healthy
        case scrollChat          // sidebar search chat + Page Up scroll — no Spotlight needed
    }

    /// Run the recovery flow. Must be called from a Task.
    static func recover(
        chatId: Int,
        chatDisplayName: String,
        messageSnippet: String?,
        strategy: Strategy = .scrollChat,
        scrollSeconds: Int = 30,
        timeout: TimeInterval = 45,
        progress: @escaping (String) -> Void = { _ in }
    ) async throws -> Result {
        var trace: [String] = []
        func log(_ line: String) {
            trace.append(line)
            logger.log("\(line, privacy: .public)")
            progress(line)
        }

        log("Counting purged attachments in chat \(chatId)…")
        let before = (try? purgedCount(chatId: chatId)) ?? -1
        log("  purgedBefore = \(before)")

        log("Running AppleScript — strategy: \(strategy)")
        let scriptResult: ScriptResult
        switch strategy {
        case .searchForMessage:
            scriptResult = runNavigationScript(chatName: chatDisplayName, snippet: messageSnippet)
        case .scrollChat:
            scriptResult = runScrollScript(chatName: chatDisplayName, seconds: scrollSeconds)
        }
        log("  appleScript exit: \(scriptResult.success ? "ok" : "failed")")
        log("  result: \(scriptResult.output.isEmpty ? "<empty>" : scriptResult.output)")
        if let err = scriptResult.error {
            log("  error: \(err)")
        }

        log("Polling chat.db for transfer_state changes (up to \(Int(timeout))s)…")
        let start = Date()
        var after = before
        var pollCount = 0
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            pollCount += 1
            after = (try? purgedCount(chatId: chatId)) ?? after
            log("  poll #\(pollCount) (\(Int(Date().timeIntervalSince(start)))s): purged=\(after)")
            if after < before { break }
        }
        let timedOut = after >= before

        return Result(
            purgedBefore: before,
            purgedAfter: after,
            recovered: max(0, before - after),
            accessibilityDenied: scriptResult.accessibilityDenied,
            timedOut: timedOut,
            trace: trace,
            appleScriptOutput: scriptResult.output,
            appleScriptError: scriptResult.error
        )
    }

    // MARK: - Private

    /// Return number of attachments in this chat with transfer_state != 5 (not fully downloaded).
    /// We shell out to sqlite3 instead of linking SQLite — one less dependency.
    private static func purgedCount(chatId: Int) throws -> Int {
        let chatDB = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
        let sql = """
        SELECT COUNT(*) FROM attachment a
        WHERE a.ROWID IN (
            SELECT maj.attachment_id
            FROM message_attachment_join maj
            JOIN chat_message_join cmj ON cmj.message_id = maj.message_id
            WHERE cmj.chat_id = \(chatId)
        )
        AND a.transfer_state != 5;
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [chatDB, sql]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(raw) ?? 0
    }

    struct ScriptResult {
        let success: Bool
        let output: String
        let error: String?
        let accessibilityDenied: Bool
    }

    /// Activate Messages, open the target chat via sidebar search, then ⌘F for
    /// the message snippet. Returns rich diagnostics so the UI can show what
    /// actually happened.
    private static func runNavigationScript(chatName: String, snippet: String?) -> ScriptResult {
        let escapedChat = escapeForAppleScript(chatName)
        let snippetLine: String = {
            guard let s = snippet, !s.isEmpty else { return "" }
            let clipped = String(s.prefix(60))
            return """
              delay 0.6
              keystroke "f" using command down
              delay 0.3
              keystroke "\(escapeForAppleScript(clipped))"
              delay 0.3
              key code 36 -- Return → scrolls to match
            """
        }()

        let script = """
        tell application "Messages" to activate
        delay 0.4
        try
          tell application "System Events"
            tell process "Messages"
              keystroke "f" using command down
              delay 0.3
              keystroke "\(escapedChat)"
              delay 0.8
              key code 36 -- Return → selects first match (the chat)
              \(snippetLine)
            end tell
          end tell
          return "navigated"
        on error errMsg number errNum
          return "error:" & errNum & ":" & errMsg
        end try
        """

        guard let apple = NSAppleScript(source: script) else {
            return ScriptResult(success: false, output: "", error: "Could not compile AppleScript", accessibilityDenied: false)
        }
        var errInfo: NSDictionary?
        let descriptor = apple.executeAndReturnError(&errInfo)

        if let err = errInfo {
            let code = err["NSAppleScriptErrorNumber"] as? Int ?? 0
            let msg = err["NSAppleScriptErrorMessage"] as? String ?? "?"
            let accessibility = (code == -1743 || code == -25211 || msg.contains("not allowed assistive access"))
            return ScriptResult(
                success: false,
                output: descriptor.stringValue ?? "",
                error: "\(code): \(msg)",
                accessibilityDenied: accessibility
            )
        }
        let output = descriptor.stringValue ?? ""
        if output.hasPrefix("error:") {
            // parse error number from string form
            let parts = output.dropFirst("error:".count).split(separator: ":", maxSplits: 1)
            let code = parts.first.flatMap { Int($0) } ?? 0
            let msg = parts.count > 1 ? String(parts[1]) : output
            let accessibility = (code == -1743 || code == -25211 || msg.contains("not allowed assistive access"))
            return ScriptResult(success: false, output: output, error: msg, accessibilityDenied: accessibility)
        }
        return ScriptResult(success: true, output: output, error: nil, accessibilityDenied: false)
    }

    /// Select chat by sidebar name, then scroll through it for `seconds`,
    /// pressing Page Up repeatedly to force cell rendering. This is
    /// Spotlight-free — Messages' sidebar chat list comes straight from
    /// chat.db, and scroll-based rendering triggers imagent lazy-fetch for
    /// every cell that materializes.
    private static func runScrollScript(chatName: String, seconds: Int) -> ScriptResult {
        let escaped = escapeForAppleScript(chatName)
        // Use a distinctive searchable fragment of the chat name if possible —
        // the first word avoids collisions with message-content matches.
        let searchTerm = chatName.components(separatedBy: .whitespaces).first.map(escapeForAppleScript) ?? escaped
        let iterations = max(1, min(seconds, 120))  // one page-up per second, ~120 max

        let script = """
        tell application "Messages" to activate
        delay 0.5
        try
          tell application "System Events"
            tell process "Messages"
              -- Step 1: sidebar search for the chat by name (chat list is not
              -- Spotlight-indexed, so this works even when the index is stuck).
              keystroke "f" using command down
              delay 0.4
              keystroke "\(searchTerm)"
              delay 0.8
              key code 36 -- Return → Messages selects the first chat match
              delay 1.2
              -- Step 2: dismiss the search focus so arrow/page keys go to
              -- the transcript. Escape cancels the search bar.
              key code 53 -- Escape
              delay 0.4
              -- Step 3: make sure the transcript area has focus. Click
              -- somewhere neutral isn't reliable via scripting; instead, Tab
              -- or use the Navigate menu. Arrow up will start loading history
              -- once the transcript has focus.
              keystroke (ASCII character 31) -- down arrow, wakes the list
              delay 0.3
              -- Step 4: scroll — Page Up renders progressively older cells.
              repeat \(iterations) times
                key code 116 -- Page Up
                delay 0.7
              end repeat
            end tell
          end tell
          return "scrolled \(iterations) pages"
        on error errMsg number errNum
          return "error:" & errNum & ":" & errMsg
        end try
        """

        guard let apple = NSAppleScript(source: script) else {
            return ScriptResult(success: false, output: "", error: "could not compile", accessibilityDenied: false)
        }
        var errInfo: NSDictionary?
        let descriptor = apple.executeAndReturnError(&errInfo)
        if let err = errInfo {
            let code = err["NSAppleScriptErrorNumber"] as? Int ?? 0
            let msg = err["NSAppleScriptErrorMessage"] as? String ?? "?"
            let access = (code == -1743 || code == -25211 || msg.contains("not allowed assistive"))
            return ScriptResult(success: false, output: "", error: "\(code): \(msg)", accessibilityDenied: access)
        }
        let out = descriptor.stringValue ?? ""
        if out.hasPrefix("error:") {
            let parts = out.dropFirst("error:".count).split(separator: ":", maxSplits: 1)
            let code = parts.first.flatMap { Int($0) } ?? 0
            let msg = parts.count > 1 ? String(parts[1]) : out
            let access = (code == -1743 || code == -25211 || msg.contains("not allowed assistive"))
            return ScriptResult(success: false, output: out, error: msg, accessibilityDenied: access)
        }
        return ScriptResult(success: true, output: out, error: nil, accessibilityDenied: false)
    }


    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
    }
}
