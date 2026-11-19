import Combine
import CoreLocation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class Reminder: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    enum State: Equatable {
        case restoring, idle, checkingNotifications(UUID), checkingLocation, requestingLocation
        case waitingForLocation, monitoring, recovering, interrupted
        case sendingNotification, notified, returnScheduled, needsSettings(String), failed(String)

        var tracksLocation: Bool {
            self == .waitingForLocation || self == .monitoring || self == .recovering
        }

        var canStop: Bool {
            switch self {
            case .checkingNotifications, .checkingLocation, .requestingLocation, .waitingForLocation,
                 .monitoring, .recovering, .returnScheduled:
                true
            default:
                false
            }
        }

        var locksSelection: Bool {
            self == .restoring || self == .sendingNotification || (canStop && self != .returnScheduled)
        }
    }

    enum Access: Equatable {
        case notRequested, ready, needsSettings
    }

    @Published private(set) var state: State = .restoring
    @Published private(set) var trip = TripStore.load()
    @Published private(set) var distanceLabel: String?
    @Published private(set) var locationAccess: Access = .notRequested
    @Published var presentedArrival: ArrivalReceipt?
    @Published private(set) var pendingArrival: ArrivalNotificationRoute?

    private let locationManager = CLLocationManager()
    private let notifications = UNUserNotificationCenter.current()
    private let activityDisplay = ReminderActivityDisplay()
    private var arrivalCheck: ArrivalCheck?
    private var heartbeat: Task<Void, Never>?
    private var lastUsableLocation: Date?
    private var recoveryAttempts = 0
    private var recoveryDeadline: Date?
    private var notificationChanges = Task<Void, Never> {}
    #if DEBUG
    let diagnostics = LocationDiagnostics()
    #endif

    var selection: StationSelection? { trip.selection }
    private var visiblePlaceName: String? { trip.showsDestination ? selection?.target.station.name : nil }
    var hasInterruptedTrip: Bool { trip.activeID != nil && !state.canStop && state != .sendingNotification }
    var nearbyCoordinate: CLLocationCoordinate2D? {
        guard canUsePreciseLocation, let location = locationManager.location,
              abs(location.timestamp.timeIntervalSinceNow) <= 300 else { return nil }
        return location.coordinate
    }

    override init() {
        super.init()
        updateLocationAccess()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
        Task { await restore() }
    }

    func registerNotificationDelegate() {
        notifications.delegate = self
        notifications.setNotificationCategories(ArrivalNotifications.categories)
    }

    func select(_ selected: StationSelection) {
        guard !state.locksSelection else { return }
        let sameTarget = selection?.target.station.id == selected.target.station.id
            && selection?.target.radius == selected.target.radius
        let previousID = trip.activeID
        guard save({ data in
            data.selection = selected
            data.remember(selected)
            if !sameTarget {
                data.activeID = nil
                data.returnArrival = nil
            }
        }) else { return }
        if !sameTarget {
            if let previousID { removeTrackingNotice(id: previousID) }
            cancelReturnReminder()
            state = .idle
        }
    }

    func start() {
        guard !state.canStop, !state.locksSelection, let selection else { return }
        let id = trip.activeID ?? UUID()
        let request = State.checkingNotifications(id)
        state = request
        #if DEBUG
        diagnostics.begin(radius: selection.target.radius)
        #endif

        Task {
            do {
                var settings = await notifications.notificationSettings()
                guard state == request else { return }
                if settings.authorizationStatus == .notDetermined {
                    try await requestNotificationPermission()
                    settings = await notifications.notificationSettings()
                }
                guard state == request else { return }
                guard canShowNotifications(settings) else {
                    #if DEBUG
                    diagnostics.append(.notificationPermissionDenied)
                    #endif
                    state = .needsSettings("请在设置中允许通知，并启用「锁定屏幕」。")
                    return
                }
                state = .checkingLocation
                appBecameActive()
            } catch {
                guard state == request else { return }
                #if DEBUG
                diagnostics.append(.notificationPermissionCheckFailed, fields: ["错误码=\((error as NSError).code)"])
                #endif
                state = .failed("无法检查通知权限，请重试。")
            }
        }
    }

    func startLastReminder() {
        if state == .returnScheduled { stop() }
        start()
    }

    func stop() {
        guard state.canStop || hasInterruptedTrip else { return }
        if let id = trip.activeID {
            guard save({ $0.activeID = nil }) else { return }
            removeTrackingNotice(id: id)
        }
        if state == .returnScheduled {
            guard save({ $0.returnArrival = nil }) else { return }
            cancelReturnReminder()
            if let arrival = trip.arrival { acknowledge(arrival.id) }
        } else {
            #if DEBUG
            diagnostics.append(.stopped)
            #endif
        }
        endLocationUpdates()
        state = .idle
    }

    func sceneBecameActive() {
        updateLocationAccess()
        appBecameActive()
        checkLocationTimeout()
        let expectedState = state
        let activeID = trip.activeID
        if expectedState == .returnScheduled || expectedState.tracksLocation {
            Task {
                let settings = await notifications.notificationSettings()
                guard state == expectedState, trip.activeID == activeID else { return }
                if !canShowNotifications(settings) {
                    if state == .returnScheduled { cancelReturnReminder() }
                    interrupt("请在设置中允许通知，并启用「锁定屏幕」。")
                }
            }
        }
    }

    private func appBecameActive() {
        guard UIApplication.shared.applicationState == .active,
              state == .checkingLocation || state == .requestingLocation,
              let selection else { return }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            guard state == .checkingLocation else { return }
            state = .requestingLocation
            requestLocationPermission()
        case .authorizedAlways, .authorizedWhenInUse:
            guard canUsePreciseLocation else {
                #if DEBUG
                diagnostics.append(.locationPermissionDenied, fields: ["精确位置未开启"])
                #endif
                state = .needsSettings("请在设置中启用「精确位置」。")
                return
            }
            let id = trip.activeID ?? UUID()
            let previousArrival = trip.arrival
            guard save({ data in
                data.beginTrip(id: id, for: selection, at: .now)
            }) else { return }
            if let previousArrival { cancelArrivalNotifications(previousArrival.id) }
            cancelReturnReminder()
            let now = Date.now
            #if DEBUG
            diagnostics.append(.locationStarted, at: now)
            #endif
            arrivalCheck = ArrivalCheck(target: selection.target, startedAt: now)
            lastUsableLocation = now
            recoveryAttempts = 0
            recoveryDeadline = nil
            state = .waitingForLocation
            activityDisplay.begin(placeName: visiblePlaceName, at: now)
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            beginHeartbeat()
            Task { await postTrackingNotice(id: id) }
        default:
            #if DEBUG
            diagnostics.append(.locationPermissionDenied)
            #endif
            state = .needsSettings("请在设置中允许使用 App 期间定位，并开启精确位置。")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateLocationAccess()
        if state.tracksLocation, !canUsePreciseLocation {
            #if DEBUG
            diagnostics.append(.locationPermissionDenied, fields: ["守候中权限发生变更"])
            #endif
            interrupt("定位权限已变更，请在设置中开启精确位置。")
        } else if state == .returnScheduled, !canUsePreciseLocation {
            cancelReturnReminder()
            state = .needsSettings("请允许使用精确位置，再开始守候。")
        }
        appBecameActive()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state.tracksLocation, let target = arrivalCheck?.target else { return }
        let now = Date.now
        #if DEBUG
        if locations.isEmpty {
            diagnostics.recordCallback(at: now, sample: nil, count: 0, distance: nil, result: nil)
        }
        #endif
        for location in locations {
            let result = arrivalCheck?.record(location, now: now)
            #if DEBUG
            let distance = CLLocationCoordinate2DIsValid(location.coordinate) ? target.distance(from: location) : nil
            diagnostics.recordCallback(at: now, sample: location, count: locations.count, distance: distance, result: result)
            #endif
            switch result {
            case .outside:
                lastUsableLocation = now
                recoveryAttempts = 0
                recoveryDeadline = nil
                distanceLabel = ArrivalNotifications.formatDistance(target.distance(from: location))
                state = .monitoring
                activityDisplay.update(
                    phase: .monitoring, placeName: visiblePlaceName, distance: distanceLabel,
                    observedAt: location.timestamp
                )
            case .arrived:
                guard let id = trip.activeID else { return }
                state = .sendingNotification
                sendArrivalNotification(target: target, id: id)
                return
            default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard state.tracksLocation else { return }
        if (error as? CLError)?.code == .locationUnknown {
            #if DEBUG
            diagnostics.append(.locationUnavailable)
            #endif
            distanceLabel = nil
            activityDisplay.update(phase: .positionUnavailable, placeName: visiblePlaceName)
            if state != .recovering { state = .waitingForLocation }
        } else {
            #if DEBUG
            diagnostics.append(.locationFailed, fields: ["错误码=\((error as NSError).code)"])
            #endif
            interrupt()
        }
    }

    private func beginHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.checkLocationTimeout()
            }
        }
    }

    private func checkLocationTimeout() {
        guard state.tracksLocation, let lastUsableLocation else { return }
        let retryDelays: [TimeInterval] = [10, 30]
        let now = Date.now
        guard now >= (recoveryDeadline ?? lastUsableLocation.addingTimeInterval(5 * 60)) else { return }
        #if DEBUG
        diagnostics.append(.locationUnavailable, fields: ["长时间未收到有效位置", "重试次数=\(recoveryAttempts)"])
        #endif
        if recoveryAttempts == retryDelays.count {
            interrupt()
        } else {
            recoveryDeadline = now.addingTimeInterval(retryDelays[recoveryAttempts])
            recoveryAttempts += 1
            distanceLabel = nil
            state = .recovering
            activityDisplay.update(phase: .positionUnavailable, placeName: visiblePlaceName)
            // 在后台保留原定位会话。回到前台时可以重新建立监听。
            if UIApplication.shared.applicationState == .active {
                locationManager.stopUpdatingLocation()
                locationManager.startUpdatingLocation()
            }
        }
    }

    private func interrupt(_ settingsMessage: String? = nil) {
        endLocationUpdates()
        state = settingsMessage.map(State.needsSettings) ?? .interrupted
        if let id = trip.activeID {
            Task { await postTrackingNotice(id: id) }
        }
    }

    private func endLocationUpdates() {
        activityDisplay.end()
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        heartbeat?.cancel()
        heartbeat = nil
        distanceLabel = nil
        if let id = trip.activeID { removeTrackingNotice(id: id) }
        #if DEBUG
        if arrivalCheck != nil { diagnostics.append(.locationEnded) }
        #endif
        arrivalCheck = nil
    }

    private func postTrackingNotice(id: UUID) async {
        guard trip.activeID == id, state.tracksLocation || hasInterruptedTrip else { return }
        let isInterrupted = hasInterruptedTrip
        let content = ArrivalNotifications.trackingContent(
            id: id, place: visiblePlaceName,
            interrupted: isInterrupted
        )
        let identifier = ArrivalNotifications.trackingID(id)
        try? await notifications.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        if trip.activeID != id || state == .sendingNotification {
            removeTrackingNotice(id: id)
        }
    }

    private func removeTrackingNotice(id: UUID) {
        let ids = [ArrivalNotifications.trackingID(id)]
        notifications.removePendingNotificationRequests(withIdentifiers: ids)
        notifications.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func sendArrivalNotification(target: ArrivalTarget, id: UUID) {
        let receipt = ArrivalReceipt(id: id, placeName: target.station.name, walkingDestination: selection?.separateDestination)
        removeTrackingNotice(id: id)
        guard save({ data in
            data.activeID = nil
            data.arrival = receipt
        }) else {
            interrupt()
            return
        }

        Task {
            defer { endLocationUpdates() }
            #if DEBUG
            diagnostics.append(.notificationSubmitting)
            #endif
            let content = ArrivalNotifications.arrivalContent(receipt: receipt, showsDestination: trip.showsDestination)
            let arrivalTime = Date.now
            do {
                let request = UNNotificationRequest(
                    identifier: ArrivalNotifications.arrivalIDs(id)[0], content: content, trigger: nil
                )
                try await notifications.add(request)
                #if DEBUG
                diagnostics.append(.notificationAccepted)
                #endif
            } catch {
                #if DEBUG
                diagnostics.append(.notificationFailed, fields: ["错误码=\((error as NSError).code)"])
                #endif
                guard save({ data in
                    data.activeID = id
                    data.arrival = nil
                }) else { return }
                state = .interrupted
                return
            }
            for (index, identifier) in ArrivalNotifications.arrivalIDs(id).enumerated().dropFirst() {
                guard trip.arrival?.id == id else { break }
                let date = arrivalTime.addingTimeInterval(ArrivalNotifications.pulseInterval * Double(index))
                guard let request = ArrivalNotifications.pulseRequest(identifier: identifier, content: content, at: date) else { continue }
                try? await notifications.add(request)
                if trip.arrival?.id != id {
                    notifications.removePendingNotificationRequests(withIdentifiers: [identifier])
                }
            }
            let returnArrival = ArrivalReceipt(id: UUID(), placeName: receipt.placeName, walkingDestination: receipt.walkingDestination)
            guard save({ $0.returnArrival = returnArrival }) else { return }
            do {
                try await notifications.add(ArrivalNotifications.returnRequest(
                    for: target, id: returnArrival.id, showsDestination: trip.showsDestination
                ))
                state = .returnScheduled
            } catch {
                state = .notified
            }
        }
    }

    func acknowledge(_ id: UUID) {
        if state == .returnScheduled || state == .restoring,
           ArrivalNotificationRoute.returnVisit(id).receipt(in: trip) != nil {
            notifications.removeDeliveredNotifications(withIdentifiers: [ArrivalNotifications.returnID])
            if presentedArrival?.id == id { presentedArrival = nil }
            return
        }
        guard trip.arrival?.id == id else { return }
        cancelArrivalNotifications(id)
        if save({ $0.arrival = nil }), presentedArrival?.id == id { presentedArrival = nil }
    }

    func setShowsDestination(_ value: Bool) {
        guard state != .restoring, state != .sendingNotification,
              trip.showsDestination != value, save({ $0.showsDestination = value }) else { return }
        activityDisplay.updatePlaceName(visiblePlaceName)
        let previousChange = notificationChanges
        notificationChanges = Task {
            await previousChange.value
            guard trip.showsDestination == value else { return }
            let requests = await notifications.pendingNotificationRequests()
            guard trip.showsDestination == value else { return }
            notifications.removeDeliveredNotifications(withIdentifiers: [ArrivalNotifications.returnID])
            if let arrival = trip.arrival {
                let ids = ArrivalNotifications.arrivalIDs(arrival.id)
                notifications.removeDeliveredNotifications(withIdentifiers: ids)
                let content = ArrivalNotifications.arrivalContent(receipt: arrival, showsDestination: value)
                for request in requests where ids.contains(request.identifier) {
                    guard trip.arrival?.id == arrival.id, trip.showsDestination == value else { break }
                    let date = (request.content.userInfo["fireAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
                        ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                    guard let date, let replacement = ArrivalNotifications.pulseRequest(
                        identifier: request.identifier, content: content, at: date
                    ) else { continue }
                    try? await notifications.add(replacement)
                    if trip.arrival?.id != arrival.id {
                        notifications.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    }
                }
                if !value { notifications.removeDeliveredNotifications(withIdentifiers: ids) }
            }
            if let id = trip.activeID {
                removeTrackingNotice(id: id)
                if state.tracksLocation || hasInterruptedTrip { await postTrackingNotice(id: id) }
            }
            if state == .returnScheduled, let target = selection?.target,
               let request = requests.first(where: { $0.identifier == ArrivalNotifications.returnID }),
               let id = ArrivalNotifications.tripID(in: request) {
                // 先取消旧文案，再更新仍然开启的回访提醒。
                cancelReturnReminder()
                do {
                    try await notifications.add(ArrivalNotifications.returnRequest(for: target, id: id, showsDestination: value))
                    if state != .returnScheduled { cancelReturnReminder() }
                } catch {
                    if state == .returnScheduled { state = .notified }
                }
            }
        }
    }

    func clearData() -> Bool {
        guard state != .restoring, state != .sendingNotification else { return false }
        let old = trip
        guard save({ $0 = TripData() }) else { return false }
        SharedPlaceInbox.clear()
        UserDefaults.standard.removeObject(forKey: AMapPlaceSearch.preferenceKey)
        if let id = old.activeID { removeTrackingNotice(id: id) }
        if let arrival = old.arrival { cancelArrivalNotifications(arrival.id) }
        cancelReturnReminder()
        endLocationUpdates()
        presentedArrival = nil
        pendingArrival = nil
        #if DEBUG
        diagnostics.clear()
        #endif
        state = .idle
        return true
    }

    @discardableResult
    private func save(_ change: (inout TripData) -> Void) -> Bool {
        var updated = trip
        change(&updated)
        do {
            try TripStore.save(updated)
            trip = updated
            return true
        } catch {
            if !state.tracksLocation { state = .failed("没能保存设置，请再试一次。") }
            return false
        }
    }

    func requestLocationPermission() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    func requestNotificationPermission() async throws {
        _ = try await notifications.requestAuthorization(options: [.alert, .sound])
    }

    func readNotificationAccess() async -> Access {
        let settings = await notifications.notificationSettings()
        if settings.authorizationStatus == .notDetermined { return .notRequested }
        return canShowNotifications(settings) ? .ready : .needsSettings
    }

    func scheduleTestReminder() async throws -> Bool {
        guard await readNotificationAccess() == .ready else { return false }
        try await notifications.add(ArrivalNotifications.testRequest())
        return true
    }

    private func updateLocationAccess() {
        let authorization = locationManager.authorizationStatus
        let access: Access = switch authorization {
        case .notDetermined: .notRequested
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.accuracyAuthorization == .fullAccuracy ? .ready : .needsSettings
        default: .needsSettings
        }
        if locationAccess != access { locationAccess = access }
    }

    private var canUsePreciseLocation: Bool { locationAccess == .ready }

    private func canShowNotifications(_ settings: UNNotificationSettings) -> Bool {
        settings.authorizationStatus == .authorized
            && settings.alertSetting == .enabled
            && settings.lockScreenSetting == .enabled
    }

    private func cancelArrivalNotifications(_ id: UUID) {
        let ids = ArrivalNotifications.arrivalIDs(id)
        notifications.removePendingNotificationRequests(withIdentifiers: ids)
        notifications.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func cancelReturnReminder() {
        let identifiers = [ArrivalNotifications.returnID]
        notifications.removePendingNotificationRequests(withIdentifiers: identifiers)
        notifications.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func restore() async {
        let requests = await notifications.pendingNotificationRequests()
        guard state == .restoring else { return }
        if trip.activeID != nil {
            cancelReturnReminder()
            state = .interrupted
            if let id = trip.activeID { await postTrackingNotice(id: id) }
            return
        }
        guard let target = selection?.target,
              let request = requests.first(where: { $0.identifier == ArrivalNotifications.returnID }),
              ArrivalNotifications.matchesReturnRequest(request, target: target),
              trip.returnArrival == nil || ArrivalNotifications.tripID(in: request) == trip.returnArrival?.id else {
            cancelReturnReminder()
            state = .idle
            return
        }
        let settings = await notifications.notificationSettings()
        guard state == .restoring else { return }
        if canUsePreciseLocation && canShowNotifications(settings) {
            state = .returnScheduled
        } else {
            cancelReturnReminder()
            state = .needsSettings("请确认通知和精确位置已开启，再开始守候。")
        }
    }

    func queueArrivalOpening(_ route: ArrivalNotificationRoute) {
        #if DEBUG
        Logger(subsystem: "ArrivalAlarm", category: "NotificationOpening").notice("收到到站通知打开请求")
        #endif
        if let id = route.receiptID, presentedArrival?.id == id { return }
        if pendingArrival != route { pendingArrival = route }
    }

    func takeArrivalOpening() -> ArrivalNotificationRoute? {
        #if DEBUG
        if pendingArrival != nil {
            Logger(subsystem: "ArrivalAlarm", category: "NotificationOpening").notice("首页已接收打开请求")
        }
        #endif
        defer { pendingArrival = nil }
        return pendingArrival
    }

    func receipt(for route: ArrivalNotificationRoute) -> ArrivalReceipt? {
        if case .returnVisit = route, state != .returnScheduled { return nil }
        return route.receipt(in: trip)
    }

    private func handleAction(_ action: String, requestID: String, tripID: UUID) {
        if requestID == ArrivalNotifications.returnID {
            if action == ArrivalNotifications.acknowledgeAction { acknowledge(tripID) }
            return
        }
        switch action {
        case ArrivalNotifications.stopAction:
            if trip.activeID == tripID { stop() }
        case ArrivalNotifications.resumeAction:
            if trip.activeID == tripID {
                if state == .restoring { state = .interrupted }
                start()
            }
        case ArrivalNotifications.acknowledgeAction:
            acknowledge(tripID)
        default:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        #if DEBUG
        Logger(subsystem: "ArrivalAlarm", category: "NotificationOpening").notice("通知代理收到用户响应")
        #endif
        let route = ArrivalNotifications.openingRoute(for: response)
        let action = response.actionIdentifier
        let request = response.notification.request
        let requestID = request.identifier
        let tripID = ArrivalNotifications.tripID(in: request)
        Task { @MainActor in
            // UIKit 可能在完成回调里更新场景快照，须在主线程交还控制权。
            defer { completionHandler() }
            if let route {
                queueArrivalOpening(route)
            } else if let tripID {
                handleAction(action, requestID: requestID, tripID: tripID)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == ArrivalNotifications.trackingCategory
            ? [.list] : [.banner, .list, .sound]
    }
}
