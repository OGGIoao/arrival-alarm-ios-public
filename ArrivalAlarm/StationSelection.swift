import CoreLocation
import Foundation

struct StationSelection: Codable, Identifiable {
    let destination: ArrivalDestination
    let stations: [ArrivalDestination]
    let target: ArrivalTarget

    var id: UUID { destination.id }
    var remindsAtDestination: Bool { destination.id == target.station.id }

    static func direct(_ destination: ArrivalDestination, radius: ReminderRadius) -> Self {
        Self(destination: destination, stations: [], target: ArrivalTarget(station: destination, radius: radius))
    }

    var separateDestination: ArrivalDestination? {
        let station = target.station
        if destination.name == station.name, target.distance(from: destination.location) < 50 { return nil }
        return destination
    }

    func stationDistanceLabel(_ station: ArrivalDestination) -> String {
        let distance = station.location.distance(from: destination.location)
        return "\(Int((distance / 10).rounded()) * 10) 米"
    }

    func matchesDestination(_ other: Self) -> Bool {
        destination.id == other.destination.id
            || (destination.name == other.destination.name && destination.location.distance(from: other.destination.location) < 50)
    }

    var hasValidCoordinates: Bool {
        CLLocationCoordinate2DIsValid(destination.coordinate)
            && CLLocationCoordinate2DIsValid(target.station.coordinate)
            && stations.allSatisfy { CLLocationCoordinate2DIsValid($0.coordinate) }
    }
}

struct ArrivalReceipt: Codable, Identifiable {
    let id: UUID
    let placeName: String
    let walkingDestination: ArrivalDestination?

    init(id: UUID, placeName: String, walkingDestination: ArrivalDestination? = nil) {
        self.id = id
        self.placeName = placeName
        self.walkingDestination = walkingDestination
    }
}

enum ArrivalNotificationRoute: Equatable, Sendable {
    case trip(UUID)
    case returnVisit(UUID?)

    var receiptID: UUID? {
        switch self {
        case .trip(let id): id
        case .returnVisit(let id): id
        }
    }

    func receipt(in trip: TripData) -> ArrivalReceipt? {
        switch self {
        case .trip(let id):
            return trip.arrival?.id == id ? trip.arrival : nil
        case .returnVisit(let id):
            guard let id, trip.activeID == nil, trip.returnArrival?.id == id else { return nil }
            return trip.returnArrival
        }
    }
}

struct TripData: Codable {
    static let recentLimit = 10

    private struct PlaceUsage: Codable {
        var selection: StationSelection
        var startsByDay: [Date: Int]
        var lastStartedAt: Date
    }

    var selection: StationSelection?
    var recent: [StationSelection] = []
    var activeID: UUID?
    var arrival: ArrivalReceipt?
    var returnArrival: ArrivalReceipt?
    var showsDestination = false
    private var placeUsage: [PlaceUsage]?

    init(selection: StationSelection? = nil) {
        self.selection = selection
    }

    mutating func remember(_ selection: StationSelection) {
        recent.removeAll { $0.matchesDestination(selection) }
        recent.insert(selection, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
    }

    mutating func beginTrip(id: UUID, for selection: StationSelection, at now: Date) {
        if activeID == nil {
            recordStart(for: selection, at: now)
        }
        activeID = id
        arrival = nil
        returnArrival = nil
    }

    func frequentPlaces(at now: Date = .now) -> [StationSelection] {
        let window = Self.usageWindow(endingAt: now)
        let ranked = (placeUsage ?? []).compactMap { usage -> (usage: PlaceUsage, count: Int)? in
            let count = usage.startsByDay.filter { window.contains($0.key) }.values.reduce(0, +)
            return count >= 2 && usage.selection.hasValidCoordinates ? (usage, count) : nil
        }
        return ranked.sorted { first, second in
            if first.count != second.count { return first.count > second.count }
            return first.usage.lastStartedAt > second.usage.lastStartedAt
        }.prefix(2).map { entry in
            let saved = entry.usage.selection
            return recent.first { $0.matchesDestination(saved) } ?? saved
        }
    }

    private mutating func recordStart(for selection: StationSelection, at now: Date) {
        let window = Self.usageWindow(endingAt: now)
        let today = Calendar.current.startOfDay(for: now)
        var usage = placeUsage ?? []
        for index in usage.indices {
            usage[index].startsByDay = usage[index].startsByDay.filter { window.contains($0.key) }
        }
        usage.removeAll { $0.startsByDay.isEmpty }

        if let index = usage.firstIndex(where: { $0.selection.matchesDestination(selection) }) {
            usage[index].selection = selection
            usage[index].startsByDay[today, default: 0] += 1
            usage[index].lastStartedAt = now
        } else {
            usage.append(PlaceUsage(selection: selection, startsByDay: [today: 1], lastStartedAt: now))
        }
        placeUsage = usage
    }

    private static func usageWindow(endingAt now: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        // 包含今天在内的 30 个自然日。
        let firstDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        return firstDay...now
    }
}

enum TripStore {
    private static var legacyFile: URL {
        URL.applicationSupportDirectory.appending(path: "last-trip.json")
    }

    private static var file: URL {
        URL.applicationSupportDirectory.appending(path: "trip-data.json")
    }

    static func load() -> TripData {
        let decoder = JSONDecoder()
        if let contents = try? Data(contentsOf: file) {
            guard var data = try? decoder.decode(TripData.self, from: contents) else { return TripData() }
            if data.selection?.hasValidCoordinates != true {
                data.selection = nil
                data.activeID = nil
                data.returnArrival = nil
            }
            data.recent = Array(data.recent.filter(\.hasValidCoordinates).prefix(TripData.recentLimit))
            return data
        }
        guard let old = try? Data(contentsOf: legacyFile),
              let selection = try? decoder.decode(StationSelection.self, from: old),
              selection.hasValidCoordinates else { return TripData() }
        var migrated = TripData(selection: selection)
        migrated.remember(selection)
        return migrated
    }

    static func save(_ trip: TripData) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(trip)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.removeItem(at: legacyFile)
    }
}
