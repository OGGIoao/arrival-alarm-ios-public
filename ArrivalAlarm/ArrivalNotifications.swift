import CoreLocation
import UserNotifications

enum ArrivalNotifications {
    static let testDelay = 10
    static let returnID = "last-trip-return"
    static let returnDetailsID = UUID()
    static let arrivalCategory = "arrival"
    static let trackingCategory = "tracking"
    static let recoveryCategory = "tracking-recovery"
    static let acknowledgeAction = "acknowledge-arrival"
    static let stopAction = "stop-tracking"
    static let resumeAction = "resume-tracking"
    static let pulseInterval: TimeInterval = 30
    private static let pulseCount = 10

    static var categories: Set<UNNotificationCategory> {
        let acknowledge = UNNotificationAction(identifier: acknowledgeAction, title: "我已到达", options: [])
        let stop = UNNotificationAction(identifier: stopAction, title: "停止守候", options: [.destructive])
        let resume = UNNotificationAction(identifier: resumeAction, title: "继续守候", options: [.foreground])
        return [
            UNNotificationCategory(identifier: arrivalCategory, actions: [acknowledge], intentIdentifiers: []),
            UNNotificationCategory(identifier: trackingCategory, actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: recoveryCategory, actions: [resume, stop], intentIdentifiers: [])
        ]
    }

    static func arrivalIDs(_ id: UUID) -> [String] {
        (0..<pulseCount).map { "arrival-\(id.uuidString)-\($0)" }
    }

    static func trackingID(_ id: UUID) -> String { "tracking-\(id.uuidString)" }

    static func trackingContent(id: UUID, place: String?, interrupted: Bool) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = interrupted ? "到站守候已中断" : "到站提醒正在守候"
        content.body = place ?? (interrupted ? "点「继续守候」恢复上次任务。" : "展开通知可停止守候。")
        content.categoryIdentifier = interrupted ? recoveryCategory : trackingCategory
        content.interruptionLevel = .passive
        content.userInfo = ["tripID": id.uuidString]
        return content
    }

    static func arrivalContent(receipt: ArrivalReceipt, showsDestination: Bool) -> UNNotificationContent {
        let content = audibleContent()
        content.title = showsDestination ? "\(receipt.placeName)快到了" : "快到站了"
        content.body = "请确认随身物品，准备下车。"
        content.categoryIdentifier = arrivalCategory
        content.threadIdentifier = receipt.id.uuidString
        content.userInfo = ["tripID": receipt.id.uuidString]
        return content
    }

    static func testRequest() -> UNNotificationRequest {
        let content = audibleContent()
        content.title = "测试提醒"
        content.body = "这就是到站时会收到的提示。"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(testDelay), repeats: false)
        return UNNotificationRequest(identifier: "reminder-test", content: content, trigger: trigger)
    }

    private static func audibleContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "ArrivalChime.wav"))
        content.interruptionLevel = .timeSensitive
        return content
    }

    static func pulseRequest(identifier: String, content: UNNotificationContent, at date: Date) -> UNNotificationRequest? {
        let delay = date.timeIntervalSinceNow
        guard delay > 0, let updated = content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        updated.userInfo["fireAt"] = date.timeIntervalSince1970
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: updated, trigger: trigger)
    }

    static func returnRequest(for target: ArrivalTarget, showsDestination: Bool) -> UNNotificationRequest {
        let region = CLCircularRegion(center: target.station.coordinate, radius: Double(target.radius.rawValue), identifier: returnID)
        region.notifyOnEntry = true
        region.notifyOnExit = false
        let trigger = UNLocationNotificationTrigger(region: region, repeats: true)
        let receipt = ArrivalReceipt(id: returnDetailsID, placeName: target.station.name)
        return UNNotificationRequest(
            identifier: returnID, content: arrivalContent(receipt: receipt, showsDestination: showsDestination), trigger: trigger
        )
    }

    static func matchesReturnRequest(_ request: UNNotificationRequest, target: ArrivalTarget) -> Bool {
        guard let trigger = request.trigger as? UNLocationNotificationTrigger, trigger.repeats,
              let region = trigger.region as? CLCircularRegion else { return false }
        return region.notifyOnEntry && !region.notifyOnExit
            && region.radius == Double(target.radius.rawValue)
            && region.center.latitude == target.station.coordinate.latitude
            && region.center.longitude == target.station.coordinate.longitude
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1_000 {
            return "\(Int((meters / 10).rounded()) * 10) 米"
        }
        return "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) 公里"
    }
}
