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

struct TripData: Codable {
    static let recentLimit = 10

    var selection: StationSelection?
    var recent: [StationSelection] = []
    var activeID: UUID?
    var arrival: ArrivalReceipt?
    var showsDestination = false

    mutating func remember(_ selection: StationSelection) {
        recent.removeAll { $0.matchesDestination(selection) }
        recent.insert(selection, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
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
