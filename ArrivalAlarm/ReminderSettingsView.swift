import SwiftUI

struct ReminderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var reminder: Reminder
    @State private var confirmingClear = false
    let onClear: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("通知中显示目的地", isOn: Binding(
                        get: { reminder.trip.showsDestination },
                        set: { value in reminder.setShowsDestination(value) }
                    ))
                } footer: {
                    Text("默认隐藏站名，锁屏上的提醒也会隐藏。")
                }
                Section {
                    Button("清空本机记录", role: .destructive) { confirmingClear = true }
                } footer: {
                    Text("最近地点、提醒范围和守候任务保存在本机。搜索地点时，Apple 地图会收到关键词和附近搜索区域。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("清空本机记录？", isPresented: $confirmingClear) {
                Button("清空", role: .destructive) {
                    if reminder.clearData() {
                        onClear()
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除最近地点和上次设置，并停止当前及下次到站提醒。")
            }
        }
    }
}
