import MapKit
import SwiftUI
import UIKit

struct ArrivalDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showingMaps = false
    @State private var showingOpenError = false

    let receipt: ArrivalReceipt
    let onAcknowledge: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("快到了", systemImage: "bell.badge.fill")
            } description: {
                VStack(spacing: 4) {
                    Text(receipt.placeName)
                    if let destination = receipt.walkingDestination {
                        Text("目的地  \(destination.name)")
                    }
                }
            } actions: {
                VStack(spacing: 12) {
                    Button("我已到达", action: onAcknowledge)
                        .buttonStyle(.borderedProminent)
                    if let destination = receipt.walkingDestination {
                        Button("步行到目的地", systemImage: "figure.walk") {
                            if availableMaps(to: destination).isEmpty {
                                openAppleMaps(to: destination)
                            } else {
                                showingMaps = true
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .confirmationDialog("选择地图 App", isPresented: $showingMaps, titleVisibility: .visible) {
                if let destination = receipt.walkingDestination {
                    Button("Apple 地图") { openAppleMaps(to: destination) }
                    ForEach(availableMaps(to: destination), id: \.self) { map in
                        Button(map.name) {
                            if let url = map.route(to: destination) {
                                openURL(url, completion: finishOpeningMap)
                            }
                        }
                    }
                }
            }
            .alert("未能打开地图", isPresented: $showingOpenError) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("请再试一次，或选择其他已安装的地图。")
            }
        }
    }

    private func availableMaps(to destination: ArrivalDestination) -> [WalkingMap] {
        WalkingMap.allCases.filter { map in
            guard let url = map.route(to: destination) else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    private func openAppleMaps(to destination: ArrivalDestination) {
        let item = MKMapItem(location: destination.location, address: nil)
        item.name = destination.name
        finishOpeningMap(item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]))
    }

    private func finishOpeningMap(_ accepted: Bool) {
        if accepted {
            onAcknowledge()
        } else {
            showingOpenError = true
        }
    }
}
