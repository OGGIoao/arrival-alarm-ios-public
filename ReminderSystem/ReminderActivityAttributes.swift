import ActivityKit

struct ReminderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let phase: Phase
        let placeName: String?
        let distance: String?
    }

    enum Phase: String, Codable, Sendable {
        case waiting, monitoring, positionUnavailable

        var title: String {
            switch self {
            case .waiting: "等待定位"
            case .monitoring: "守候中"
            case .positionUnavailable: "位置暂未更新"
            }
        }

        var compactTitle: String {
            switch self {
            case .waiting: "定位中"
            case .monitoring: "守候中"
            case .positionUnavailable: "待更新"
            }
        }

        var icon: String {
            switch self {
            case .waiting: "location"
            case .monitoring: "tram.fill"
            case .positionUnavailable: "location.slash"
            }
        }
    }
}
