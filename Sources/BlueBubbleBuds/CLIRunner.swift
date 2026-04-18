import Foundation

enum CLIError: Error, LocalizedError {
    case cliNotFound(URL)
    case nonZeroExit(Int32, String)
    case decodeFailed(Error, String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let url):
            return "CLI not found at \(url.path)"
        case .nonZeroExit(let code, let stderr):
            return "CLI exited \(code): \(stderr)"
        case .decodeFailed(let err, let raw):
            return "Decode failed: \(err.localizedDescription)\nRaw:\n\(raw.prefix(500))"
        }
    }
}

struct CLIRunner {
    /// Resolve the path to the bundled CLI. For `swift run` from the package root,
    /// cwd is the package root, so `cli/blue_bubble_buds.py` works.
    static var cliURL: URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd.appendingPathComponent("cli/blue_bubble_buds.py")
    }

    static func run<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
        let cli = cliURL
        guard FileManager.default.fileExists(atPath: cli.path) else {
            throw CLIError.cliNotFound(cli)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", cli.path, "--json"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errText = String(data: errData, encoding: .utf8) ?? "<no stderr>"
            throw CLIError.nonZeroExit(process.terminationStatus, errText)
        }

        do {
            return try JSONDecoder().decode(T.self, from: outData)
        } catch {
            let raw = String(data: outData, encoding: .utf8) ?? "<not utf8>"
            throw CLIError.decodeFailed(error, raw)
        }
    }

    static func listChats(limit: Int = 50) async throws -> [ChatSummary] {
        let payload: ChatListPayload = try await run(
            ChatListPayload.self,
            arguments: ["list-chats", "--limit", String(limit)]
        )
        return payload.chats
    }

    static func analyze(chatId: Int) async throws -> AnalysisPayload {
        try await run(AnalysisPayload.self, arguments: ["analyze", String(chatId)])
    }
}
