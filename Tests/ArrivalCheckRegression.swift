import CoreLocation

@main
struct ArrivalCheckRegression {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(20)
        let center = CLLocationCoordinate2D(latitude: 30.6571, longitude: 104.0658)
        let station = ArrivalDestination(name: "测试站", address: nil, coordinate: center)
        let target = ArrivalTarget(station: station, radius: .meters300)

        func fix(
            _ offset: TimeInterval,
            accuracy: Double = 10,
            outside: Bool = false,
            latitude: Double? = nil
        ) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: latitude ?? center.latitude + (outside ? Double(target.radius.rawValue) / 55_000 : 0),
                    longitude: center.longitude
                ),
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: 10,
                timestamp: start.addingTimeInterval(offset)
            )
        }

        var check = ArrivalCheck(target: target, startedAt: start)
        precondition(check.record(fix(-1), now: start) == .filtered(.beforeStart), "忽略守候前的定位")
        precondition(check.record(fix(2), now: now) == .filtered(.stale), "忽略过期定位")
        precondition(check.record(fix(21), now: now) == .filtered(.futureTimestamp), "忽略未来时间戳")
        precondition(check.record(fix(6, latitude: 91), now: now) == .filtered(.invalidCoordinate), "忽略非法坐标")
        precondition(check.record(fix(7, accuracy: -1), now: now) == .filtered(.invalidAccuracy), "忽略无效定位精度")
        precondition(check.record(fix(8, accuracy: target.radius.accuracyLimit + 1), now: now) == .filtered(.lowAccuracy), "忽略低精度定位")
        precondition(check.record(fix(10, outside: true), now: now) == .outside, "圈外继续守候")
        precondition(check.record(fix(9), now: now) == .filtered(.outOfOrder), "忽略乱序定位")
        precondition(check.record(fix(10), now: now) == .filtered(.outOfOrder), "忽略同一时间戳")
        precondition(check.record(fix(12), now: now) == .arrived, "圈内首次触发")
        precondition(check.record(fix(13), now: now) == .filtered(.alreadyArrived), "圈内重复定位不触发")
        precondition(check.record(fix(14, outside: true), now: now) == .filtered(.alreadyArrived), "触发后忽略圈外更新")
        precondition(check.record(fix(15), now: now) == .filtered(.alreadyArrived), "重新进入不触发")

        var next = ArrivalCheck(target: target, startedAt: start.addingTimeInterval(15))
        precondition(next.record(fix(16), now: now) == .arrived, "重新开始可以独立触发")

        let widerTarget = ArrivalTarget(station: station, radius: .meters500)
        var baseline = ArrivalCheck(target: target, startedAt: start)
        var wider = ArrivalCheck(target: widerTarget, startedAt: start)
        let between = fix(12, latitude: center.latitude + 0.0035)
        precondition(baseline.record(between, now: now) == .outside, "300 米半径判在圈外")
        precondition(wider.record(between, now: now) == .arrived, "500 米半径判在圈内")

        let otherStation = ArrivalDestination(name: "另一站", address: nil, coordinate: between.coordinate)
        var other = ArrivalCheck(target: ArrivalTarget(station: otherStation, radius: .meters200), startedAt: start)
        precondition(other.record(fix(12), now: now) == .outside, "更换站点后按新坐标计算")
        precondition(other.record(fix(13, accuracy: 130, latitude: between.coordinate.latitude), now: now) == .filtered(.lowAccuracy),
                     "200 米半径使用本轮的精度门槛")
        precondition(other.record(fix(14, latitude: between.coordinate.latitude), now: now) == .arrived,
                     "到新站点后触发")
        print("到站判定通过（19 项）")
    }
}
