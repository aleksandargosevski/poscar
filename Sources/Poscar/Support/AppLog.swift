import Foundation

/// A small lifecycle log in ~/Library/Logs/Poscar/poscar.log (launches, quits, window closes), so
/// "Poscar wasn't running" can be answered later. macOS keeps no lasting record of such events.
enum AppLog {
    private static let queue = DispatchQueue(label: "poscar.applog")
    private static let maxSize = 512 * 1024

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Poscar/poscar.log")
    }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let url = fileURL
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep one previous file instead of growing forever.
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxSize {
                let previous = url.deletingPathExtension().appendingPathExtension("1.log")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Writes synchronously; used while the app is quitting, when async work may never run.
    static func flush() {
        queue.sync {}
    }
}
