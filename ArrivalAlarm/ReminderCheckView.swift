import SwiftUI
import UIKit

struct ReminderCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var reminder: Reminder
    @State private var notificationAccess: Reminder.Access?
    @State private var isRequestingPermission = false
    @State private var isSubmitting = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    accessLabel("精确位置", access: reminder.locationAccess)
                    switch reminder.locationAccess {
                    case .notRequested:
                        Button("允许定位") { reminder.requestLocationPermission() }
                    case .needsSettings:
                        Button("打开定位设置") { openSettings(UIApplication.openSettingsURLString) }
                    case .ready:
                        EmptyView()
                    }
                } footer: {
                    if reminder.locationAccess != .ready {
                        Text("允许在使用 App 期间访问位置，并开启「精确位置」。")
                    }
                }

                Section {
                    accessLabel("锁屏通知", access: notificationAccess)
                    switch notificationAccess {
                    case .notRequested:
                        Button("允许通知", action: requestNotifications)
                            .disabled(isRequestingPermission)
                    case .needsSettings:
                        Button("打开通知设置") { openSettings(UIApplication.openNotificationSettingsURLString) }
                    case .ready, nil:
                        EmptyView()
                    }
                } footer: {
                    if notificationAccess == .needsSettings {
                        Text("允许通知，并勾选「锁定屏幕」。想听见提示时也请开启「声音」。")
                    }
                }

                Section {
                    Button("发送测试提醒", action: sendTestReminder)
                        .disabled(notificationAccess != .ready || isSubmitting)
                } footer: {
                    Text(result ?? "点一下，然后锁屏。测试提醒将在 \(ArrivalNotifications.testDelay) 秒后发出。")
                }
            }
            .navigationTitle("检查提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: scenePhase) {
                if scenePhase == .active {
                    let access = await reminder.readNotificationAccess()
                    if !Task.isCancelled { notificationAccess = access }
                }
            }
        }
    }

    private func accessLabel(_ label: String, access: Reminder.Access?) -> some View {
        let status: String = switch access {
        case .ready: "已开启"
        case .notRequested: "待授权"
        case .needsSettings: "需设置"
        case nil: "检查中"
        }
        return LabeledContent(label, value: status)
    }

    private func openSettings(_ address: String) {
        if let url = URL(string: address) { openURL(url) }
    }

    private func requestNotifications() {
        isRequestingPermission = true
        Task {
            defer { isRequestingPermission = false }
            do {
                try await reminder.requestNotificationPermission()
                notificationAccess = await reminder.readNotificationAccess()
            } catch {
                result = "没能请求通知权限，请再试一次。"
            }
        }
    }

    private func sendTestReminder() {
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                if try await reminder.scheduleTestReminder() {
                    result = "已安排测试提醒，现在可以锁屏。"
                } else {
                    notificationAccess = await reminder.readNotificationAccess()
                    result = "请先开启锁屏通知，再试一次。"
                }
            } catch {
                result = "没能发送测试提醒，请再试一次。"
            }
        }
    }
}
