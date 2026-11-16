#if DEBUG
import SwiftUI
import UIKit

struct LocationDiagnosticsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let report: LocationDiagnostics.Report

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: report.icon)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                        Text(report.title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(report.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let note = report.note {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                        if report.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                            Button("打开设置") { openURL(url) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .tint(ReminderPalette.actionBlue)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(controlSurface)

                if !report.rows.isEmpty {
                    Section("最近一轮") {
                        ForEach(report.rows, id: \.label) { row in
                            LabeledContent(row.label) {
                                Text(row.value)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .listRowBackground(controlSurface)

                    Section {
                        DisclosureGroup("原始记录") {
                            Text(verbatim: report.raw)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                    }
                    .listRowBackground(controlSurface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ReminderPalette.surface(in: colorScheme).ignoresSafeArea())
            .tint(accent)
            .navigationTitle("定位诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if !report.rows.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: report.raw) {
                            Label("分享原始记录", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private var accent: Color { ReminderPalette.accent(in: colorScheme) }
    private var controlSurface: Color { ReminderPalette.controlSurface(in: colorScheme) }
}
#endif
