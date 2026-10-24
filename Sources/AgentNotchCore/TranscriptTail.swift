import Foundation

public enum TranscriptRole: Sendable, Equatable { case assistant, user }

/// What one transcript line contributes. A decode failure is `nil` from the parser.
public enum TranscriptLine: Sendable, Equatable {
    case aiTitle(String)
    case message(role: TranscriptRole, branch: String?, activity: Activity?)
    case ignored
}

/// Tolerant JSONL line parser. Reads only `type`, `aiTitle`, `gitBranch`, `isSidechain` and
/// `message.content[].{type,name,input,text}` (F6). Never retains the line.
public enum TranscriptLineParser {
    public static func parse(_ line: Data) -> TranscriptLine? {
        guard let obj = try? JSONSerialization.jsonObject(with: line), let dict = obj as? [String: Any] else { return nil }
        if (dict["isSidechain"] as? Bool) == true { return .ignored }                     // D2: subagents are v2
        guard let type = dict["type"] as? String else { return .ignored }
        switch type {
        case "ai-title":
            guard let title = dict["aiTitle"] as? String else { return .ignored }
            let finished = ActivitySummary.finish(title)
            return finished.isEmpty ? .ignored : .aiTitle(finished)
        case "assistant", "user":
            let role: TranscriptRole = type == "assistant" ? .assistant : .user
            let branch = (dict["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let activity = role == .assistant ? activity(in: dict["message"]) : nil
            return .message(role: role, branch: branch, activity: activity)
        default:
            return .ignored
        }
    }

    /// The last `tool_use` block, or failing that the last non-empty `text` block (D11).
    static func activity(in message: Any?) -> Activity? {
        guard let message = message as? [String: Any], let blocks = message["content"] as? [Any] else { return nil }
        var lastText: Activity?
        for block in blocks.reversed() {
            guard let block = block as? [String: Any], let kind = block["type"] as? String else { continue }
            if kind == "tool_use", let name = block["name"] as? String, !name.isEmpty {
                return ActivitySummary.forToolUse(name: name, input: block["input"] as? [String: Any] ?? [:])
            }
            if kind == "text", lastText == nil, let text = block["text"] as? String {
                lastText = ActivitySummary.forText(text)
            }
        }
        return lastText
    }
}

/// Fields derived from a read. `nil` means "no new value in this read", so the store leaves the
/// field untouched; `unavailable` reflects D24 (20+ decode failures and no success).
public struct TranscriptUpdate: Sendable, Equatable {
    public var aiTitle: String?
    public var branch: String?
    public var activity: Activity?
    public var unavailable: Bool = false
    public init(aiTitle: String? = nil, branch: String? = nil, activity: Activity? = nil, unavailable: Bool = false) {
        self.aiTitle = aiTitle; self.branch = branch; self.activity = activity; self.unavailable = unavailable
    }
}

/// Offset-based tail of one transcript (R7). Not thread-safe: call it from one queue or actor.
public final class TranscriptTail {
    public static let unavailableThreshold = 20

    public let path: URL
    public private(set) var offset: UInt64 = 0
    public private(set) var decodeFailures = 0
    public private(set) var decodeSuccesses = 0
    private let chunkSize: Int
    private let maxBackscan: Int

    public init(path: URL, chunkSize: Int = 256 * 1024, maxBackscan: Int = 4 * 1024 * 1024) {
        self.path = path
        self.chunkSize = max(16, chunkSize)
        self.maxBackscan = max(self.chunkSize, maxBackscan)
    }

    public var unavailable: Bool { decodeFailures >= Self.unavailableThreshold && decodeSuccesses == 0 }

    /// Read backwards in chunks (up to `maxBackscan`) until the latest title, branch and
    /// assistant activity are known. Leaves `offset` at EOF.
    public func attach() throws -> TranscriptUpdate {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        decodeFailures = 0
        decodeSuccesses = 0

        var found = TranscriptUpdate()
        var haveTitle = false, haveBranch = false, haveActivity = false
        var carry: [UInt8] = []
        var end = size
        while end > 0, Int(size - end) < maxBackscan, !(haveTitle && haveBranch && haveActivity) {
            let start = end > UInt64(chunkSize) ? end - UInt64(chunkSize) : 0
            try handle.seek(toOffset: start)
            var bytes = [UInt8](try handle.read(upToCount: Int(end - start)) ?? Data())
            bytes.append(contentsOf: carry)
            var body = bytes[...]
            if start > 0 {
                if let nl = bytes.firstIndex(of: 0x0A) {
                    carry = Array(bytes[..<nl])
                    body = bytes[(nl + 1)...]
                } else {
                    carry = bytes          // the whole chunk is the middle of one line
                    body = []
                }
            } else {
                carry = []
            }
            for line in body.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                switch parseCounting(Data(line)) {
                case .aiTitle(let title):
                    if !haveTitle { found.aiTitle = title; haveTitle = true }
                case .message(let role, let branch, let activity):
                    if !haveBranch, let branch { found.branch = branch; haveBranch = true }
                    if !haveActivity, role == .assistant, let activity { found.activity = activity; haveActivity = true }
                case .ignored, nil:
                    break
                }
                if haveTitle && haveBranch && haveActivity { break }
            }
            end = start
        }
        offset = size
        found.unavailable = unavailable
        return found
    }

    /// Read from `offset` to EOF. Only complete lines advance the offset; a trailing partial
    /// line is re-read next time. A shrunken file means truncation → re-attach.
    public func readNew() throws -> TranscriptUpdate? {
        let bytes: [UInt8]
        do {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if size < offset { bytes = [] } else {
                guard size > offset else { return nil }
                try handle.seek(toOffset: offset)
                bytes = [UInt8](try handle.read(upToCount: Int(size - offset)) ?? Data())
            }
            if size < offset { return try reattachAfterTruncation() }
        }
        guard let lastNewline = bytes.lastIndex(of: 0x0A) else { return nil }
        let complete = bytes[...lastNewline]
        offset += UInt64(complete.count)

        var update = TranscriptUpdate()
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            switch parseCounting(Data(line)) {
            case .aiTitle(let title): update.aiTitle = title
            case .message(_, let branch, let activity):
                if let branch { update.branch = branch }
                if let activity { update.activity = activity }
            case .ignored, nil: break
            }
        }
        update.unavailable = unavailable
        return update
    }

    private func reattachAfterTruncation() throws -> TranscriptUpdate { try attach() }

    private func parseCounting(_ line: Data) -> TranscriptLine? {
        let parsed = TranscriptLineParser.parse(line)
        if parsed == nil { decodeFailures += 1 } else { decodeSuccesses += 1 }
        return parsed
    }
}
