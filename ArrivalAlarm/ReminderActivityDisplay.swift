import ActivityKit
import Foundation

@MainActor
final class ReminderActivityDisplay {
    private typealias LiveActivity = Activity<ReminderActivityAttributes>
    private typealias Content = ActivityContent<ReminderActivityAttributes.ContentState>

    private static let displayLifetime: TimeInterval = 45
    private static let updateInterval: TimeInterval = 5

    private var activityID: String?
    private var lastContent: Content?
    private var lastUpdate: Date?
    private var updateTask: Task<Void, Never>?

    init() {
        // 进程重新启动后，旧定位会话已结束。先收起旧卡片。
        let oldActivities = LiveActivity.activities.map(\.id)
        Task {
            for id in oldActivities {
                await Self.dismiss(id: id)
            }
        }
    }

    func begin(placeName: String?, at time: Date) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ReminderActivityAttributes.ContentState(phase: .waiting, placeName: placeName, distance: nil)
        let content = content(state, observedAt: time)
        guard let activity = try? LiveActivity.request(
            attributes: ReminderActivityAttributes(),
            content: content,
            pushType: nil
        ) else { return }
        activityID = activity.id
        lastContent = content
        lastUpdate = time
    }

    func update(
        phase: ReminderActivityAttributes.Phase,
        placeName: String?,
        distance: String? = nil,
        observedAt: Date? = nil
    ) {
        if let state = lastContent?.state, state.phase == phase, state.placeName == placeName {
            if phase == .positionUnavailable { return }
            if let lastUpdate, Date.now.timeIntervalSince(lastUpdate) < Self.updateInterval { return }
        }
        let state = ReminderActivityAttributes.ContentState(phase: phase, placeName: placeName, distance: distance)
        publish(content(state, observedAt: observedAt))
    }

    func updatePlaceName(_ name: String?) {
        guard let old = lastContent, old.state.placeName != name else { return }
        let state = ReminderActivityAttributes.ContentState(phase: old.state.phase, placeName: name, distance: old.state.distance)
        publish(ActivityContent(state: state, staleDate: old.staleDate))
    }

    private func publish(_ content: Content) {
        guard let activityID else { return }
        lastContent = content
        lastUpdate = .now
        let previous = updateTask
        previous?.cancel()
        updateTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await Self.send(content, to: activityID)
        }
    }

    func end() {
        guard let id = activityID else { return }
        activityID = nil
        lastContent = nil
        lastUpdate = nil
        let update = updateTask
        update?.cancel()
        updateTask = nil
        Task {
            await update?.value
            await Self.dismiss(id: id)
        }
    }

    private func content(
        _ state: ReminderActivityAttributes.ContentState,
        observedAt: Date?
    ) -> Content {
        ActivityContent(state: state, staleDate: observedAt?.addingTimeInterval(Self.displayLifetime))
    }

    private nonisolated static func send(_ content: Content, to id: String) async {
        guard let activity = LiveActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content)
    }

    private nonisolated static func dismiss(id: String) async {
        guard let activity = LiveActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
