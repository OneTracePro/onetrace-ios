import Foundation

/// Events waiting to be sent, one JSON object per line in Application Support: they survive a restart and a lack of
/// network. Beyond `maxSize` the oldest events are dropped. Used from the SDK queue only.
final class EventQueue {
    private let file: URL
    private let maxSize: Int
    private var items: [String]

    init(file: URL, maxSize: Int) {
        self.file = file
        self.maxSize = maxSize
        let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
        items = Array(lines.suffix(maxSize))
    }

    var count: Int { items.count }

    func add(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event), let line = String(data: data, encoding: .utf8) else { return }
        items.append(line)
        if items.count > maxSize { items.removeFirst(items.count - maxSize) }
        save()
    }

    func peek(_ count: Int) -> [[String: Any]] {
        items.prefix(count).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    func remove(_ count: Int) {
        items.removeFirst(min(count, items.count))
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = items.isEmpty ? "" : items.joined(separator: "\n") + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}
