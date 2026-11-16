import MapKit
import SwiftUI

struct StationRangeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var station: ArrivalDestination
    @State private var radius: ReminderRadius
    @State private var camera = MapCameraPosition.automatic
    @State private var visibleBounds: MKMapRect?
    @State private var selectedMarker: UUID?
    @State private var showingStations = false
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private let selection: StationSelection
    private let isEditing: Bool
    private let importNote: String?
    private let onConfirm: (StationSelection) -> Void

    init(
        selection: StationSelection,
        isEditing: Bool = false,
        importNote: String? = nil,
        onConfirm: @escaping (StationSelection) -> Void
    ) {
        self.selection = selection
        self.isEditing = isEditing
        self.importNote = importNote
        self.onConfirm = onConfirm
        _station = State(initialValue: selection.target.station)
        _radius = State(initialValue: selection.target.radius)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stationHeading
                rangeMap
                if showingStations {
                    stationChoices
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("提醒范围")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { radiusButtons }
                        VStack(spacing: 8) { radiusButtons }
                    }
                    Slider(
                        value: Binding(
                            get: { Double(max(radius.rawValue, ReminderRadius.androidRange.lowerBound)) },
                            set: { radius = ReminderRadius(meters: Int($0)) }
                        ),
                        in: Double(ReminderRadius.androidRange.lowerBound)...Double(ReminderRadius.androidRange.upperBound),
                        step: Double(ReminderRadius.step)
                    )
                    .tint(accent)
                    .accessibilityLabel("调整提醒范围")
                    .accessibilityValue(radius.label)
                    Text("当前范围  \(radius.label)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("开始守候后，定位进入蓝圈时会提醒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                onConfirm(draft)
            } label: {
                Text(isEditing ? "保存设置" : (draft.remindsAtDestination ? "确认目的地" : "确认下车站"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .controlSize(.large)
            .tint(ReminderPalette.actionBlue)
            .frame(maxWidth: 440)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(surface)
        }
        .background(surface.ignoresSafeArea())
        .navigationTitle(isEditing ? "调整提醒" : "确认提醒地点")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: showingStations) { _, showing in
            if !showing { scrollPosition.scrollTo(edge: .top) }
        }
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            guard importNote != nil, let request = MKReverseGeocodingRequest(location: station.location),
                  let item = try? await request.mapItems.first else { return }
            if let address = item.address?.fullAddress ?? item.addressRepresentations?.cityWithContext {
                station = ArrivalDestination(
                    name: station.name, address: address, coordinate: station.coordinate
                )
            }
        }
    }

    private var draft: StationSelection {
        if importNote != nil { return .direct(station, radius: radius) }
        return StationSelection(
            destination: selection.destination,
            stations: selection.stations,
            target: ArrivalTarget(station: station, radius: radius)
        )
    }

    private var stationHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let destination = draft.separateDestination {
                Text("目的地  \(destination.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if draft.separateDestination != nil {
                        let description = station.id == selection.stations.first?.id ? "最近地铁站" : "下车站"
                        Text("\(description) · 直线约 \(selection.stationDistanceLabel(station))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if !selection.stations.isEmpty {
                    Button {
                        showingStations.toggle()
                    } label: {
                        Text(showingStations ? "收起" : "换站")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(accent)
                    .accessibilityLabel(showingStations ? "收起站点列表" : "更换下车站")
                }
            }
            if let address = station.address, draft.remindsAtDestination {
                Text(address).font(.subheadline).foregroundStyle(.secondary)
            }
            if let importNote {
                Text(importNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var stationOptions: [ArrivalDestination] { selection.stations + [selection.destination] }

    private var mapAlternatives: [ArrivalDestination] {
        showingStations ? selection.stations.prefix(3).filter { $0.id != station.id } : []
    }

    private var stationChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择提醒地点")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            ForEach(stationOptions) { option in
                Divider()
                Button {
                    selectStation(option)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.name)
                                .font(.subheadline.weight(.semibold))
                            Text(option.id == selection.destination.id
                                 ? "直接在目的地提醒"
                                 : (option.id == selection.stations.first?.id
                                    ? "最近 · 直线约 \(selection.stationDistanceLabel(option))"
                                    : "直线约 \(selection.stationDistanceLabel(option))"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option.id == station.id {
                            Image(systemName: "checkmark").foregroundStyle(accent)
                        }
                    }
                    .frame(minHeight: 44)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option.id == station.id ? .isSelected : [])
            }
        }
    }

    private func selectStation(_ option: ArrivalDestination) {
        station = option
        selectedMarker = nil
        showingStations = false
    }

    private var rangeMap: some View {
        let preview = draft
        let target = preview.target
        return Map(position: $camera, interactionModes: [.pan, .zoom], selection: $selectedMarker) {
            MapCircle(center: target.station.coordinate, radius: Double(target.radius.rawValue))
                .foregroundStyle(accent.opacity(0.18))
                .stroke(accent, lineWidth: 2)
                .mapOverlayLevel(level: .aboveRoads)
            if let destination = preview.separateDestination {
                Marker("目的地 · \(destination.name)", systemImage: "flag.fill", coordinate: destination.coordinate)
                    .tint(.gray)
                    .tag(destination.id)
            }
            ForEach(mapAlternatives) { option in
                Marker(option.name, systemImage: "tram.fill", coordinate: option.coordinate)
                    .tint(.indigo)
                    .tag(option.id)
            }
            Marker(target.station.name, systemImage: preview.remindsAtDestination ? "mappin" : "tram.fill", coordinate: target.station.coordinate)
                .tint(ReminderPalette.actionBlue)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .mapControls {
            MapScaleView()
                .mapControlVisibility(.visible)
        }
        .onAppear { camera = .rect(previewBounds) }
        .onChange(of: station.id) { _, _ in camera = .rect(previewBounds) }
        .onChange(of: showingStations) { _, _ in
            selectedMarker = nil
            camera = .rect(previewBounds)
        }
        .onChange(of: selectedMarker) { _, marker in
            if showingStations, let option = stationOptions.first(where: { $0.id == marker }) {
                selectStation(option)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { visibleBounds = $0.rect }
        .onChange(of: radius) { oldRadius, _ in
            let zoomedOutForLargeRadius = oldRadius.rawValue > ReminderRadius.meters800.rawValue
                && radius.rawValue <= ReminderRadius.meters800.rawValue
            if zoomedOutForLargeRadius || visibleBounds?.contains(coverageBounds(for: radius.rawValue)) != true {
                camera = .rect(previewBounds)
            }
        }
        .frame(height: 328)
        .clipShape(.rect(cornerRadius: 20))
        .accessibilityLabel("站点和提醒范围地图")
        .accessibilityValue(radius.label)
    }

    private func coverageBounds(for meters: Int) -> MKMapRect {
        var bounds = MKCircle(center: station.coordinate, radius: Double(meters)).boundingMapRect
        for option in [selection.destination] + mapAlternatives {
            let point = MKMapPoint(option.coordinate)
            bounds = bounds.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        return bounds
    }

    private var previewBounds: MKMapRect {
        // 给常用半径留出同一取景范围，便于比较圆圈大小。
        let bounds = coverageBounds(for: max(radius.rawValue, ReminderRadius.meters800.rawValue))
        return bounds.insetBy(dx: -bounds.width * 0.16, dy: -bounds.height * 0.16)
    }

    private var radiusButtons: some View {
        ForEach(ReminderRadius.quickChoices, id: \.rawValue) { option in
            let isSelected = option == radius
            Button {
                radius = option
            } label: {
                Text(option.label)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(isSelected ? .white : accent)
                    .background(
                        isSelected ? ReminderPalette.actionBlue : ReminderPalette.controlSurface(in: colorScheme),
                        in: .rect(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(accent.opacity(0.22))
                            .allowsHitTesting(false)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var surface: Color { ReminderPalette.surface(in: colorScheme) }
    private var accent: Color { ReminderPalette.accent(in: colorScheme) }
}
