import CoreLocation
import UserNotifications

@main
struct ArrivalNotificationRegression {
    static func main() throws {
        let station = ArrivalDestination(name: "测试站", address: nil, coordinate: .init(latitude: 45.78, longitude: 126.68))
        let school = ArrivalDestination(name: "测试学校", address: nil, coordinate: .init(latitude: 45.79, longitude: 126.68))
        let target = ArrivalTarget(station: station, radius: .meters300)
        let normal = ArrivalReceipt(id: UUID(), placeName: station.name, walkingDestination: school)
        let visit = ArrivalReceipt(id: UUID(), placeName: station.name, walkingDestination: school)
        var trip = TripData(selection: .direct(school, radius: .meters500))
        trip.arrival = normal
        trip.returnArrival = visit

        let first = ArrivalNotifications.arrivalContent(receipt: normal, showsDestination: false)
        let followUp = ArrivalNotifications.pulseRequest(identifier: "follow-up", content: first, at: .now.addingTimeInterval(30))!
        precondition(ArrivalNotifications.tripID(in: followUp) == normal.id, "后续通知仍属于同一趟")
        let returnRequest = ArrivalNotifications.returnRequest(for: target, id: visit.id, showsDestination: false)
        precondition(ArrivalNotifications.tripID(in: returnRequest) == visit.id, "系统回访请求保留登记身份")
        precondition(ArrivalNotifications.matchesReturnRequest(returnRequest, target: target), "回访围栏仍指向登记站点")

        let restored = try JSONDecoder().decode(TripData.self, from: JSONEncoder().encode(trip))
        precondition(ArrivalNotificationRoute.trip(normal.id).receipt(in: restored)?.placeName == station.name)
        let restoredVisit = ArrivalNotificationRoute.returnVisit(visit.id).receipt(in: restored)
        precondition(restoredVisit?.placeName == station.name && restoredVisit?.walkingDestination?.id == school.id,
                     "恢复后仍使用登记时的站点和步行目的地")
        precondition(ArrivalNotificationRoute.returnVisit(normal.id).receipt(in: restored) == nil, "普通通知不能冒用回访记录")
        precondition(ArrivalNotificationRoute.returnVisit(nil).receipt(in: restored) == nil, "无身份的回访不能打开当前地点")

        let legacy = try JSONDecoder().decode(TripData.self, from: Data(#"{"recent":[],"showsDestination":false}"#.utf8))
        precondition(ArrivalNotificationRoute.returnVisit(visit.id).receipt(in: legacy) == nil, "升级前的本地记录仍可读")

        let newID = UUID()
        trip.beginTrip(id: newID, for: .direct(school, radius: .meters500), at: .now)
        precondition(ArrivalNotificationRoute.trip(normal.id).receipt(in: trip) == nil)
        precondition(ArrivalNotificationRoute.returnVisit(visit.id).receipt(in: trip) == nil)
        precondition(trip.activeID == newID, "旧通知不会影响新守候")
        print("到站通知身份与恢复回归通过")
    }
}
