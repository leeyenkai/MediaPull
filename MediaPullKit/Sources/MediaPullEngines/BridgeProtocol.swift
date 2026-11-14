import Foundation
import MediaPullCore

/// Any JSON value, for the open-ended parts of bridge events.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var string: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case let .bool(value): value ? "true" : "false"
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case let .number(value): Int(exactly: value.rounded(.towardZero))
        case let .string(value): Int(value)
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value)
        default: nil
        }
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }
}

public struct BridgeAccount: Sendable, Equatable {
    public var username: String
    public var fullName: String?
    public var userID: String?
    public var isPrivate: Bool
    public var followedByViewer: Bool?
    public var postCount: Int?
    public var avatarURL: URL?
    public var biography: String?
}

public struct BridgeItem: Sendable {
    public var key: String
    public var kind: String
    public var subcategory: String?
    public var url: String
    public var thumbURL: URL?
    public var width: Int?
    public var height: Int?
    public var isDash: Bool
    public var fallbackURL: URL?
    public var headers: [String: String]
    public var meta: [String: JSONValue]
}

public struct BridgeFile: Sendable {
    public var key: String
    public var path: URL
    public var bytes: Int64?
    public var subcategory: String?
    public var meta: [String: JSONValue]

    /// Whether the reported file lies inside `folder`. Engines build paths from site metadata, so
    /// a path is never trusted until this holds (it may contain `..` or pass through a link).
    public func isInside(_ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let target = path.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return target.hasPrefix(prefix) && !path.path.split(separator: "/").contains("..")
    }
}

public enum BridgeEvent: Sendable {
    case hello([String: String])
    case account(BridgeAccount)
    case item(BridgeItem)
    case file(BridgeFile)
    case skip(key: String, reason: String)
    case progress(received: Int64?, total: Int64?, speed: Double?)
    case wait(seconds: Double, reason: String)
    case cursor(subcategory: String, value: String)
    case checkpoint(kind: String, url: URL?, message: String)
    case error(code: String, message: String, key: String?, fatal: Bool)
    case policyViolation(method: String, host: String, path: String, reason: String)
    case log(level: String, message: String)
    case supports(supported: Bool, category: String?, subcategory: String?)
    case done(status: String, errors: [String])
    case unknown(String)

    static func decode(_ line: String) -> BridgeEvent? {
        guard let data = line.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = value["type"]?.string
        else { return nil }
        func string(_ key: String) -> String? { value[key]?.string }
        switch type {
        case "hello":
            var info: [String: String] = [:]
            if case let .object(object) = value {
                for (key, entry) in object { if let text = entry.string { info[key] = text } }
            }
            return .hello(info)
        case "account":
            return .account(BridgeAccount(
                username: string("username") ?? "", fullName: string("full_name"), userID: string("user_id"),
                isPrivate: value["is_private"]?.bool ?? false, followedByViewer: value["followed_by_viewer"]?.bool,
                postCount: value["post_count"]?.int, avatarURL: string("avatar_url").flatMap(URL.init(string:)),
                biography: string("biography")
            ))
        case "item":
            var meta: [String: JSONValue] = [:]
            if case let .object(object) = value["meta"] ?? .null { meta = object }
            var headers: [String: String] = [:]
            if case let .object(object) = value["headers"] ?? .null {
                for (key, entry) in object { if let text = entry.string { headers[key] = text } }
            }
            let video = value["video"]
            return .item(BridgeItem(
                key: string("key") ?? UUID().uuidString, kind: string("kind") ?? "image", subcategory: string("subcategory"),
                url: string("url") ?? "", thumbURL: string("thumb_url").flatMap(URL.init(string:)), width: value["width"]?.int,
                height: value["height"]?.int, isDash: video?["variant"]?.string == "dash",
                fallbackURL: video?["fallback_url"]?.string.flatMap(URL.init(string:)), headers: headers, meta: meta
            ))
        case "file":
            var meta: [String: JSONValue] = [:]
            if case let .object(object) = value["meta"] ?? .null { meta = object }
            guard let path = string("path") else { return nil }
            return .file(BridgeFile(
                key: string("key") ?? "", path: URL(fileURLWithPath: path), bytes: value["bytes"]?.double.map { Int64($0) },
                subcategory: string("subcategory"), meta: meta
            ))
        case "skip":
            return .skip(key: string("key") ?? "", reason: string("reason") ?? "")
        case "progress":
            return .progress(received: value["received"]?.double.map { Int64($0) }, total: value["total"]?.double.map { Int64($0) },
                             speed: value["speed"]?.double)
        case "wait":
            return .wait(seconds: value["seconds"]?.double ?? 0, reason: string("reason") ?? "pacing")
        case "cursor":
            return .cursor(subcategory: string("subcategory") ?? "", value: string("value") ?? "")
        case "checkpoint":
            return .checkpoint(kind: string("kind") ?? "challenge", url: string("url").flatMap(URL.init(string:)),
                               message: string("message") ?? "")
        case "error":
            return .error(code: string("code") ?? "internal", message: string("message") ?? "Unknown error", key: string("key"),
                          fatal: value["fatal"]?.bool ?? false)
        case "policy_violation":
            return .policyViolation(method: string("method") ?? "", host: string("host") ?? "", path: string("path") ?? "",
                                    reason: string("reason") ?? "")
        case "log":
            return .log(level: string("level") ?? "info", message: string("message") ?? "")
        case "supports":
            return .supports(supported: value["supported"]?.bool ?? false, category: string("category"), subcategory: string("subcategory"))
        case "done":
            var errors: [String] = []
            if case let .array(list) = value["errors"] ?? .null { errors = list.compactMap(\.string) }
            return .done(status: string("status") ?? "completed", errors: errors)
        default:
            return .unknown(type)
        }
    }
}

public struct BridgeRequest: Encodable, Sendable {
    public struct Video: Encodable, Sendable {
        public var format: String
        public var formatSort: [String]

        enum CodingKeys: String, CodingKey {
            case format
            case formatSort = "format_sort"
        }

        public init(format: String, formatSort: [String]) {
            self.format = format
            self.formatSort = formatSort
        }
    }

    public struct Pacing: Encodable, Sendable {
        public var requestDelay: [Double]

        enum CodingKeys: String, CodingKey {
            case requestDelay = "request_delay"
        }
    }

    public var v = 1
    public var op: String
    public var url: String?
    public var urls: [String]?
    public var username: String?
    public var include: [String]?
    public var cookies: String?
    public var staging: String?
    public var knownIDs: String?
    public var stopAfterKnown: Int?
    public var dateFrom: String?
    public var dateTo: String?
    public var pacing: Pacing?
    public var video: Video?
    public var cursor: String?
    public var filter: String?
    public var referer: String?
    public var userAgent: String?
    public var key: String?
    public var wheel: String?
    public var target: String?
    public var paths: [String] = []

    public init(op: String) {
        self.op = op
    }

    public mutating func setPacing(_ delay: [Double]) {
        pacing = Pacing(requestDelay: delay)
    }

    enum CodingKeys: String, CodingKey {
        case v, op, url, urls, username, include, cookies, staging, pacing, video, cursor, filter, referer, key, wheel, target, paths
        case knownIDs = "known_ids"
        case stopAfterKnown = "stop_after_known"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case userAgent = "user_agent"
    }
}

public extension BridgeItem {
    /// The engine context for an item, built from the closed metadata set the bridge reports.
    func engineContext(sourceURL: URL?) -> EngineContext {
        EngineContext.from(meta: meta, key: key, subcategory: subcategory, headers: headers, sourceURL: sourceURL)
    }

    func ingestInput(sourceURL: URL?) -> EngineItemInput {
        EngineItemInput(
            context: engineContext(sourceURL: sourceURL), kind: kind == "video" ? .video : .image, engineURL: url, thumbURL: thumbURL,
            width: width, height: height, isDash: isDash, fallbackURL: fallbackURL
        )
    }
}

public extension EngineContext {
    static func from(meta: [String: JSONValue], key: String, subcategory: String?, headers: [String: String] = [:], sourceURL: URL?)
        -> EngineContext
    {
        let category = meta["category"]?.string ?? "site"
        var context = EngineContext(key: key, category: category, subcategory: subcategory ?? meta["subcategory"]?.string ?? "")
        context.username = meta["username"]?.string ?? meta["user_name"]?.string ?? meta["author"]?.string
        context.fullName = meta["fullname"]?.string
        context.shortcode = meta["shortcode"]?.string
        context.postShortcode = meta["post_shortcode"]?.string
        context.postID = meta["post_id"]?.string ?? (category == "instagram" ? nil : meta["id"]?.string)
        context.mediaID = meta["media_id"]?.string
        context.num = meta["num"]?.int
        context.count = meta["count"]?.int
        context.date = (meta["date"]?.string ?? meta["post_date"]?.string).flatMap(DateFormats.parseEngineDate)
        context.description = meta["description"]?.string ?? meta["content"]?.string
        context.title = meta["title"]?.string
        context.postURL = meta["post_url"]?.string.flatMap(URL.init(string:))
        context.highlightTitle = meta["highlight_title"]?.string
        context.productType = meta["type"]?.string
        context.pinned = meta["pinned"]?.bool ?? false
        context.originalWidth = meta["width_original"]?.int
        context.originalHeight = meta["height_original"]?.int
        if let name = meta["filename"]?.string, let ext = meta["extension"]?.string {
            context.fileName = "\(name).\(ext)"
        }
        context.headers = headers
        context.sourceURL = sourceURL
        return context
    }
}
