import Foundation

/// File-backed logger. Writes every Logger.log(...) line to both stdout
/// (so dev runs from the terminal still see output) and a per-launch
/// log file under ~/Library/Logs/VoiceInput/. Old files (>7 days) are
/// pruned at startup.
enum Logger {
    private static let logDir: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/VoiceInput", isDirectory: true)
    }()

    /// Public so callers (e.g. failed-transcription wav dumps) can drop
    /// debug artefacts alongside the log.
    static var directory: URL { logDir }

    private static var fileHandle: FileHandle?
    private static let queue = DispatchQueue(label: "me.changhai.VoiceInput.logger")
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Set up the log directory, prune old files, open today's log file.
    /// Safe to call multiple times — second call is a no-op.
    static func bootstrap() {
        queue.sync {
            guard fileHandle == nil else { return }
            try? FileManager.default.createDirectory(
                at: logDir, withIntermediateDirectories: true
            )
            pruneOldArtifacts(retentionDays: 7)
            let stamp = filenameTimestamp(Date())
            let url = logDir.appendingPathComponent("run-\(stamp).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: url)
            // Update a stable symlink so external tooling can `tail -f latest.log`.
            let symlink = logDir.appendingPathComponent("latest.log")
            try? FileManager.default.removeItem(at: symlink)
            try? FileManager.default.createSymbolicLink(
                at: symlink, withDestinationURL: url
            )
        }
        log("Logger bootstrapped. Log dir: \(logDir.path)")
    }

    static func log(_ message: String) {
        let line = "[\(dateFormatter.string(from: Date()))] \(message)\n"
        queue.async {
            // stdout for dev runs from terminal
            FileHandle.standardOutput.write(Data(line.utf8))
            // file for everyone else
            try? fileHandle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Filename-safe timestamp suitable for log/wav files.
    static func filenameTimestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // MARK: - Private

    /// Delete .log and .wav files older than `retentionDays`. Symlinks
    /// (e.g. `latest.log`) are left alone since their targets may be
    /// inside the retention window.
    private static func pruneOldArtifacts(retentionDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]
        ) else { return }
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let ext = url.pathExtension.lowercased()
            guard ext == "log" || ext == "wav" else { continue }
            guard let mtime = values?.contentModificationDate else { continue }
            if mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
