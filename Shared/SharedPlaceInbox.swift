import Foundation

enum SharedPlaceInbox {
    static let inputLimit = 8_192

    private static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ArrivalAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("pending-place.txt")
    }

    static func save(_ text: String) -> Bool {
        guard let fileURL, !text.isEmpty, text.utf8.count <= inputLimit else { return false }
        do {
            try Data(text.utf8).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func take() -> String? {
        guard let fileURL else { return nil }
        let reading = fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        guard (try? FileManager.default.moveItem(at: fileURL, to: reading)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: reading) }
        return try? String(contentsOf: reading, encoding: .utf8)
    }

    static func clear() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}
