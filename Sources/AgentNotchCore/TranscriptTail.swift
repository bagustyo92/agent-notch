import Foundation

public enum TranscriptRole: Sendable, Equatable { case assistant, user }

/// Which transcript JSONL schema a tail parses.
public enum TranscriptFormat: Sendable, Equatable { case claude, antigravity }

/// A `Bash` call with `run_in_background: true` (D41, F22). The activity comes from
/// `ActivitySummary.forToolUse`, which never reads `command`.
public struct BackgroundStart: Sendable, Equatable {
    public var toolUseId: String
    public var activity: Activity
    /// The line's `timestamp`; nil when it has none, and the store uses the time of the read.
    public var startedAt: Date?

    public init(toolUseId: String, activity: Activity, startedAt: Date? = nil) {
        self.toolUseId = toolUseId; self.activity = activity; self.startedAt = startedAt
    }
}

/// The acknowledging `tool_result` of a background `Bash` call, `Command running in background with
/// ID: <taskId>. …`: its task id is the one `TaskStop` names (F25). The rest of the text is never read.
public struct BackgroundAck: Sendable, Equatable {
    public var toolUseId: String
    public var taskId: String

    public init(toolUseId: String, taskId: String) { self.toolUseId = toolUseId; self.taskId = taskId }
}

/// The per-line facts beyond the activity: phase, model, effort, the `Agent` calls a line starts,
/// its context size, the files it edits and its background-task records (D29, D30, D33, D38, D39, D41).
public struct MessageDetails: Sendable, Equatable {
    public var phase: Phase?
    public var model: String?
    public var effort: String?
    public var spawnedToolUseIds: [String] = []
    /// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the reply (D38).
    public var contextTokens: Int?
    /// Hashes of the paths that `Edit`, `Write`, `MultiEdit` and `NotebookEdit` calls name (D39).
    /// The paths themselves are never kept.
    public var editedPathHashes: [Int] = []
    /// Background Bash calls this line starts (D41).
    public var backgroundStarts: [BackgroundStart] = []
    /// `<tool-use-id>` of each `<task-notification>` the line carries: any status closes a task.
    public var closedToolUseIds: [String] = []
    /// `tool_use_id` of each `tool_result` with `is_error: true`: a launch that failed or was denied.
    public var erroredToolUseIds: [String] = []
    /// Background launches this line acknowledges, with the task id `TaskStop` uses (F25).
    public var backgroundAcks: [BackgroundAck] = []
    /// `input.task_id` of each `TaskStop` call: no notification follows a stop (F25).
    public var stoppedTaskIds: [String] = []
    public init(
        phase: Phase? = nil, model: String? = nil, effort: String? = nil, spawnedToolUseIds: [String] = [],
        contextTokens: Int? = nil, editedPathHashes: [Int] = [], backgroundStarts: [BackgroundStart] = [],
        closedToolUseIds: [String] = [], erroredToolUseIds: [String] = [], backgroundAcks: [BackgroundAck] = [],
        stoppedTaskIds: [String] = []
    ) {
        self.phase = phase; self.model = model; self.effort = effort; self.spawnedToolUseIds = spawnedToolUseIds
        self.contextTokens = contextTokens; self.editedPathHashes = editedPathHashes
        self.backgroundStarts = backgroundStarts; self.closedToolUseIds = closedToolUseIds
        self.erroredToolUseIds = erroredToolUseIds; self.backgroundAcks = backgroundAcks; self.stoppedTaskIds = stoppedTaskIds
    }
}

/// What one transcript line contributes. A decode failure is `nil` from the parser.
public enum TranscriptLine: Sendable, Equatable {
    case aiTitle(String)
    case message(role: TranscriptRole, branch: String?, activity: Activity?, details: MessageDetails = MessageDetails())
    /// A `queue-operation` or `attachment` line carrying task notifications (F23). It closes
    /// background tasks and touches neither phase nor activity.
    case taskRecords(closed: [String])
    case ignored
}

/// Tolerant JSONL line parser. Reads only `type`, `aiTitle`, `gitBranch`, `isSidechain`, `effort`,
/// `timestamp`, `content` (of a `queue-operation` line, whatever its `operation`), `attachment.prompt`,
/// `message.{model,content[].{type,id,name,input,text,tool_use_id,is_error}}` and the three input
/// counters of `message.usage` (F6, F19, F22, F23). Of a task notification it reads `tool-use-id` and
/// `status` only; of a `tool_result`'s `content`, only the task id after a launch acknowledgement's
/// lead-in (F25). Never retains the line.
public enum TranscriptLineParser {
    /// `includeSidechain` is for subagent transcripts, whose every line is a sidechain (D33).
    public static func parse(_ line: Data, includeSidechain: Bool = false, format: TranscriptFormat = .claude) -> TranscriptLine? {
        guard let obj = try? JSONSerialization.jsonObject(with: line), let dict = obj as? [String: Any] else { return nil }
        if format == .antigravity { return parseAntigravity(dict) }
        if !includeSidechain, (dict["isSidechain"] as? Bool) == true { return .ignored }   // D2: the main row ignores them
        guard let type = dict["type"] as? String else { return .ignored }
        switch type {
        case "ai-title":
            guard let title = dict["aiTitle"] as? String else { return .ignored }
            let finished = ActivitySummary.finish(title)
            return finished.isEmpty ? .ignored : .aiTitle(finished)
        case "assistant", "user":
            let role: TranscriptRole = type == "assistant" ? .assistant : .user
            let branch = (dict["gitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var details = MessageDetails(effort: token(dict["effort"]))
            let message = dict["message"] as? [String: Any]
            guard role == .assistant else {
                // A prompt or a tool result: the model has the turn and has not answered yet.
                details.phase = .thinking
                details.closedToolUseIds = notificationIds(inContent: message?["content"])
                details.erroredToolUseIds = erroredToolUseIds(in: message?["content"])
                details.backgroundAcks = backgroundAcks(in: message?["content"])
                return .message(role: role, branch: branch, activity: nil, details: details)
            }
            details.phase = phase(in: message)
            details.model = token(message?["model"])
            details.spawnedToolUseIds = spawnedToolUseIds(in: message)
            details.contextTokens = contextTokens(in: message)
            details.editedPathHashes = editedPathHashes(in: message)
            details.backgroundStarts = backgroundStarts(in: message, timestamp: dict["timestamp"])
            details.stoppedTaskIds = stoppedTaskIds(in: message)
            return .message(role: role, branch: branch, activity: activity(in: message), details: details)
        case "queue-operation":
            let closed = notificationIds(in: dict["content"] as? String)
            return closed.isEmpty ? .ignored : .taskRecords(closed: closed)
        case "attachment":
            let closed = notificationIds(in: (dict["attachment"] as? [String: Any])?["prompt"] as? String)
            return closed.isEmpty ? .ignored : .taskRecords(closed: closed)
        default:
            return .ignored
        }
    }

    /// `Bash` calls with `run_in_background: true` (F22). Their activity masks the description and
    /// never reads `command` (D11).
    static func backgroundStarts(in message: [String: Any]?, timestamp: Any?) -> [BackgroundStart] {
        guard let blocks = message?["content"] as? [Any] else { return [] }
        return blocks.compactMap { block in
            guard let block = block as? [String: Any], block["type"] as? String == "tool_use", block["name"] as? String == "Bash",
                  let input = block["input"] as? [String: Any], (input["run_in_background"] as? Bool) == true,
                  let id = token(block["id"]) else { return nil }
            return BackgroundStart(toolUseId: id, activity: ActivitySummary.forToolUse(name: "Bash", input: input), startedAt: date(timestamp))
        }
    }

    /// Notifications in a user line's content: a string, or its `text` blocks (F22).
    static func notificationIds(inContent content: Any?) -> [String] {
        if let text = content as? String { return notificationIds(in: text) }
        guard let blocks = content as? [Any] else { return [] }
        return blocks.flatMap { block -> [String] in
            guard let block = block as? [String: Any], block["type"] as? String == "text" else { return [] }
            return notificationIds(in: block["text"] as? String)
        }
    }

    /// The `<tool-use-id>` of each `<task-notification>` in `text` that also has a `<status>`. Both
    /// must pass `token`. `summary`, `output-file` and `task-id` are never read (R4).
    static func notificationIds(in text: String?) -> [String] {
        guard let text, text.contains("<task-notification>") else { return [] }
        return text.components(separatedBy: "<task-notification>").dropFirst().compactMap { block in
            let body = block.range(of: "</task-notification>").map { block[..<$0.lowerBound] } ?? block[...]
            guard let id = token(tag("tool-use-id", in: body)), token(tag("status", in: body)) != nil else { return nil }
            return id
        }
    }

    private static func tag(_ name: String, in text: Substring) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func erroredToolUseIds(in content: Any?) -> [String] {
        guard let blocks = content as? [Any] else { return [] }
        return blocks.compactMap { block in
            guard let block = block as? [String: Any], block["type"] as? String == "tool_result",
                  (block["is_error"] as? Bool) == true else { return nil }
            return token(block["tool_use_id"])
        }
    }

    /// How Claude Code acknowledges a background launch (F22, F25).
    static let ackLeadIn = "Command running in background with ID: "
    /// The tool that stops a background task by the acknowledgement's id, with no notification (F25).
    static let stopToolName = "TaskStop"

    /// Launch acknowledgements: a `tool_result` whose text (a string, or its first `text` block)
    /// starts with `ackLeadIn`. Only the id up to the next `.` or space is read, through `token`;
    /// the output path after it never is (R4).
    static func backgroundAcks(in content: Any?) -> [BackgroundAck] {
        guard let blocks = content as? [Any] else { return [] }
        return blocks.compactMap { block in
            guard let block = block as? [String: Any], block["type"] as? String == "tool_result",
                  let toolUseId = token(block["tool_use_id"]), let text = resultText(block["content"]),
                  text.hasPrefix(ackLeadIn) else { return nil }
            // One character past the longest token, so an overlong id fails `token` without a long scan.
            let id = text.dropFirst(ackLeadIn.count).prefix(tokenMaxLength + 1).prefix { $0 != "." && !$0.isWhitespace }
            return token(String(id)).map { BackgroundAck(toolUseId: toolUseId, taskId: $0) }
        }
    }

    private static func resultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        return (content as? [Any])?.lazy.compactMap { block -> String? in
            guard let block = block as? [String: Any], block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.first
    }

    /// `input.task_id` of each `TaskStop` call, through `token` (F25).
    static func stoppedTaskIds(in message: [String: Any]?) -> [String] {
        guard let blocks = message?["content"] as? [Any] else { return [] }
        return blocks.compactMap { block in
            guard let block = block as? [String: Any], block["type"] as? String == "tool_use",
                  block["name"] as? String == stopToolName else { return nil }
            return token((block["input"] as? [String: Any])?["task_id"])
        }
    }

    /// ISO-8601, with or without fractional seconds. Anything else is nil.
    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String, !s.isEmpty, s.count <= 40 else { return nil }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle())
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

    /// The phase of the line's last block: the block Claude Code wrote most recently.
    static func phase(in message: [String: Any]?) -> Phase? {
        guard let blocks = message?["content"] as? [Any] else { return nil }
        for block in blocks.reversed() {
            switch (block as? [String: Any])?["type"] as? String {
            case "tool_use": return .tool
            case "text": return .writing
            case "thinking", "redacted_thinking": return .thinking
            default: continue
            }
        }
        return nil
    }

    static func spawnedToolUseIds(in message: [String: Any]?) -> [String] {
        guard let blocks = message?["content"] as? [Any] else { return [] }
        return blocks.compactMap { block in
            guard let block = block as? [String: Any], block["type"] as? String == "tool_use",
                  let name = block["name"] as? String, ActivitySummary.describedTools.contains(name) else { return nil }
            return token(block["id"])
        }
    }

    /// The prompt size Claude Code's status line reports (F19). Zero means a `<synthetic>`
    /// placeholder, not an empty context, so it is dropped.
    static func contextTokens(in message: [String: Any]?) -> Int? {
        guard let usage = message?["usage"] as? [String: Any] else { return nil }
        let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        let total = keys.reduce(0) { $0 + ContextWindow.clamp((usage[$1] as? Int) ?? 0) }   // R8
        return total > 0 ? total : nil
    }

    static let editTools: [String: String] = [
        "Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path",
    ]

    static func editedPathHashes(in message: [String: Any]?) -> [Int] {
        guard let blocks = message?["content"] as? [Any] else { return [] }
        return blocks.compactMap { block in
            guard let block = block as? [String: Any], block["type"] as? String == "tool_use",
                  let name = block["name"] as? String, let key = editTools[name],
                  let path = (block["input"] as? [String: Any])?[key] as? String, !path.isEmpty else { return nil }
            return path.hashValue
        }
    }

    static let tokenMaxLength = 64

    /// Short machine tokens only (model ids, effort levels, tool_use ids). Anything else, including
    /// `<synthetic>` placeholders, is dropped rather than shown.
    static func token(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty, s.count <= tokenMaxLength,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.[]".contains($0)) }) else { return nil }
        return s
    }

    // MARK: - Antigravity Transcript Parsing

    static let antigravityEditTools: Set<String> = [
        "edit_file", "write_file", "write_to_file", "replace_file_content", "multi_replace_file_content",
    ]

    private static let geminiEffortSuffixes = ["xhigh", "high", "medium", "low", "max"]

    /// Splits a Gemini model+effort token such as `gemini-4-neon-xhigh` → `("gemini-4-neon", "xhigh")`.
    /// Non-Gemini or suffixless models return `(model, nil)`.
    static func splitModelEffort(_ any: Any?) -> (model: String?, effort: String?) {
        guard let raw = token(any) else { return (nil, nil) }
        let lower = raw.lowercased()
        guard lower.hasPrefix("gemini-") else { return (raw, nil) }
        for effort in geminiEffortSuffixes {
            let suffix = "-\(effort)"
            if lower.hasSuffix(suffix), raw.count > suffix.count {
                let model = String(raw.dropLast(suffix.count))
                return (model, effort)
            }
        }
        return (raw, nil)
    }

    /// Parses one Antigravity `transcript.jsonl` line (`USER_INPUT`, `PLANNER_RESPONSE`, `GENERIC`, `SYSTEM_MESSAGE`).
    static func parseAntigravity(_ dict: [String: Any]) -> TranscriptLine {
        guard let type = dict["type"] as? String else { return .ignored }
        switch type {
        case "USER_INPUT":
            return .message(role: .user, branch: nil, activity: nil, details: MessageDetails(phase: .thinking))
        case "PLANNER_RESPONSE":
            let (model, effort) = splitModelEffort(dict["model"])
            let inputTokens = ContextWindow.clamp((dict["input_tokens"] as? Int) ?? 0)
            let cacheRead = ContextWindow.clamp((dict["cache_read_tokens"] as? Int) ?? 0)
            let cacheCreate = ContextWindow.clamp((dict["cache_creation_input_tokens"] as? Int) ?? 0)
            let totalTokens = inputTokens + cacheRead + cacheCreate
            var details = MessageDetails(
                model: model,
                effort: effort,
                contextTokens: totalTokens > 0 ? totalTokens : nil
            )

            let toolCalls = (dict["tool_calls"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            details.editedPathHashes = antigravityEditedPathHashes(in: toolCalls)

            var activity: Activity?
            if let lastTool = toolCalls.reversed().first(where: { ($0["name"] as? String)?.isEmpty == false }),
               let name = lastTool["name"] as? String
            {
                let args = lastTool["args"] as? [String: Any] ?? [:]
                activity = ActivitySummary.forAntigravityToolCall(name: name, args: args)
                details.phase = .tool
            } else if let text = dict["content"] as? String, let summary = ActivitySummary.forText(text) {
                activity = summary
                details.phase = .writing
            } else {
                details.phase = .thinking
            }
            return .message(role: .assistant, branch: nil, activity: activity, details: details)
        case "GENERIC":
            let status = (dict["status"] as? String)?.uppercased()
            let phase: Phase = status == "RUNNING" ? .tool : .thinking
            return .message(role: .user, branch: nil, activity: nil, details: MessageDetails(phase: phase))
        case "SYSTEM_MESSAGE":
            return .ignored
        default:
            return .ignored
        }
    }

    static func antigravityEditedPathHashes(in toolCalls: [[String: Any]]) -> [Int] {
        toolCalls.compactMap { call in
            guard let name = call["name"] as? String, antigravityEditTools.contains(name),
                  let args = call["args"] as? [String: Any] else { return nil }
            let path = ActivitySummary.antigravityString(args["Path"] ?? args["TargetFile"] ?? args["file_path"])
            guard let path, !path.isEmpty else { return nil }
            return path.hashValue
        }
    }
}

/// Fields derived from a read. `nil` means "no new value in this read", so the store leaves the
/// field untouched; `unavailable` reflects D24 (20+ decode failures and no success).
public struct TranscriptUpdate: Sendable, Equatable {
    public var aiTitle: String?
    public var branch: String?
    public var activity: Activity?
    public var phase: Phase?
    public var model: String?
    public var effort: String?
    public var spawnedToolUseIds: [String] = []
    /// The newest reply's context size (D38).
    public var contextTokens: Int?
    /// Every edit in this read, oldest first. `attach` leaves it empty: a back-scan cannot tell
    /// which turn an edit belongs to (D39).
    public var editedPathHashes: [Int] = []
    /// Background Bash starts, closes, launch errors, acknowledgements and `TaskStop` calls in this
    /// read, oldest first (D41, F25). `attach` returns only the starts no close or error in its window
    /// matched, with their acknowledgements, plus every close and stop it saw: a close or a stop in one
    /// file can match a start in another, so the store applies them. It leaves `erroredToolUseIds`
    /// empty, since a launch error always sits in the same file after its start.
    public var backgroundStarts: [BackgroundStart] = []
    public var closedToolUseIds: [String] = []
    public var erroredToolUseIds: [String] = []
    public var backgroundAcks: [BackgroundAck] = []
    public var stoppedTaskIds: [String] = []
    public var unavailable: Bool = false
    public init(
        aiTitle: String? = nil, branch: String? = nil, activity: Activity? = nil, phase: Phase? = nil,
        model: String? = nil, effort: String? = nil, spawnedToolUseIds: [String] = [], contextTokens: Int? = nil,
        editedPathHashes: [Int] = [], backgroundStarts: [BackgroundStart] = [], closedToolUseIds: [String] = [],
        erroredToolUseIds: [String] = [], backgroundAcks: [BackgroundAck] = [], stoppedTaskIds: [String] = [],
        unavailable: Bool = false
    ) {
        self.aiTitle = aiTitle; self.branch = branch; self.activity = activity; self.phase = phase
        self.model = model; self.effort = effort; self.spawnedToolUseIds = spawnedToolUseIds
        self.contextTokens = contextTokens; self.editedPathHashes = editedPathHashes
        self.backgroundStarts = backgroundStarts; self.closedToolUseIds = closedToolUseIds
        self.erroredToolUseIds = erroredToolUseIds; self.backgroundAcks = backgroundAcks
        self.stoppedTaskIds = stoppedTaskIds; self.unavailable = unavailable
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
    private let includeSidechain: Bool
    private let format: TranscriptFormat

    public init(
        path: URL, chunkSize: Int = 256 * 1024, maxBackscan: Int = 4 * 1024 * 1024,
        includeSidechain: Bool = false, format: TranscriptFormat = .claude
    ) {
        self.path = path
        self.chunkSize = max(16, chunkSize)
        self.maxBackscan = max(self.chunkSize, maxBackscan)
        self.includeSidechain = includeSidechain
        self.format = format
    }

    public var unavailable: Bool { decodeFailures >= Self.unavailableThreshold && decodeSuccesses == 0 }

    /// Read backwards in chunks, up to `maxBackscan`: every line until the latest title, branch,
    /// assistant activity, phase, model, effort and context size are known, then only the lines whose
    /// bytes may hold a background-task record (D41, R7). Leaves `offset` at EOF.
    public func attach() throws -> TranscriptUpdate {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        decodeFailures = 0
        decodeSuccesses = 0

        var found = TranscriptUpdate()
        var haveTitle = format == .antigravity
        var haveBranch = format == .antigravity
        var haveActivity = false
        var havePhase = false, haveModel = false, haveEffort = false, haveTokens = false
        var complete: Bool {
            if format == .antigravity { return haveActivity && havePhase && haveModel && haveTokens }
            return haveTitle && haveBranch && haveActivity && havePhase && haveModel && haveEffort && haveTokens
        }
        // Newest first while scanning backwards.
        var starts: [BackgroundStart] = [], closed: [String] = [], errored = Set<String>()
        var acks: [BackgroundAck] = [], stopped: [String] = []
        var carry: [UInt8] = []
        var end = size
        while end > 0, Int(size - end) < maxBackscan {
            if format == .antigravity, complete { break }
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
            if complete, !Self.mayHoldTaskRecord(body) { end = start; continue }
            for line in body.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                if format == .antigravity, complete { break }
                if complete, !Self.mayHoldTaskRecord(line) { continue }
                switch parseCounting(Data(line)) {
                case .aiTitle(let title):
                    if !haveTitle { found.aiTitle = title; haveTitle = true }
                case .message(let role, let branch, let activity, let details):
                    if !haveBranch, let branch { found.branch = branch; haveBranch = true }
                    if !haveActivity, role == .assistant, let activity { found.activity = activity; haveActivity = true }
                    if !havePhase, let phase = details.phase { found.phase = phase; havePhase = true }
                    if !haveModel, let model = details.model { found.model = model; haveModel = true }
                    if !haveEffort, let effort = details.effort { found.effort = effort; haveEffort = true }
                    if !haveTokens, let tokens = details.contextTokens { found.contextTokens = tokens; haveTokens = true }
                    starts += details.backgroundStarts.reversed()
                    closed += details.closedToolUseIds.reversed()
                    errored.formUnion(details.erroredToolUseIds)
                    acks += details.backgroundAcks.reversed()
                    stopped += details.stoppedTaskIds.reversed()
                case .taskRecords(let ids):
                    closed += ids.reversed()
                case .ignored, nil:
                    break
                }
            }
            end = start
        }
        // Open tasks: the starts in the window minus the closes and launch errors in it. Stops are left
        // to the store, with the acknowledgements that give these starts their task ids (F25).
        let ended = errored.union(closed)
        found.backgroundStarts = starts.reversed().filter { !ended.contains($0.toolUseId) }
        let open = Set(found.backgroundStarts.map(\.toolUseId))
        found.backgroundAcks = acks.reversed().filter { open.contains($0.toolUseId) }
        found.closedToolUseIds = closed.reversed()
        found.stoppedTaskIds = stopped.reversed()
        offset = size
        found.unavailable = unavailable
        return found
    }

    /// Byte needles of the lines that can start, acknowledge or end a background task (F22, F23,
    /// F25). Claude Code writes compact JSON, so `"is_error":true` has no space.
    private static let taskNeedles: [[UInt8]] = [
        "run_in_background", "task-notification", #""is_error":true"#, TranscriptLineParser.ackLeadIn,
        #""name":""# + TranscriptLineParser.stopToolName + #"""#,
    ].map { Array($0.utf8) }

    /// A cheap pre-filter, so the back-scan past the newest fields decodes only candidate lines (R7).
    static func mayHoldTaskRecord(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.withUnsafeBytes { hay in
            guard let base = hay.baseAddress else { return false }
            return taskNeedles.contains { needle in
                hay.count >= needle.count && needle.withUnsafeBytes { memmem(base, hay.count, $0.baseAddress, $0.count) != nil }
            }
        }
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
            case .message(_, let branch, let activity, let details):
                if let branch { update.branch = branch }
                if let activity { update.activity = activity }
                if let phase = details.phase { update.phase = phase }
                if let model = details.model { update.model = model }
                if let effort = details.effort { update.effort = effort }
                update.spawnedToolUseIds += details.spawnedToolUseIds
                if let tokens = details.contextTokens { update.contextTokens = tokens }
                update.editedPathHashes += details.editedPathHashes
                update.backgroundStarts += details.backgroundStarts
                update.closedToolUseIds += details.closedToolUseIds
                update.erroredToolUseIds += details.erroredToolUseIds
                update.backgroundAcks += details.backgroundAcks
                update.stoppedTaskIds += details.stoppedTaskIds
            case .taskRecords(let closed): update.closedToolUseIds += closed
            case .ignored, nil: break
            }
        }
        update.unavailable = unavailable
        return update
    }

    /// Read forward from the start (or the last `maxBytes`) so every `Agent` call is seen; used for
    /// subagent transcripts, which are short and whose spawned ids nest grandchildren (D33).
    public func attachFromStart(maxBytes: Int = 4 * 1024 * 1024) throws -> TranscriptUpdate {
        let size = (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.uint64Value ?? 0
        offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        decodeFailures = 0
        decodeSuccesses = 0
        return try readNew() ?? TranscriptUpdate(unavailable: unavailable)
    }

    private func reattachAfterTruncation() throws -> TranscriptUpdate { try attach() }

    private func parseCounting(_ line: Data) -> TranscriptLine? {
        let parsed = TranscriptLineParser.parse(line, includeSidechain: includeSidechain, format: format)
        if parsed == nil { decodeFailures += 1 } else { decodeSuccesses += 1 }
        return parsed
    }
}
