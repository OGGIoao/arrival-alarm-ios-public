import ActivityKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct ArrivalAlarmApp: App {
    @UIApplicationDelegateAdaptor(ArrivalAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { ReminderView(reminder: delegate.reminder) }
    }
}

@MainActor
private final class ArrivalAppDelegate: NSObject, UIApplicationDelegate {
    static let sharedReminder = Reminder()
    var reminder: Reminder { Self.sharedReminder }

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        reminder.registerNotificationDelegate()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication {
            configuration.delegateClass = ArrivalSceneDelegate.self
        }
        return configuration
    }
}

@MainActor
private final class ArrivalSceneDelegate: NSObject, UIWindowSceneDelegate {
    private static let startLastReminderType = "start-last-reminder"

    static func updateQuickActions(hasSelection: Bool) {
        UIApplication.shared.shortcutItems = hasSelection ? [
            UIApplicationShortcutItem(
                type: startLastReminderType,
                localizedTitle: String(localized: StartLastReminderIntent.title),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "tram.fill"),
                userInfo: nil
            )
        ] : []
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        if let response = options.notificationResponse, let route = ArrivalNotifications.openingRoute(for: response) {
            ArrivalAppDelegate.sharedReminder.queueArrivalOpening(route)
        }
        if let item = options.shortcutItem { _ = handle(item) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        handle(shortcutItem)
    }

    private func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == Self.startLastReminderType else { return false }
        LastReminderRequest.shared.isPending = true
        return true
    }
}

enum ReminderPalette {
    static let actionBlue = Color(red: 0.12, green: 0.30, blue: 0.75)

    static func accent(in scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.63, green: 0.77, blue: 1) : actionBlue
    }

    static func surface(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.045, green: 0.075, blue: 0.145)
            : Color(red: 0.92, green: 0.95, blue: 0.99)
    }

    static func controlSurface(in scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.085, green: 0.135, blue: 0.235)
            : Color(red: 0.97, green: 0.98, blue: 1)
    }
}

private struct ReminderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var stationTitleSize = 39.0
    @ObservedObject var reminder: Reminder
    @ObservedObject private var lastReminderRequest = LastReminderRequest.shared
    @State private var search: SearchPresentation?
    @State private var queuedImport: String?
    @State private var showingSettings = false
    @State private var showingReminderCheck = false
    @State private var showingRange = false
    @State private var showingTrip = false
    @State private var queuedTripDetails = false
    @State private var queuedSearch = false
    @State private var viewportHeight: CGFloat = 740
    @State private var replacement: StationSelection?
    @State private var showingReplacement = false
    @State private var showingExpiredArrival = false

    private let contentWidth: CGFloat = 440
    private let gutter: CGFloat = 20
    private let heroBackground = Color(red: 0.035, green: 0.090, blue: 0.220)

    private struct SearchPresentation: Identifiable {
        let id = UUID()
        var input = ""
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 24) {
                    homeHero(topInset: viewport.safeAreaInsets.top)
                    VStack(alignment: .leading, spacing: 24) {
                        if showsCurrentReminder { currentReminder }
                        if !recentSelections.isEmpty { recentPlaces }
                    }
                    .frame(maxWidth: contentWidth)
                    .padding(.horizontal, gutter)
                }
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(edges: .top)
        }
        .background(surface.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                reminder.sceneBecameActive()
                if let text = SharedPlaceInbox.take() { offerImport(text) }
                showQueuedPresentation()
            }
        }
        .onChange(of: reminder.state) { _, _ in
            showQueuedPresentation()
        }
        .onChange(of: reminder.pendingArrival, initial: true) { _, route in
            if route != nil {
                showingRange = false
                showingTrip = false
            }
            showQueuedPresentation()
        }
        .onChange(of: lastReminderRequest.isPending, initial: true) { _, _ in
            showQueuedPresentation()
        }
        .onChange(of: selection != nil, initial: true) { _, hasSelection in
            ArrivalSceneDelegate.updateQuickActions(hasSelection: hasSelection)
        }
        .onOpenURL { url in
            if PlaceInput.isArrivalLink(url) { offerImport(url.absoluteString) }
        }
        .sheet(item: $search, onDismiss: {
            Task { @MainActor in
                await Task.yield()
                showingReplacement = replacement != nil
                showQueuedPresentation()
            }
        }) { presentation in
            StationSearchView(
                initialRadius: selection?.target.radius ?? .standard,
                frequent: reminder.trip.frequentPlaces(),
                recent: reminder.trip.recent,
                nearby: reminder.nearbyCoordinate,
                initialInput: presentation.input,
                onConfirm: confirmSelection
            )
        }
        .sheet(isPresented: $showingTrip, onDismiss: showQueuedPresentation) { tripDetails }
        .sheet(isPresented: $showingSettings, onDismiss: showQueuedPresentation) {
            ReminderSettingsView(reminder: reminder) { queuedImport = nil }
        }
        .sheet(isPresented: $showingReminderCheck, onDismiss: showQueuedPresentation) {
            ReminderCheckView(reminder: reminder)
        }
        .sheet(item: $reminder.presentedArrival, onDismiss: showQueuedPresentation) { receipt in
            ArrivalDetailsView(receipt: receipt) { reminder.acknowledge(receipt.id) }
        }
        .alert("更换守候目的地？", isPresented: $showingReplacement, presenting: replacement) { selected in
            Button("停止并更换", role: .destructive) {
                reminder.stop()
                reminder.select(selected)
                replacement = nil
                queuedTripDetails = true
            }
            Button("取消", role: .cancel) {
                replacement = nil
                showQueuedPresentation()
            }
        } message: { selected in
            Text("当前守候会结束。确认后可对\(selected.target.station.name)开始守候。")
        }
        .onChange(of: showingReplacement) { _, isShowing in
            if !isShowing { showQueuedPresentation() }
        }
        .alert("这条到站提醒已失效", isPresented: $showingExpiredArrival) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("可以在首页查看当前守候。")
        }
        .onChange(of: showingExpiredArrival) { _, isShowing in
            if !isShowing { showQueuedPresentation() }
        }
    }

    private func startLastReminderIfRequested() {
        guard lastReminderRequest.isPending, scenePhase == .active,
              reminder.state != .restoring, reminder.state != .sendingNotification else { return }
        lastReminderRequest.isPending = false
        if selection != nil {
            reminder.startLastReminder()
        } else if search == nil {
            search = SearchPresentation()
        }
    }

    private func confirmSelection(_ selected: StationSelection) {
        if selected.target.station.id == selection?.target.station.id,
           selected.target.radius == selection?.target.radius,
           selected.id == selection?.id {
            queuedTripDetails = true
        } else if canStopCurrentTrip || reminder.hasInterruptedTrip {
            replacement = selected
        } else {
            reminder.select(selected)
            queuedTripDetails = true
        }
    }

    private func offerImport(_ text: String) {
        queuedImport = text
        showQueuedPresentation()
    }

    private func showQueuedPresentation() {
        guard scenePhase == .active, search == nil, !showingSettings, !showingReminderCheck, !showingRange,
              !showingTrip, !showingReplacement,
              reminder.presentedArrival == nil, replacement == nil, !showingExpiredArrival,
              reminder.state != .restoring, reminder.state != .sendingNotification else { return }
        if let route = reminder.takeArrivalOpening() {
            if let receipt = reminder.receipt(for: route) {
                reminder.presentedArrival = receipt
            } else {
                showingExpiredArrival = true
            }
            return
        }
        if queuedTripDetails {
            queuedTripDetails = false
            showingTrip = true
            return
        }
        if queuedSearch {
            queuedSearch = false
            search = SearchPresentation()
            return
        }
        startLastReminderIfRequested()
        guard let text = queuedImport, search == nil else { return }
        search = SearchPresentation(input: text)
        queuedImport = nil
    }

    private var selection: StationSelection? { reminder.selection }
    private var surface: Color { ReminderPalette.surface(in: colorScheme) }
    private var controlSurface: Color { ReminderPalette.controlSurface(in: colorScheme) }
    private var accent: Color { ReminderPalette.accent(in: colorScheme) }

    private var ink: Color {
        colorScheme == .dark ? Color(red: 0.88, green: 0.93, blue: 1) : heroBackground
    }

    private var recentSelections: [StationSelection] {
        if reminder.trip.recent.isEmpty, let selection { return [selection] }
        return reminder.trip.recent
    }

    private var isFirstUse: Bool { recentSelections.isEmpty && selection == nil }
    private var heroSpacing: CGFloat { isFirstUse ? max(180, viewportHeight * 0.5 - 80) : 76 }

    private var showsCurrentReminder: Bool {
        selection != nil && (reminder.state != .idle || reminder.trip.activeID != nil || reminder.trip.arrival != nil)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("别坐过站")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(ink)
    }

    private func homeHero(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Color.clear.frame(height: heroSpacing)
                .accessibilityHidden(true)
            if isFirstUse {
                Text("这次想去哪儿？")
                    .font(.title.bold())
                    .foregroundStyle(ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Button {
                search = SearchPresentation()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.medium))
                    Text("输入目的地或地铁站")
                        .font(.body)
                        .foregroundStyle(colorScheme == .dark ? ink : Color(red: 0.32, green: 0.39, blue: 0.52))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(controlSurface, in: .rect(cornerRadius: 30))
                .shadow(color: ReminderPalette.actionBlue.opacity(0.12), radius: 12, y: 5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索目的地或地铁站")
            if isFirstUse {
                Text("选好下车站，接近时提醒你。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: contentWidth)
        .padding(.horizontal, gutter)
        .padding(.top, topInset + 4)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            GeometryReader { geometry in
                Image("SubwayStation")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: (isFirstUse ? heroSpacing + 140 : 228) + topInset, alignment: .bottomLeading)
                    .clipped()
                    .overlay {
                        if colorScheme == .dark { Color.black.opacity(0.58) }
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [surface.opacity(0), surface], startPoint: .top, endPoint: .bottom)
                            .frame(height: 100)
                    }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }

    private var currentReminder: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in currentReminderCard }
    }

    private var currentReminderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showingTrip = true
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reminder.state == .returnScheduled ? "下次到访提醒" : "当前提醒")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                    Text(selection?.target.station.name ?? "提醒地点")
                        .font(.title.bold())
                        .foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let destination = selection?.separateDestination {
                        Text("目的地：\(destination.name)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Label(status.title, systemImage: status.icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accent)
                    if let message = status.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("查看本次提醒")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(ReminderPalette.actionBlue, in: .rect(cornerRadius: 14))
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if needsSettings {
                Button("检查提醒设置", systemImage: "exclamationmark.circle") {
                    showingReminderCheck = true
                }
                .frame(minHeight: 44)
                .buttonStyle(.bordered)
                .tint(accent)
            }
        }
        .padding(20)
        .background(accent.opacity(0.085), in: .rect(cornerRadius: 20))
    }

    private var recentPlaces: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近选择的地点")
                .font(.title3.bold())
                .foregroundStyle(ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(recentSelections.prefix(3).enumerated()), id: \.element.id) { index, saved in
                    if index > 0 { Divider() }
                    Button {
                        confirmSelection(saved)
                        showingReplacement = replacement != nil
                        showQueuedPresentation()
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                recentPlaceLabel(saved)
                                Spacer(minLength: 8)
                                recentPlaceAction
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                recentPlaceLabel(saved)
                                recentPlaceAction
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 16)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(reminder.state == .restoring || reminder.state == .sendingNotification)
                }
                Divider()
                Button {
                    search = SearchPresentation()
                } label: {
                    HStack(spacing: 6) {
                        Text("查看全部")
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(.rect)
                }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .tint(accent)
            }
            .padding(.horizontal, 16)
            .background(controlSurface, in: .rect(cornerRadius: 20))
        }
    }

    private var recentPlaceAction: some View {
        Text("选这里")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ReminderPalette.actionBlue, in: Capsule())
    }

    private func recentPlaceLabel(_ saved: StationSelection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(saved.destination.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                if reminder.trip.frequentPlaces().contains(where: { $0.matchesDestination(saved) }) {
                    Text("常用").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(saved.remindsAtDestination ? "提醒地点" : "下车站")：\(saved.target.station.name)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tripDetails: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let selection {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selection.remindsAtDestination ? "提醒地点" : "下车站")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(selection.target.station.name)
                                .font(.system(size: stationTitleSize, weight: .bold))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            if let destination = selection.separateDestination {
                                Text("目的地：\(destination.name)").foregroundStyle(.secondary)
                            }
                        }
                        reminderStatus
                        configuration(radius: selection.target.radius)
                    }
                    if let receipt = reminder.trip.arrival {
                        Button("查看到站提醒", systemImage: "bell") {
                            queuedTripDetails = false
                            showingTrip = false
                            reminder.queueArrivalOpening(.trip(receipt.id))
                        }
                        .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .padding(gutter)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                footer
                    .frame(maxWidth: contentWidth)
                    .padding(.horizontal, gutter)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(surface)
            }
            .background(surface)
            .foregroundStyle(ink)
            .navigationTitle("本次提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingTrip = false }
                }
            }
            .sheet(isPresented: $showingRange) {
                if let selection {
                    NavigationStack {
                        StationRangeView(selection: selection, isEditing: true) { selected in
                            reminder.select(selected)
                            showingRange = false
                        }
                    }
                }
            }
        }
    }

    private var reminderStatus: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in reminderStatusContent }
    }

    private var reminderStatusContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(status.title, systemImage: status.icon)
                .font(.headline)
                .foregroundStyle(accent)
            if let message = status.message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            if reminder.state == .returnScheduled {
                Button("关闭下次提醒") { reminder.stop() }
                    .frame(minHeight: 44)
                    .tint(accent)
            }
            if needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("打开设置") { openURL(url) }
                    .frame(minHeight: 44)
                    .tint(accent)
            }
            if reminder.hasInterruptedTrip, reminder.state != .restoring {
                Button("结束本次提醒") { reminder.stop() }
                    .frame(minHeight: 44)
                    .tint(accent)
            }
        }
    }

    private func configuration(radius: ReminderRadius) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if configurationLocked {
                LabeledContent("提醒范围") {
                    Text(radius.label)
                        .foregroundStyle(accent)
                }
                .frame(minHeight: 54)
            } else {
                Button {
                    showingRange = true
                } label: {
                    HStack(spacing: 8) {
                        Text("提醒范围")
                        Spacer()
                        Text(radius.label)
                            .foregroundStyle(accent)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 54)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("提醒范围")
                .accessibilityValue(radius.label)

            }
            if !configurationLocked || reminder.state.tracksLocation {
                Rectangle()
                    .fill(accent.opacity(0.18))
                    .frame(height: 1)
                    .accessibilityHidden(true)
                Button {
                    queuedSearch = true
                    showingTrip = false
                } label: {
                    HStack {
                        Label("更换目的地", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 48)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 16)
        .foregroundStyle(ink)
        .background(controlSurface, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).strokeBorder(accent.opacity(0.18))
                .allowsHitTesting(false)
        }
    }

    private var mainButton: some View {
        Button {
            if canStopCurrentTrip {
                reminder.stop()
                showingTrip = false
            } else if selection != nil {
                reminder.startLastReminder()
            } else {
                search = SearchPresentation()
            }
        } label: {
            Text(mainButtonTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .controlSize(.large)
        .disabled(reminder.state == .sendingNotification || reminder.state == .restoring)
    }

    @ViewBuilder
    private var footer: some View {
        if canStopCurrentTrip {
            mainButton
                .buttonStyle(.bordered)
                .tint(accent)
        } else {
            mainButton
                .buttonStyle(.borderedProminent)
                .tint(ReminderPalette.actionBlue)
                .foregroundStyle(.white)
        }
    }

    private var canStopCurrentTrip: Bool {
        reminder.state.canStop && reminder.state != .returnScheduled
    }

    private var mainButtonTitle: String {
        if reminder.state == .restoring { return "正在读取上次设置" }
        if selection == nil { return "搜索目的地" }
        if reminder.state == .sendingNotification { return "正在发送提醒" }
        if reminder.state == .returnScheduled { return "开始本次提醒" }
        if reminder.hasInterruptedTrip { return "继续本次提醒" }
        return canStopCurrentTrip ? "结束本次提醒" : "开始本次提醒"
    }

    private var needsSettings: Bool {
        if case .needsSettings = reminder.state { return true }
        return false
    }

    private var configurationLocked: Bool {
        reminder.state.locksSelection
    }

    private var status: (title: String, icon: String, message: String?) {
        if reminder.state == .monitoring,
           let staleDate = Activity<ReminderActivityAttributes>.activities.first?.content.staleDate,
           staleDate <= .now {
            return ("位置暂未更新", "location.slash", "正在等待新位置，请留意车厢报站。")
        }
        return switch reminder.state {
        case .restoring:
            ("正在读取上次设置", "clock", nil)
        case .idle:
            ("还没开始提醒", "bell.slash", "开始后，下次到这站也会提醒。")
        case .checkingNotifications, .checkingLocation, .requestingLocation:
            ("检查权限", "lock.shield", nil)
        case .waitingForLocation:
            ("等待定位", "location", "正在等待足够准确的位置。")
        case .monitoring:
            ("到站提醒已开启", "bell.badge.fill", reminder.distanceLabel.map { "距离提醒地点约\($0) · 可以锁屏" } ?? "可以锁屏")
        case .recovering:
            ("位置暂未更新", "location.slash", "正在重新获取位置，请留意车厢报站。")
        case .interrupted:
            ("提醒已中断", "pause.circle", "进入本次提醒，点「继续本次提醒」恢复任务。")
        case .sendingNotification:
            ("正在发送提醒", "bell", nil)
        case .notified:
            ("已发送本次提醒", "checkmark.circle", "下次提醒没能开启，可以再次开始守候。")
        case .returnScheduled:
            ("下次还会提醒", "bell.badge.fill", "离开后再次进入这个范围，iPhone 会提醒你。")
        case .needsSettings(let message):
            ("需要权限", "exclamationmark.circle", message)
        case .failed(let message):
            ("守候未完成", "exclamationmark.circle", message)
        }
    }
}
