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
    let stickerLeaderboard: [PersonCount]
    let emojiLeaderboard: [PersonCount]
    let stickersOnImages: [PersonCount]
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
        case stickerLeaderboard = "sticker_leaderboard"
        case emojiLeaderboard = "emoji_leaderboard"
        case stickersOnImages = "stickers_on_images"
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
    let sticker: Int
    let total: Int
    var id: String { person }
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
    let sender: String
    let date: String
    let text: String?
    let reactionCount: Int
    var id: String { "\(date)-\(sender)-\(reactionCount)" }

    enum CodingKeys: String, CodingKey {
        case sender, date, text
        case reactionCount = "reaction_count"
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
