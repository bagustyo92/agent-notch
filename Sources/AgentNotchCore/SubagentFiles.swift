import Foundation

/// Locates and reads `~/.claude/projects/<project>/<sessionId>/subagents/agent-<id>.{jsonl,meta.json}`
/// (D33). The meta file is read for five fields only; nothing else in it is kept.
public enum SubagentFiles {
    /// The subagents directory next to a session transcript `<project>/<sessionId>.jsonl`.
    public static func directory(forTranscript url: URL) -> URL {
        url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
    }

    public static func transcript(_ directory: URL, agentId: String) -> URL {
        directory.appendingPathComponent("agent-\(agentId).jsonl")
    }

    public static func meta(_ directory: URL, agentId: String) -> URL {
        directory.appendingPathComponent("agent-\(agentId).meta.json")
    }

    /// `…/<sessionId>/subagents/agent-<id>.jsonl` (or `.meta.json`) → its session, agent and directory.
    public static func parse(path: String) -> (sessionId: String, agentId: String, directory: URL)? {
        let parts = (path as NSString).pathComponents
        guard parts.count >= 4, parts[parts.count - 2] == "subagents" else { return nil }
        let file = parts[parts.count - 1]
        guard file.hasPrefix("agent-") else { return nil }
        let stem: Substring
        if file.hasSuffix(".meta.json") { stem = file.dropLast(10) } else if file.hasSuffix(".jsonl") { stem = file.dropLast(6) } else { return nil }
        let agentId = String(stem.dropFirst(6))
        let sessionId = parts[parts.count - 3]
        guard !agentId.isEmpty, !agentId.contains(".."), !sessionId.isEmpty else { return nil }
        return (sessionId, agentId, URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true))
    }

    /// Agent ids present in a subagents directory.
    public static func agentIds(in directory: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let ids = names.compactMap { parse(path: directory.appendingPathComponent($0).path)?.agentId }
        return Array(Set(ids)).sorted()
    }

    /// Meta fields plus the transcript's creation and modification times; no transcript read.
    public static func readMeta(_ directory: URL, agentId: String) -> SubagentUpdate {
        var update = SubagentUpdate(agentId: agentId)
        if let data = try? Data(contentsOf: meta(directory, agentId: agentId)),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let type = (dict["agentType"] as? String).map(ActivitySummary.finish), !type.isEmpty { update.agentType = type }
            update.description = (dict["description"] as? String).map(ActivitySummary.finish) ?? ""
            update.toolUseId = TranscriptLineParser.token(dict["toolUseId"])
            update.spawnDepth = max(1, (dict["spawnDepth"] as? NSNumber)?.intValue ?? 1)
            update.finished = (dict["finished"] as? Bool) ?? false
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: transcript(directory, agentId: agentId).path) {
            update.startedAt = attrs[.creationDate] as? Date
            update.lastWriteAt = attrs[.modificationDate] as? Date
        }
        return update
    }
}
