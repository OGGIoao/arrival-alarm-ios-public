import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ArrivalWidgets: WidgetBundle {
    var body: some Widget {
        ReminderActivityWidget()
        StartLastReminderControl()
    }
}

struct StartLastReminderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "arrival-alarm.start-last-reminder") {
            ControlWidgetButton(action: StartLastReminderIntent()) {
                Label("开始上次守候", systemImage: "tram.fill")
            }
        }
        .displayName("开始上次守候")
        .description("使用上次的地点和提醒范围。")
    }
}

struct ReminderActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReminderActivityAttributes.self) { context in
            ReminderActivityCard(context: context)
        } dynamicIsland: { context in
            let phase = context.isStale ? .positionUnavailable : context.state.phase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    ReminderActivityCard(context: context)
                }
            } compactLeading: {
                Image(systemName: phase.icon)
                    .foregroundStyle(.cyan)
                    .accessibilityLabel("到站提醒")
            } compactTrailing: {
                Text(phase.compactTitle).font(.caption2)
            } minimal: {
                Image(systemName: phase.icon)
                    .foregroundStyle(.cyan)
                    .accessibilityLabel(phase.title)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct ReminderActivityCard: View {
    let context: ActivityViewContext<ReminderActivityAttributes>
    @Environment(\.activityFamily) private var family

    private var phase: ReminderActivityAttributes.Phase {
        context.isStale ? .positionUnavailable : context.state.phase
    }

    var body: some View {
        HStack(alignment: .top, spacing: family == .small ? 8 : 12) {
            Image(systemName: phase.icon)
                .font(family == .small ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.cyan)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if family == .small {
                    Text(context.state.placeName ?? "到站提醒")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .privacySensitive(context.state.placeName != nil)
                    Text(phase.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(phase == .positionUnavailable ? .orange : .secondary)
                } else {
                    Text(phase.title).font(.headline)
                }
                if let distance = context.state.distance, phase == .monitoring {
                    Text("直线约\(distance)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let placeName = context.state.placeName, family != .small {
                    Text(placeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .privacySensitive()
                }
            }
            .lineLimit(family == .small ? 1 : 2)
            Spacer(minLength: 0)
        }
        .padding(family == .small ? 8 : 14)
        .accessibilityElement(children: .combine)
    }
}
