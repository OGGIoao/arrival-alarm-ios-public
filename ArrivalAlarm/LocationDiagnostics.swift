#if DEBUG
import CoreLocation

@MainActor
final class LocationDiagnostics {
    enum Event: String {
        case runStarted = "开始守候"
        case locationStarted = "定位启动"
        case locationCallback = "定位回调"
        case locationUnavailable = "暂时无法定位"
        case locationFailed = "定位失败"
        case locationPermissionDenied = "定位权限不满足"
        case notificationPermissionDenied = "通知权限不满足"
        case notificationPermissionCheckFailed = "通知权限检查失败"
        case notificationSubmitting = "提交通知"
        case notificationAccepted = "通知已受理"
        case notificationFailed = "通知提交失败"
        case stopped = "手动停止"
        case locationEnded = "定位结束"
    }

    struct Report {
        let title: String
        let message: String
        let icon: String
        let needsSettings: Bool
        let rows: [(label: String, value: String)]
        let note: String?
        let raw: String
    }

    private enum Field: String {
        case radius = "半径"
        case count = "样本数"
        case distance = "距离"
        case decision = "判定"

        func record(_ value: String) -> String { "\(rawValue)=\(value)" }
    }

    private struct Entry {
        let event: Event
        let time: Date
        let fields: [String: String]

        subscript(field: Field) -> String? { fields[field.rawValue] }
    }

    private static let separator = "  "
    private static let inRange = "有效位置已进圈"
    private static let outsideRange = "有效位置在圈外"

    private let file = URL.cachesDirectory.appending(path: "arrival-location-diagnostics.txt")
    private let clock: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var hasCurrentFile = false
    private var writeFailed = false

    func clear() {
        hasCurrentFile = false
        writeFailed = false
        try? FileManager.default.removeItem(at: file)
    }

    func begin(radius: ReminderRadius) {
        hasCurrentFile = false
        writeFailed = false
        let header = line(.runStarted, at: .now, fields: [
            Field.radius.record(radius.label),
            "精度上限=\(radius.accuracyLimit) 米",
            "样本最长有效时间=\(ArrivalCheck.maximumAge) 秒"
        ])
        do {
            // 首次解锁后可在锁屏期间继续写入。缓存目录用于保留最近一轮。
            try Data(header.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            hasCurrentFile = true
        } catch {
            writeFailed = true
        }
    }

    func append(_ event: Event, at time: Date = .now, fields: [String] = []) {
        guard hasCurrentFile, !writeFailed else { return }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line(event, at: time, fields: fields).utf8))
        } catch {
            writeFailed = true
        }
    }

    func recordCallback(
        at time: Date,
        sample: CLLocation?,
        count: Int,
        distance: CLLocationDistance?,
        result: ArrivalCheck.Result?
    ) {
        let sampleTime = sample.map { clock.string(from: $0.timestamp) }
        append(.locationCallback, at: time, fields: [
            Field.count.record(String(count)),
            "采样时间=\(sampleTime ?? "—")",
            Field.distance.record(meters(distance)),
            "水平精度=\(meters(sample?.horizontalAccuracy))",
            Field.decision.record(decisionText(result, sample: sample))
        ])
    }

    func report() -> Report {
        let raw = rawReport()
        let entries = raw.split(whereSeparator: \.isNewline).compactMap(parseEntry)
        guard let start = entries.last(where: { $0.event == .runStarted }) else {
            return Report(
                title: writeFailed || hasCurrentFile ? "暂时读不到记录" : "还没有守候记录",
                message: raw,
                icon: "location.slash",
                needsSettings: false,
                rows: [],
                note: nil,
                raw: raw
            )
        }

        let callback = entries.last { $0.event == .locationCallback }
        let lastEvent = entries.last { $0.event != .locationEnded } ?? start
        let distance = (callback?[.distance]).flatMap(displayDistance)
        let summary = presentation(for: lastEvent, distance: distance)
        var rows = [("开始守候", start.time.formatted(date: .abbreviated, time: .shortened))]
        if let radius = start[.radius] { rows.append(("提醒范围", radius)) }
        if let callback, (Int(callback[.count] ?? "") ?? 0) > 0 {
            rows.append(("最近收到位置", callback.time.formatted(date: .omitted, time: .standard)))
            if let distance, lastEvent[.decision] != Self.outsideRange {
                rows.append(("该位置距车站", distance))
            }
        } else {
            rows.append(("最近收到位置", "暂无"))
        }
        switch lastEvent.event {
        case .notificationAccepted, .notificationFailed:
            break
        case .notificationSubmitting:
            rows.append(("提醒通知", "提交中"))
        default:
            rows.append(("提醒通知", "尚未提交"))
        }
        return Report(
            title: summary.title,
            message: summary.message,
            icon: summary.icon,
            needsSettings: lastEvent.event == .locationPermissionDenied || lastEvent.event == .notificationPermissionDenied,
            rows: rows,
            note: writeFailed ? "这轮记录不完整。" : nil,
            raw: raw
        )
    }

    private func rawReport() -> String {
        if writeFailed, !hasCurrentFile { return "本轮诊断文件创建失败。" }
        do {
            let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            if writeFailed { return "本轮诊断写入中断，以下记录不完整。\n\n" + contents }
            return contents
        } catch {
            return hasCurrentFile ? "无法读取本轮诊断记录。" : "暂无可用记录。点「开始守候」后会生成记录。"
        }
    }

    private func line(_ event: Event, at time: Date, fields: [String]) -> String {
        ([clock.string(from: time), event.rawValue] + fields).joined(separator: Self.separator) + "\n"
    }

    private func parseEntry(_ line: Substring) -> Entry? {
        let parts = line.components(separatedBy: Self.separator)
        guard parts.count >= 2, let time = clock.date(from: parts[0]),
              let event = Event(rawValue: parts[1]) else { return nil }
        var fields: [String: String] = [:]
        for part in parts.dropFirst(2) {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return Entry(event: event, time: time, fields: fields)
    }

    private func displayDistance(_ raw: String) -> String? {
        guard raw.hasSuffix(" 米"), let value = Double(raw.dropLast(2)), value.isFinite else { return nil }
        return "\(value.formatted(.number.precision(.fractionLength(0)))) 米"
    }

    private func presentation(for entry: Entry, distance: String?) -> (title: String, message: String, icon: String) {
        switch entry.event {
        case .runStarted:
            ("正在准备守候", "App 正在检查定位和通知是否可用。", "clock")
        case .locationStarted, .locationUnavailable, .locationEnded:
            ("还没收到新位置", "App 正在等 iPhone 提供位置。", "location")
        case .locationCallback:
            positionPresentation(entry[.decision], distance: distance)
        case .locationFailed:
            ("定位中断了", "回到首页，再试一次开始守候。", "location.slash")
        case .locationPermissionDenied:
            ("需要开启定位", "打开设置，允许使用 App 期间定位，并开启精确位置。", "location.slash")
        case .notificationPermissionDenied:
            ("需要开启通知", "打开设置，允许通知，并勾选「锁定屏幕」。", "bell.slash")
        case .notificationPermissionCheckFailed:
            ("暂时无法检查通知", "回到首页，再试一次开始守候。", "bell.slash")
        case .notificationSubmitting:
            ("正在发送提醒", "已进入提醒范围，正在把提醒交给 iPhone。", "bell")
        case .notificationAccepted:
            ("提醒已交给 iPhone", "可到锁屏或通知中心查看这条到站提醒。", "checkmark.circle")
        case .notificationFailed:
            ("提醒没有发出去", "回到首页，再试一次开始守候。", "bell.slash")
        case .stopped:
            ("这轮守候已停止", "下方保留了停止前的记录。", "stop.circle")
        }
    }

    private func positionPresentation(_ decision: String?, distance: String?) -> (String, String, String) {
        switch decision {
        case Self.outsideRange:
            (distance.map { "距车站还有 \($0)" } ?? "仍在提醒范围外", "这次定位有效，正在继续守候。", "location.circle")
        case Self.inRange:
            ("已进入提醒范围", "App 已收到圈内的有效位置。", "location.circle")
        case Self.filtered(.beforeStart), Self.filtered(.stale):
            ("收到的位置太旧", "App 正在等 iPhone 提供新的位置。", "clock")
        case Self.filtered(.lowAccuracy), Self.filtered(.invalidAccuracy):
            ("这次定位不够准", "App 正在等更准确的位置。", "location.slash")
        default:
            ("还没有可用的新位置", "App 正在等待下一条定位。", "location")
        }
    }

    private static func filtered(_ reason: ArrivalCheck.FilterReason) -> String {
        "过滤（\(reason.text)）"
    }

    private func meters(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f 米", value)
    }

    private func decisionText(_ result: ArrivalCheck.Result?, sample: CLLocation?) -> String {
        switch result {
        case .outside: Self.outsideRange
        case .arrived: Self.inRange
        case .filtered(let reason): Self.filtered(reason)
        case nil: sample == nil ? "回调未包含样本" : "本轮判定器未就绪"
        }
    }
}

private extension ArrivalCheck.FilterReason {
    var text: String {
        switch self {
        case .alreadyArrived: "已经触发过到站"
        case .invalidCoordinate: "坐标无效"
        case .beforeStart: "早于定位启动"
        case .outOfOrder: "重复或乱序"
        case .futureTimestamp: "采样时间在未来"
        case .stale: "样本过期"
        case .invalidAccuracy: "水平精度无效"
        case .lowAccuracy: "精度不足"
        }
    }
}
#endif
