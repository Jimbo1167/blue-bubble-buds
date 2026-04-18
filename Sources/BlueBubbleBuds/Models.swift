import Foundation

// MARK: - list-chats payload

struct ChatListPayload: Decodable {
    let chats: [ChatSummary]
}

struct ChatSummary: Decodable, Identifiable, Hashable {
    let chatId: Int
    let displayName: String?
    let chatIdentifier: String
    let memberCount: Int
    let messageCount: Int
    let members: [String]

    var id: Int { chatId }
    var label: String { displayName ?? "(no title)" }

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case displayName = "display_name"
        case chatIdentifier = "chat_identifier"
        case memberCount = "member_count"
        case messageCount = "message_count"
        case members
    }
}

// MARK: - analyze payload

struct AnalysisPayload: Decodable {
    let chatId: Int
    let chatName: String
    let memberCount: Int
    let reactionsGiven: [PersonCount]
    let reactionsReceived: [PersonCount]
    let byType: [ByTypeRow]
    let receivedByType: [ByTypeRow]
    let stickerLeaderboard: [PersonCount]
    let stuckStickerLeaderboard: [PersonCount]
    let tapbackStickerLeaderboard: [PersonCount]
    let liveStickerLeaderboard: [PersonCount]
    let emojiLeaderboard: [PersonCount]
    let stickersOnVisualMedia: [PersonCount]
    let reactionRate: [RateRow]
    let pairwise: [PairRow]
    let weeklySeries: WeeklySeries
    let topMessages: [TopMessage]
    let quietFriends: [QuietFriend]

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case chatName = "chat_name"
        case memberCount = "member_count"
        case reactionsGiven = "reactions_given"
        case reactionsReceived = "reactions_received"
        case byType = "by_type"
        case receivedByType = "received_by_type"
        case stickerLeaderboard = "sticker_leaderboard"
        case stuckStickerLeaderboard = "stuck_sticker_leaderboard"
        case tapbackStickerLeaderboard = "tapback_sticker_leaderboard"
        case liveStickerLeaderboard = "live_sticker_leaderboard"
        case emojiLeaderboard = "emoji_leaderboard"
        case stickersOnVisualMedia = "stickers_on_visual_media"
        case reactionRate = "reaction_rate"
        case pairwise
        case weeklySeries = "weekly_series"
        case topMessages = "top_messages"
        case quietFriends = "quiet_friends"
    }
}

struct PersonCount: Decodable, Identifiable, Hashable {
    let person: String
    let count: Int
    var id: String { person }
}

struct ByTypeRow: Decodable, Identifiable, Hashable {
    let person: String
    let love: Int
    let like: Int
    let dislike: Int
    let laugh: Int
    let emphasize: Int
    let question: Int
    let emoji: Int
    let tapbackSticker: Int
    let stuckSticker: Int
    let total: Int
    var id: String { person }

    var sticker: Int { tapbackSticker + stuckSticker }

    enum CodingKeys: String, CodingKey {
        case person, love, like, dislike, laugh, emphasize, question, emoji, total
        case tapbackSticker = "tapback_sticker"
        case stuckSticker = "stuck_sticker"
    }
}

struct RateRow: Decodable, Identifiable, Hashable {
    let person: String
    let reactions: Int
    let eligibleMessages: Int
    let per100: Double
    var id: String { person }

    enum CodingKeys: String, CodingKey {
        case person
        case reactions
        case eligibleMessages = "eligible_messages"
        case per100 = "per_100"
    }
}

struct PairRow: Decodable, Identifiable, Hashable {
    let reactor: String
    let target: String
    let count: Int
    var id: String { "\(reactor)→\(target)" }
}

struct WeeklySeries: Decodable, Hashable {
    let weeks: [String]
    let series: [WeeklyRow]
}

struct WeeklyRow: Decodable, Identifiable, Hashable {
    let person: String
    let counts: [Int]
    var id: String { person }
}

struct TopMessage: Decodable, Identifiable, Hashable {
    let rowid: Int?
    let sender: String
    let date: String
    let datetime: String?
    let guid: String?
    let text: String?
    let reactionCount: Int
    let balloonBundleId: String?
    let hasGhostAttachment: Bool
    let attachments: [TopMessageAttachment]
    var id: String { guid ?? "\(date)-\(sender)-\(reactionCount)" }

    enum CodingKeys: String, CodingKey {
        case rowid, sender, date, datetime, guid, text, attachments
        case reactionCount = "reaction_count"
        case balloonBundleId = "balloon_bundle_id"
        case hasGhostAttachment = "has_ghost_attachment"
    }

    var kindLabel: String {
        if let b = balloonBundleId {
            if b == "com.apple.messages.URLBalloonProvider" { return "URL preview card" }
            if b.contains(".Polls") { return "Poll" }
            if b.contains("PeerPaymentMessages") { return "Apple Cash" }
            if b.contains("DigitalTouch") { return "Digital Touch" }
            if b.contains("Handwriting") { return "Handwritten note" }
            if b.contains("ActivityMessagesApp") { return "Fitness activity" }
            if b.contains("FindMy") { return "Find My" }
            if b.contains("gamepigeon") { return "GamePigeon" }
            if b.contains("SafetyMonitor") { return "Check In" }
            return "Extension message"
        }
        if attachments.contains(where: { $0.isImageLike }) { return "Photo" }
        if attachments.contains(where: { $0.isVideoLike }) { return "Video" }
        if !attachments.isEmpty { return "Attachment" }
        if hasGhostAttachment { return "Attachment (purged)" }
        return "Text"
    }

    var firstImageURL: URL? {
        attachments.first(where: { $0.isImageLike })?.fileURL
    }
}

// MARK: - context payload

struct ContextPayload: Decodable {
    let chatId: Int
    let chatName: String
    let targetRowid: Int
    let messages: [ContextMessage]

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case chatName = "chat_name"
        case targetRowid = "target_rowid"
        case messages
    }
}

struct ContextMessage: Decodable, Identifiable, Hashable {
    let rowid: Int
    let guid: String?
    let sender: String
    let isFromMe: Bool
    let datetime: String
    let date: String
    let isTarget: Bool
    let text: String?
    let balloonBundleId: String?
    let reactionCount: Int
    let attachments: [TopMessageAttachment]
    var id: Int { rowid }

    enum CodingKeys: String, CodingKey {
        case rowid, guid, sender, datetime, date, text, attachments
        case isFromMe = "is_from_me"
        case isTarget = "is_target"
        case balloonBundleId = "balloon_bundle_id"
        case reactionCount = "reaction_count"
    }

    var firstImageURL: URL? {
        attachments.first(where: { $0.isImageLike })?.fileURL
    }
}

struct TopMessageAttachment: Decodable, Hashable {
    let path: String?
    let name: String?
    let mimeType: String?
    let uti: String?
    let isSticker: Bool

    enum CodingKeys: String, CodingKey {
        case path, name, uti
        case mimeType = "mime_type"
        case isSticker = "is_sticker"
    }

    var fileURL: URL? {
        guard let p = path else { return nil }
        return URL(fileURLWithPath: p)
    }

    var isImageLike: Bool {
        if let m = mimeType, m.hasPrefix("image/") { return true }
        let lower = (name ?? path ?? "").lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"].contains { lower.hasSuffix($0) }
    }

    var isVideoLike: Bool {
        if let m = mimeType, m.hasPrefix("video/") { return true }
        let lower = (name ?? path ?? "").lowercased()
        return ["mov", "mp4", "m4v"].contains { lower.hasSuffix($0) }
    }
}

struct QuietFriend: Decodable, Identifiable, Hashable {
    let person: String
    let baselinePerWeek: Double
    let recentPerWeek: Double
    let dropPct: Double
    var id: String { person }

    enum CodingKeys: String, CodingKey {
        case person
        case baselinePerWeek = "baseline_per_week"
        case recentPerWeek = "recent_per_week"
        case dropPct = "drop_pct"
    }
}
