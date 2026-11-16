import SwiftUI
import UIKit

@main
struct ArrivalAlarmApp: App {
    @UIApplicationDelegateAdaptor(ArrivalAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup { ReminderView(reminder: delegate.reminder) }
    }
}

@MainActor
private final class ArrivalAppDelegate: NSObject, UIApplicationDelegate {
    let reminder = Reminder()
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
    @State private var replacement: StationSelection?
    @State private var showingReplacement = false
    #if DEBUG
    @State private var showingDiagnostics = false
    #endif

    private let contentWidth: CGFloat = 440
    private let gutter: CGFloat = 24
    private let heroBackground = Color(red: 0.035, green: 0.090, blue: 0.220)
    private let onHero = Color(red: 0.79, green: 0.87, blue: 1)

    private struct SearchPresentation: Identifiable {
        let id = UUID()
        var input = ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                stationCard
                if let selection {
                    configuration(radius: selection.target.radius)
                } else if !reminder.trip.recent.isEmpty {
                    Button("最近地点", systemImage: "clock") { search = SearchPresentation() }
                        .frame(minHeight: 44)
                }
                if let receipt = reminder.trip.arrival {
                    Button("查看到站提醒", systemImage: "bell") { reminder.presentedArrival = receipt }
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: contentWidth)
            .padding(.horizontal, gutter)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
                .frame(maxWidth: contentWidth)
                .padding(.horizontal, gutter)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(surface)
        }
        .background(surface.ignoresSafeArea())
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                reminder.sceneBecameActive()
                startLastReminderIfRequested()
                if let text = SharedPlaceInbox.take() { offerImport(text) }
            }
        }
        .onChange(of: reminder.state) { _, _ in
            startLastReminderIfRequested()
            showQueuedImport()
        }
        .onChange(of: lastReminderRequest.isPending, initial: true) { _, _ in
            startLastReminderIfRequested()
        }
        .onOpenURL { url in
            if PlaceInput.isArrivalLink(url) { offerImport(url.absoluteString) }
        }
        .sheet(item: $search, onDismiss: {
            showingReplacement = replacement != nil
            showQueuedImport()
        }) { presentation in
            StationSearchView(
                initialRadius: selection?.target.radius ?? .standard,
                recent: reminder.trip.recent,
                nearby: reminder.nearbyCoordinate,
                initialInput: presentation.input,
                onConfirm: confirmSelection
            )
        }
        .sheet(isPresented: $showingRange, onDismiss: showQueuedImport) {
            if let selection {
                NavigationStack {
                    StationRangeView(selection: selection, isEditing: true) { selected in
                        reminder.select(selected)
                        showingRange = false
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: showQueuedImport) {
            ReminderSettingsView(reminder: reminder) { queuedImport = nil }
        }
        .sheet(isPresented: $showingReminderCheck, onDismiss: showQueuedImport) {
            ReminderCheckView(reminder: reminder)
        }
        .sheet(item: $reminder.presentedArrival, onDismiss: showQueuedImport) { receipt in
            ArrivalDetailsView(receipt: receipt) { reminder.acknowledge(receipt.id) }
        }
        .alert("更换守候目的地？", isPresented: $showingReplacement, presenting: replacement) { selected in
            Button("停止并更换", role: .destructive) {
                reminder.stop()
                reminder.select(selected)
                replacement = nil
                showQueuedImport()
            }
            Button("取消", role: .cancel) {
                replacement = nil
                showQueuedImport()
            }
        } message: { selected in
            Text("当前守候会结束。确认后可对\(selected.target.station.name)开始守候。")
        }
        #if DEBUG
        .sheet(isPresented: $showingDiagnostics, onDismiss: showQueuedImport) {
            LocationDiagnosticsView(report: reminder.diagnostics.report())
        }
        #endif
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
        if reminder.state.tracksLocation || reminder.hasInterruptedTrip {
            replacement = selected
        } else {
            reminder.select(selected)
        }
    }

    private func offerImport(_ text: String) {
        queuedImport = text
        showQueuedImport()
    }

    private func showQueuedImport() {
        guard let text = queuedImport, search == nil, !showingSettings, !showingReminderCheck, !showingRange,
              reminder.presentedArrival == nil, replacement == nil,
              reminder.state != .restoring, reminder.state != .sendingNotification else { return }
        #if DEBUG
        guard !showingDiagnostics else { return }
        #endif
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tram.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(ReminderPalette.actionBlue, in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            Text("别坐过站").font(.headline)
            Spacer()
            Menu {
                Button("检查提醒", systemImage: "checkmark.shield") { showingReminderCheck = true }
                Button("设置", systemImage: "gearshape") { showingSettings = true }
                #if DEBUG
                Button("定位诊断", systemImage: "waveform.path") {
                    showingDiagnostics = true
                }
                #endif
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(controlSurface, in: Circle())
                    .overlay(Circle().strokeBorder(accent.opacity(0.18)))
            }
            .accessibilityLabel("更多")
            .tint(ink)
        }
        .foregroundStyle(ink)
        .frame(minHeight: 48)
    }

    private var stationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            destinationHeading
            if selection != nil {
                reminderStatus
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .padding(.bottom, 154)
        .frame(minHeight: 354, alignment: .topLeading)
        .background(alignment: .bottom) {
            GeometryReader { geometry in
                Image("SubwayHero")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width)
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .background(heroBackground)
        .clipShape(.rect(cornerRadius: 28))
    }

    private var destinationHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selection?.target.station.name ?? "你想去哪儿？")
                .font(.system(size: stationTitleSize, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(destinationDescription)
                .font(.subheadline)
                .foregroundStyle(onHero)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destinationDescription: String {
        guard let selection else { return "输入地点，查找附近的下车站。" }
        return selection.separateDestination.map { "目的地  \($0.name)" }
            ?? selection.target.station.address ?? "提醒地点"
    }

    private var reminderStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(status.title, systemImage: status.icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(reminder.state == .monitoring ? .white : onHero)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(onHero.opacity(reminder.state == .monitoring ? 0.23 : 0.13), in: Capsule())
            if let message = status.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(onHero)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if needsSettings, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button("打开设置") { openURL(settingsURL) }
                    .frame(minHeight: 44, alignment: .leading)
                    .tint(onHero)
            }
            if reminder.hasInterruptedTrip, reminder.state != .restoring {
                Button("结束这次守候") { reminder.stop() }
                    .frame(minHeight: 44, alignment: .leading)
                    .tint(onHero)
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
                    search = SearchPresentation()
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
            if reminder.state.canStop {
                reminder.stop()
            } else if selection != nil {
                reminder.start()
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
        if reminder.state.canStop {
            mainButton
                .buttonStyle(.bordered)
                .tint(accent)
        } else {
            mainButton
                .buttonStyle(.borderedProminent)
                .tint(ReminderPalette.actionBlue)
        }
    }

    private var mainButtonTitle: String {
        if reminder.state == .restoring { return "正在读取上次设置" }
        if selection == nil { return "搜索目的地" }
        if reminder.state == .sendingNotification { return "正在发送提醒" }
        if reminder.state == .returnScheduled { return "停止提醒" }
        if reminder.hasInterruptedTrip { return "继续守候" }
        return reminder.state.canStop ? "停止守候" : "开始守候"
    }

    private var needsSettings: Bool {
        if case .needsSettings = reminder.state { return true }
        return false
    }

    private var configurationLocked: Bool {
        reminder.state.locksSelection
    }

    private var status: (title: String, icon: String, message: String?) {
        switch reminder.state {
        case .restoring:
            ("正在读取上次设置", "clock", nil)
        case .idle:
            ("尚未开始", "bell.slash", "开始后，下次到这站也会提醒。")
        case .checkingNotifications, .checkingLocation, .requestingLocation:
            ("检查权限", "lock.shield", nil)
        case .waitingForLocation:
            ("等待定位", "location", "正在等待足够准确的位置。")
        case .monitoring:
            ("守候中", "bell.badge.fill", reminder.distanceLabel.map { "距离提醒地点约\($0) · 可以锁屏" } ?? "可以锁屏")
        case .recovering:
            ("正在重新定位", "location.slash", "暂时没有可用的位置。")
        case .interrupted:
            ("守候已中断", "pause.circle", "点「继续守候」恢复上次任务。")
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
