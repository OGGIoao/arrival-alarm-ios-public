import CoreLocation

struct ArrivalDestination: Identifiable, Codable {
    let id: UUID
    let name: String
    let address: String?
    let isPublicTransport: Bool
    private let latitude: CLLocationDegrees
    private let longitude: CLLocationDegrees

    init(name: String, address: String?, coordinate: CLLocationCoordinate2D, isPublicTransport: Bool = false) {
        id = UUID()
        self.name = name
        self.address = address
        self.isPublicTransport = isPublicTransport
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct ReminderRadius: Hashable, Codable, RawRepresentable {
    static let androidRange = 300...5_000
    static let step = 100
    static let meters200 = Self(meters: 200)
    static let meters300 = Self(meters: 300)
    static let meters500 = Self(meters: 500)
    static let meters800 = Self(meters: 800)
    static let standard = Self(meters: 1_000)
    static let quickChoices = [meters200, meters300, meters500, meters800]

    let rawValue: Int

    init(meters: Int) {
        let bounded = min(Self.androidRange.upperBound, max(200, meters))
        rawValue = ((bounded + Self.step / 2) / Self.step) * Self.step
    }

    init?(rawValue: Int) {
        guard rawValue == 200 || (Self.androidRange.contains(rawValue) && rawValue.isMultiple(of: Self.step)) else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let meters = try container.decode(Int.self)
        guard let radius = Self(rawValue: meters) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效的提醒范围")
        }
        self = radius
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var label: String {
        rawValue < 1_000 ? "\(rawValue) 米" : "\((Double(rawValue) / 1_000).formatted(.number.precision(.fractionLength(0...1)))) 公里"
    }
    var accuracyLimit: CLLocationAccuracy { min(200, Double(rawValue) / 2) }
}

struct ArrivalTarget: Codable {
    let station: ArrivalDestination
    let radius: ReminderRadius

    func distance(from location: CLLocation) -> CLLocationDistance {
        location.distance(from: station.location)
    }
}

struct ArrivalCheck {
    enum Result: Equatable {
        case filtered(FilterReason)
        case outside
        case arrived
    }

    enum FilterReason: Equatable {
        case alreadyArrived
        case invalidCoordinate
        case beforeStart
        case outOfOrder
        case futureTimestamp
        case stale
        case invalidAccuracy
        case lowAccuracy
    }

    static let maximumAge: TimeInterval = 15

    let target: ArrivalTarget
    let startedAt: Date
    private var lastAcceptedAt: Date?
    private var hasArrived = false

    init(target: ArrivalTarget, startedAt: Date) {
        self.target = target
        self.startedAt = startedAt
    }

    mutating func record(_ location: CLLocation, now: Date = .now) -> Result {
        let age = now.timeIntervalSince(location.timestamp)
        guard !hasArrived else { return .filtered(.alreadyArrived) }
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return .filtered(.invalidCoordinate) }
        guard location.timestamp >= startedAt else { return .filtered(.beforeStart) }
        if let lastAcceptedAt, location.timestamp <= lastAcceptedAt {
            return .filtered(.outOfOrder)
        }
        guard age >= 0 else { return .filtered(.futureTimestamp) }
        guard age <= Self.maximumAge else { return .filtered(.stale) }
        let accuracy = location.horizontalAccuracy
        guard accuracy.isFinite, accuracy >= 0 else { return .filtered(.invalidAccuracy) }
        guard accuracy <= target.radius.accuracyLimit else { return .filtered(.lowAccuracy) }

        lastAcceptedAt = location.timestamp
        guard target.distance(from: location) <= Double(target.radius.rawValue) else {
            return .outside
        }
        hasArrived = true
        return .arrived
    }
}
