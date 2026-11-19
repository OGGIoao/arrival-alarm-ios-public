import CoreLocation
import Foundation

@main
struct FrequentPlacesRegression {
    static func main() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now).addingTimeInterval(12 * 3_600)
        let campus = place("学校", latitude: 45.77)
        let shop = place("商场", latitude: 45.78)
        let library = place("图书馆", latitude: 45.79)
        let unused = place("博物馆", latitude: 45.80)

        let encodedCampus = String(decoding: try JSONEncoder().encode(campus), as: UTF8.self)
        let legacy = Data("""
        {"selection":\(encodedCampus),"recent":[\(encodedCampus)],"showsDestination":false}
        """.utf8)
        var trip = try JSONDecoder().decode(TripData.self, from: legacy)
        precondition(trip.selection?.id == campus.id && trip.recent.count == 1, "升级后保留原有地点")
        precondition(trip.frequentPlaces(at: today).isEmpty, "旧地点不会凭空获得使用次数")

        let firstID = UUID()
        trip.beginTrip(id: firstID, for: campus, at: today)
        trip.beginTrip(id: firstID, for: campus, at: today.addingTimeInterval(10))
        precondition(trip.frequentPlaces(at: today).isEmpty, "继续同一趟只计一次")

        let sameCampus = place("学校", latitude: 45.7701, radius: .meters500)
        trip.remember(sameCampus)
        startNewTrip(in: &trip, at: today.addingTimeInterval(20), to: sameCampus)
        precondition(trip.frequentPlaces(at: today).map(\.id) == [sameCampus.id], "重新搜索同一地点合并计数")
        precondition(trip.frequentPlaces(at: today).first?.target.radius == .meters500, "复用最新确认的提醒范围")

        startNewTrip(in: &trip, at: today.addingTimeInterval(30), to: sameCampus)
        startNewTrip(in: &trip, at: today.addingTimeInterval(40), to: shop)
        startNewTrip(in: &trip, at: today.addingTimeInterval(50), to: shop)
        startNewTrip(in: &trip, at: today.addingTimeInterval(60), to: library)
        startNewTrip(in: &trip, at: today.addingTimeInterval(70), to: library)
        trip.remember(unused)
        let ranked = [sameCampus.id, library.id]
        precondition(trip.frequentPlaces(at: today).map(\.id) == ranked, "次数优先，同次数按最近使用排列，只取前两位")
        let reopened = try JSONDecoder().decode(TripData.self, from: JSONEncoder().encode(trip))
        precondition(reopened.frequentPlaces(at: today).map(\.id) == ranked, "重新打开后保留排序")
        precondition(TripData().frequentPlaces(at: today).isEmpty, "清空设置后没有常用地点")

        var timed = TripData()
        let outsideWindow = calendar.date(byAdding: .day, value: -30, to: today)!
        let firstIncluded = calendar.date(byAdding: .day, value: -29, to: today)!
        startNewTrip(in: &timed, at: outsideWindow, to: campus)
        startNewTrip(in: &timed, at: outsideWindow, to: shop)
        startNewTrip(in: &timed, at: firstIncluded, to: campus)
        startNewTrip(in: &timed, at: today, to: campus)
        startNewTrip(in: &timed, at: today, to: shop)
        precondition(timed.frequentPlaces(at: today).map(\.id) == [campus.id], "只统计含今天的 30 个自然日")

        print("常用地点回归通过")
    }

    private static func place(
        _ name: String, latitude: Double, radius: ReminderRadius = .meters300
    ) -> StationSelection {
        let destination = ArrivalDestination(
            name: name,
            address: nil,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 126.68)
        )
        return .direct(destination, radius: radius)
    }

    private static func startNewTrip(in trip: inout TripData, at now: Date, to selection: StationSelection) {
        trip.activeID = nil
        trip.beginTrip(id: UUID(), for: selection, at: now)
    }
}
