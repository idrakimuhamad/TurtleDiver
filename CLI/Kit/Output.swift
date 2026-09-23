import Foundation

/// Where a command's output goes, and in which of the two shapes.
///
/// The rule that keeps `--json` usable in a pipeline: in JSON mode, standard
/// output carries exactly one JSON document and nothing else. Progress and
/// human notes go to standard error, where a person still sees them and `jq`
/// does not.
public struct Output {
    public let json: Bool
    public let quiet: Bool
    private let out: FileHandle
    private let err: FileHandle

    public init(json: Bool, quiet: Bool, out: FileHandle = .standardOutput, err: FileHandle = .standardError) {
        self.json = json
        self.quiet = quiet
        self.out = out
        self.err = err
    }

    /// The one JSON document, on standard output. No-op unless `--json`.
    public func jsonObject(_ object: [String: Any]) {
        guard json else { return }
        write(Self.encode(object), to: out)
    }

    /// A line for a person. Suppressed by `--quiet`, and sent to standard error
    /// in JSON mode so the JSON stays the only thing on standard output.
    public func line(_ text: String) {
        guard !quiet else { return }
        write(text + "\n", to: json ? err : out)
    }

    /// A progress note. Always standard error, always shown: silence during a
    /// connect is the failure mode this exists to avoid.
    public func note(_ text: String) {
        write(text + "\n", to: err)
    }

    public func error(_ text: String) {
        write(text + "\n", to: err)
    }

    /// The body of a failure, in whichever shape is selected. One place, so the
    /// two never disagree about what went wrong.
    public func fail(_ failure: CLIFailure) {
        if json {
            var body: [String: Any] = [
                "ok": false,
                "error": failure.message,
                "code": failure.code.meaning,
                "exitCode": Int(failure.code.rawValue),
            ]
            if !failure.details.isEmpty { body["details"] = failure.details }
            jsonObject(body)
            // Said once, on standard error, so a person watching the terminal
            // is not left with a JSON document and no sentence.
            note("turtlediver: \(failure.message)")
        } else {
            error("turtlediver: \(failure.message)")
        }
    }

    /// The two shapes of a success, from one source. In JSON mode the document
    /// goes to standard output and the sentences to standard error, so a person
    /// still sees them and `jq` does not.
    public func report(_ object: [String: Any], _ lines: [String]) {
        if json {
            jsonObject(object)
            for text in lines { note(text) }
        } else {
            for text in lines { line(text) }
        }
    }

    /// Stable key order (`.sortedKeys`) so two runs of the same command produce
    /// byte-identical output — which is what makes `--json` diffable and
    /// testable. A JSON encoder that cannot see a value fails loudly rather
    /// than printing `null` and letting the caller believe it.
    static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"the command produced a value that is not JSON"}"#
        }
        return text + "\n"
    }

    private func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
