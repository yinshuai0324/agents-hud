import Foundation

/// Streams a .jsonl file line by line without loading it whole (transcripts can
/// be hundreds of MB). Mirrors the readline usage in claude.ts / today.ts:
/// blank lines and unparseable lines are skipped by the callers.
enum JSONLReader {
    /// Calls `handle` with each parsed top-level JSON object. Lines that fail
    /// to parse (or aren't objects) are skipped. Returns false if the file
    /// couldn't be opened.
    @discardableResult
    static func forEachObject(atPath path: String, _ handle: ([String: Any]) -> Void) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }

        var buffer = Data()
        let chunkSize = 1 << 20 // 1 MB
        let newline = UInt8(ascii: "\n")

        func processLine(_ line: Data) {
            // Trim whitespace-only lines cheaply.
            guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            handle(obj)
        }

        while true {
            let chunk: Data
            do {
                guard let d = try fh.read(upToCount: chunkSize), !d.isEmpty else { break }
                chunk = d
            } catch {
                break // partial/locked file — keep whatever we read
            }
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: newline) {
                processLine(buffer.subdata(in: buffer.startIndex..<idx))
                buffer.removeSubrange(buffer.startIndex...idx)
            }
        }
        if !buffer.isEmpty {
            processLine(buffer)
        }
        return true
    }
}

/// Parse an ISO timestamp string the way JS Date.parse handles Claude Code's
/// transcript timestamps (RFC3339, with or without fractional seconds).
enum TimestampParser {
    private static let withMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Epoch milliseconds, or nil when unparseable (NaN in the Node code).
    static func epochMs(_ s: String) -> Double? {
        if let d = withMillis.date(from: s) ?? plain.date(from: s) {
            return d.timeIntervalSince1970 * 1000
        }
        return nil
    }
}
