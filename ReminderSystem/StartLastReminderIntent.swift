import AppIntents
import Combine

struct StartLastReminderIntent: OpenIntent {
    static let title: LocalizedStringResource = "开始上次守候"
    static let description = IntentDescription("用上次确认的地点和提醒范围开始守候。")

    @Parameter(title: "守候")
    var target: LastReminderTarget

    init() {
        target = .lastReminder
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LastReminderRequest.shared.isPending = true
        return .result()
    }
}

enum LastReminderTarget: String, AppEnum {
    case lastReminder

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "守候")
    static let caseDisplayRepresentations: [LastReminderTarget: DisplayRepresentation] = [
        .lastReminder: "上次守候"
    ]
}

@MainActor
final class LastReminderRequest: ObservableObject {
    static let shared = LastReminderRequest()

    @Published var isPending = false

    private init() {}
}
