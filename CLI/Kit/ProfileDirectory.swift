import Foundation
import TurtleDiverCore
import TurtleDiverSystem

/// The profile directory, read without side effects.
///
/// `ProfileManager` is public but its initialiser *creates* a default profile
/// when the active name has no file. A read command that writes is a bug, so the
/// CLI does its own listing and parsing here. `ProfileParser` is public and does
/// the hard part; this type is only the directory.
public struct ProfileDirectory {
    public let directory: URL

    public init(directory: URL = ProfileDirectory.defaultDirectory()) {
        self.directory = directory
    }

    /// `~/Library/Application Support/TurtleDiver/Profiles`, the same path the
    /// app uses. The app is not sandboxed, so this is the real directory and not
    /// a container's copy of it.
    public static func defaultDirectory() -> URL {
        OpenConnectPidFile.applicationSupportDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    /// Every `*.conf`, by name and sorted. A missing directory is an empty list,
    /// not an error: "no profiles" is a fact, and creating the directory to
    /// report it would be the same side effect as above.
    public func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files
            .filter { $0.hasSuffix(".conf") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    public func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(name + ".conf")
    }

    public func load(named name: String) -> ProfileParseResult? {
        guard let text = try? String(contentsOf: fileURL(for: name), encoding: .utf8) else { return nil }
        return ProfileParser.parse(text, name: name)
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: name).path)
    }

    /// The profile to use when the caller did not name one: the app's active
    /// profile if it still exists, otherwise the only profile if there is
    /// exactly one. `nil` when neither is true — a guess among several profiles
    /// would be a wrong answer presented as a right one.
    public func resolveDefault(activeName: String?) -> String? {
        if let activeName, !activeName.isEmpty, exists(activeName) { return activeName }
        let all = names()
        return all.count == 1 ? all.first : nil
    }
}
