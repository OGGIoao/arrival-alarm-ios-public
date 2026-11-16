import AppIntents

struct ReminderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartLastReminderIntent(),
            phrases: ["用\(.applicationName)开始上次守候"],
            shortTitle: "开始上次守候",
            systemImageName: "tram.fill"
        )
    }
}
