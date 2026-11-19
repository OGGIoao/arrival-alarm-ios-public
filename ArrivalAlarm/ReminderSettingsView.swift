import SwiftUI

struct ReminderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var reminder: Reminder
    @State private var confirmingClear = false
    @State private var checkingReminder = false
    #if DEBUG
    @State private var showingDiagnostics = false
    #endif
    let onClear: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("提醒与帮助") {
                    Button("试一下提醒", systemImage: "bell.badge") { checkingReminder = true }
                    #if DEBUG
                    Button("定位诊断（调试版）", systemImage: "waveform.path") { showingDiagnostics = true }
                    #endif
                }
                Section {
                    Toggle("锁屏显示站名", isOn: Binding(
                        get: { reminder.trip.showsDestination },
                        set: { value in reminder.setShowsDestination(value) }
                    ))
                } header: {
                    Text("记录与隐私")
                } footer: {
                    Text("默认隐藏站名，锁屏上的提醒也会隐藏。")
                }
                Section {
                    Button("清空本机记录", role: .destructive) { confirmingClear = true }
                } footer: {
                    Text("常用地点、最近地点、提醒范围和守候任务保存在本机。搜索地点时，Apple 地图会收到关键词和附近搜索区域。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $checkingReminder) { ReminderCheckView(reminder: reminder) }
            #if DEBUG
            .sheet(isPresented: $showingDiagnostics) {
                LocationDiagnosticsView(report: reminder.diagnostics.report())
            }
            #endif
            .alert("清空本机记录？", isPresented: $confirmingClear) {
                Button("清空", role: .destructive) {
                    if reminder.clearData() {
                        onClear()
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会清除常用地点、最近地点和上次设置，并停止当前及下次到站提醒。")
            }
        }
    }
}
