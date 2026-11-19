import MapKit
import SwiftUI

struct StationSearchView: View {
    let initialRadius: ReminderRadius
    let frequent: [StationSelection]
    let recent: [StationSelection]
    let nearby: CLLocationCoordinate2D?
    let onConfirm: (StationSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AMapPlaceSearch.preferenceKey) private var useAMap = false
    @FocusState private var searchFocused: Bool
    @StateObject private var suggestions = PlaceSuggestions()
    @State private var query: String
    @State private var phase: SearchPhase = .idle
    @State private var currentSearch: MKLocalSearch?
    @State private var currentAMapSearch: Task<Void, Never>?
    @State private var amapSuggestions: [AMapPlaceSearch.Entry] = []
    @State private var confirmingAMap = false

    private enum SearchPhase {
        case idle
        case searching
        case results([ArrivalDestination])
        case imported(PlaceInput.ImportedPlace)
        case unreadable
        case empty
        case failed(String)
    }

    init(
        initialRadius: ReminderRadius,
        frequent: [StationSelection],
        recent: [StationSelection],
        nearby: CLLocationCoordinate2D?,
        initialInput: String,
        onConfirm: @escaping (StationSelection) -> Void
    ) {
        self.initialRadius = initialRadius
        self.frequent = frequent
        self.recent = recent
        self.nearby = nearby
        self.onConfirm = onConfirm
        _query = State(initialValue: initialInput)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        TextField("地点、站名或地图链接", text: $query)
                            .accessibilityLabel("目的地")
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .onSubmit(search)
                        Button("搜索", action: search)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(keyword.isEmpty || isSearching)
                    }
                }

                switch phase {
                case .idle:
                    if keyword.isEmpty, frequent.isEmpty {
                        Text("输入目的地或地铁站，也可以粘贴地图链接。")
                            .foregroundStyle(.secondary)
                    }
                    savedPlacesSections
                    if !amapSuggestions.isEmpty {
                        Section("地点建议") {
                            ForEach(amapSuggestions) { item in
                                Button {
                                    searchFocused = false
                                    if let destination = item.destination {
                                        cancelSearch()
                                        phase = .results([destination])
                                    } else if let amap {
                                        performAMapSearch(item.name, using: amap)
                                    }
                                } label: {
                                    suggestionRow(name: item.name, address: item.address)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if !suggestions.items.isEmpty {
                        Section("地点建议") {
                            ForEach(suggestions.items, id: \.self) { item in
                                Button {
                                    let request = MKLocalSearch.Request(completion: item)
                                    perform(request)
                                } label: {
                                    suggestionRow(name: item.title, address: item.subtitle)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                case .searching:
                    ProgressView("正在搜索地点")
                case .results(let destinations):
                    Section("搜索结果") {
                        ForEach(destinations) { destination in
                            NavigationLink {
                                NearbyStationsView(destination: destination, initialRadius: initialRadius, onConfirm: confirm)
                            } label: {
                                StationSummary(destination: destination)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                case .imported(let place):
                    Section {
                        NavigationLink {
                            StationRangeView(
                                selection: .direct(place.destination, radius: initialRadius),
                                importNote: place.note,
                                onConfirm: confirm
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.name ?? "导入的地点").font(.headline)
                                Text("在地图上核对位置").font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                case .unreadable:
                    Text("这段内容里没有可用的位置。可以输入地点名，或粘贴带坐标的地图链接。")
                        .foregroundStyle(.secondary)
                case .empty:
                    Text("没有找到地点。试试加上城市名，或换个关键词。")
                        .foregroundStyle(.secondary)
                    savedPlacesSections
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                        Button("重试", action: search)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    savedPlacesSections
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("搜索目的地")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if AMapPlaceSearch.configured != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Apple 地图") { useAMap = false }
                            Button("高德地图") { if !useAMap { confirmingAMap = true } }
                        } label: {
                            Text(useAMap ? "高德地图" : "Apple 地图")
                        }
                        .accessibilityLabel("搜索来源")
                        .accessibilityValue(useAMap ? "高德地图" : "Apple 地图")
                    }
                }
            }
            .alert("用高德地图搜索？", isPresented: $confirmingAMap) {
                Button("切换到高德") { useAMap = true }
                Button("取消", role: .cancel) {}
            } message: {
                Text("地点关键词和输入的城市会发送给高德。地图预览和附近地铁站仍由 Apple 地图提供。")
            }
            .onChange(of: query) { _, _ in resetSearch() }
            .onChange(of: useAMap) { _, _ in resetSearch() }
            .onChange(of: suggestions.needsSearch) { _, needsSearch in
                guard needsSearch, amap == nil, case .idle = phase,
                      case .keyword(let input) = PlaceInput.parse(keyword) else { return }
                perform(MKLocalSearch.Request(naturalLanguageQuery: input))
            }
            .task {
                if !keyword.isEmpty { search() }
            }
            .task(id: [keyword, useAMap ? "AMap" : "MapKit"]) {
                guard case .idle = phase, case .keyword(let input) = PlaceInput.parse(keyword),
                      input.count >= 2, input.count <= 100 else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard case .idle = phase, !Task.isCancelled else { return }
                if let amap {
                    let items = (try? await amap.suggestions(for: input)) ?? []
                    guard !Task.isCancelled, case .idle = phase else { return }
                    amapSuggestions = items
                } else {
                    suggestions.update(query: input, region: nearbyRegion)
                }
            }
        }
        .onDisappear { cancelSearch() }
    }

    private func suggestionRow(name: String, address: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            if let address, !address.isEmpty {
                Text(address).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var savedPlacesSections: some View {
        let matchingFrequent = frequent.filter(matchesKeyword)
        let matchingRecent = recent.filter { item in
            matchesKeyword(item) && !matchingFrequent.contains { $0.matchesDestination(item) }
        }

        if !matchingFrequent.isEmpty {
            Section("常用地点") {
                savedPlaceRows(matchingFrequent, showsReminderDetails: true)
            }
        }
        if !matchingRecent.isEmpty {
            Section("最近地点") {
                savedPlaceRows(matchingRecent, showsReminderDetails: false)
            }
        }
    }

    private func savedPlaceRows(_ items: [StationSelection], showsReminderDetails: Bool) -> some View {
        ForEach(items) { item in
            NavigationLink {
                StationRangeView(selection: item, onConfirm: confirm)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.destination.name).font(.headline)
                    let detail = showsReminderDetails
                        ? "\(item.target.station.name) · \(item.target.radius.label)"
                        : item.destination.address
                    if let detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func matchesKeyword(_ item: StationSelection) -> Bool {
        keyword.isEmpty || item.destination.name.localizedCaseInsensitiveContains(keyword)
            || item.target.station.name.localizedCaseInsensitiveContains(keyword)
    }

    private var keyword: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var amap: AMapPlaceSearch? { useAMap ? AMapPlaceSearch.configured : nil }
    private var isSearching: Bool { currentSearch != nil || currentAMapSearch != nil }

    private var nearbyRegion: MKCoordinateRegion? {
        nearby.map { MKCoordinateRegion(center: $0, latitudinalMeters: 60_000, longitudinalMeters: 60_000) }
    }

    private func confirm(_ selected: StationSelection) {
        onConfirm(selected)
        dismiss()
    }

    private func search() {
        guard !keyword.isEmpty, !isSearching else { return }
        searchFocused = false
        cancelSearch()
        switch PlaceInput.parse(keyword) {
        case .coordinates(let place):
            phase = .imported(place)
        case .keyword(let name):
            if let amap {
                performAMapSearch(name, using: amap)
            } else {
                perform(MKLocalSearch.Request(naturalLanguageQuery: name))
            }
        case .unreadable:
            phase = .unreadable
        }
    }

    private func perform(_ request: MKLocalSearch.Request) {
        searchFocused = false
        cancelSearch()
        request.resultTypes = [.pointOfInterest, .address]
        if let nearbyRegion { request.region = nearbyRegion }
        let search = MKLocalSearch(request: request)
        currentSearch = search
        phase = .searching
        Task {
            do {
                let response = try await search.start()
                guard currentSearch === search else { return }
                let destinations = response.mapItems.compactMap(ArrivalDestination.init(mapItem:))
                phase = destinations.isEmpty ? .empty : .results(destinations)
            } catch {
                guard currentSearch === search else { return }
                phase = (error as? MKError)?.code == .placemarkNotFound
                    ? .empty : .failed("暂时无法搜索，请检查网络后重试。")
            }
            currentSearch = nil
        }
    }

    private func performAMapSearch(_ query: String, using search: AMapPlaceSearch) {
        searchFocused = false
        cancelSearch()
        phase = .searching
        currentAMapSearch = Task {
            do {
                let destinations = try await search.results(for: query)
                guard !Task.isCancelled else { return }
                phase = destinations.isEmpty ? .empty : .results(destinations)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed("高德暂时无法搜索。可以重试或切回 Apple 地图。")
            }
            currentAMapSearch = nil
        }
    }

    private func resetSearch() {
        cancelSearch()
        phase = .idle
    }

    private func cancelSearch() {
        currentSearch?.cancel()
        currentSearch = nil
        currentAMapSearch?.cancel()
        currentAMapSearch = nil
        suggestions.cancel()
        amapSuggestions = []
    }
}

@MainActor
private final class PlaceSuggestions: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var items: [MKLocalSearchCompletion] = []
    @Published private(set) var needsSearch = false
    private var active: MKLocalSearchCompleter?

    func update(query: String, region: MKCoordinateRegion?) {
        cancel()
        let completer = MKLocalSearchCompleter()
        completer.resultTypes = [.pointOfInterest, .address, .query]
        if let region { completer.region = region }
        completer.delegate = self
        active = completer
        completer.queryFragment = query
    }

    func cancel() {
        active?.cancel()
        active = nil
        items = []
        needsSearch = false
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === active else { return }
        items = Array(completer.results.prefix(8))
        needsSearch = items.isEmpty
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        guard completer === active else { return }
        needsSearch = true
    }
}

private struct StationSummary: View {
    let destination: ArrivalDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(destination.name)
                .font(.headline)
            if destination.isPublicTransport {
                Text("公共交通")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(destination.address ?? "未提供地址")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NearbyStationsView: View {
    let destination: ArrivalDestination
    let initialRadius: ReminderRadius
    let onConfirm: (StationSelection) -> Void

    @State private var phase = Phase.loading

    private static let searchRadius: CLLocationDistance = 3_000

    private enum Phase {
        case loading
        case ready(StationSelection)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 16) {
                    ProgressView("正在查找附近地铁站")
                    Button("直接用这个地点") { phase = .ready(directSelection) }
                        .buttonStyle(.bordered)
                }
                .navigationTitle("附近地铁站")
            case .ready(let selection):
                StationRangeView(selection: selection, onConfirm: onConfirm)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await findStations()
        }
    }

    private var directSelection: StationSelection { .direct(destination, radius: initialRadius) }

    private func findStations() async {
        let span = Self.searchRadius * 2
        let request = MKLocalSearch.Request(
            naturalLanguageQuery: "地铁站",
            region: MKCoordinateRegion(
                center: destination.coordinate,
                latitudinalMeters: span,
                longitudinalMeters: span
            )
        )
        request.resultTypes = .pointOfInterest
        request.regionPriority = .required
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled, case .loading = phase else { return }
            let center = destination.location
            let stations = response.mapItems
                .compactMap(ArrivalDestination.init(mapItem:))
                .filter(\.isPublicTransport)
                .map { (station: $0, distance: $0.location.distance(from: center)) }
                .filter { $0.distance <= Self.searchRadius }
                .sorted { $0.distance < $1.distance }
                .map(\.station)
            guard let nearest = stations.first else {
                phase = .ready(directSelection)
                return
            }
            phase = .ready(StationSelection(
                destination: destination,
                stations: stations,
                target: ArrivalTarget(station: nearest, radius: initialRadius)
            ))
        } catch {
            guard !Task.isCancelled, case .loading = phase else { return }
            phase = .ready(directSelection)
        }
    }
}

private extension ArrivalDestination {
    init?(mapItem: MKMapItem) {
        let coordinate = mapItem.location.coordinate
        guard let name = mapItem.name, !name.isEmpty,
              CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        self.init(
            name: name,
            address: mapItem.address?.fullAddress ?? mapItem.addressRepresentations?.cityWithContext,
            coordinate: coordinate,
            isPublicTransport: mapItem.pointOfInterestCategory == .publicTransport
        )
    }
}
