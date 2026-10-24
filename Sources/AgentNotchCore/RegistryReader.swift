import Foundation

/// Fallback list source (D23): decodes `~/.claude/sessions/<pid>.json`.
/// Only files whose extension is exactly `json` are ever opened; the sibling `*.key` files are
/// secrets (R5, F2) and are filtered out by name before any read happens.
public struct RegistryReader: Sendable {
    public typealias FileOpener = @Sendable (URL) -> Data?

    public var directory: URL
    private let open: FileOpener

    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    public init(directory: URL = RegistryReader.defaultDirectory(), open: @escaping FileOpener = { try? Data(contentsOf: $0) }) {
        self.directory = directory
        self.open = open
    }

    /// Throws only when the directory itself cannot be listed. A single bad file is skipped (R8).
    public func read(now: Date) throws -> [ListedSession] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names
            .filter { ($0 as NSString).pathExtension == "json" }
            .sorted()
            .compactMap { name -> ListedSession? in
                let url = directory.appendingPathComponent(name)
                guard let data = open(url), let entry = Self.decode(data, now: now) else { return nil }
                return entry
            }
    }

    /// One session's registry entry, used to learn the Claude Code version of a session that
    /// `claude agents --json` listed (the command output carries no version).
    public func readOne(pid: Int32, now: Date) -> ListedSession? {
        let url = directory.appendingPathComponent("\(pid).json")
        guard let data = open(url) else { return nil }
        return Self.decode(data, now: now)
    }

    static func decode(_ data: Data, now: Date) -> ListedSession? {
        guard let raw = try? JSONSerialization.jsonObject(with: data), let dict = raw as? [String: Any] else { return nil }
        return ListedSession(json: dict, now: now)
    }
}
