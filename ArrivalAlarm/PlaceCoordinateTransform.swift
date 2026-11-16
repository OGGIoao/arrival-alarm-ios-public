/*
坐标转换算法移植自 arrival-alarm-android 的 CoordinateTransform.java。
https://github.com/yueqiu666/arrival-alarm-android/blob/477078a/android-app/src/com/example/arrivalalarm/CoordinateTransform.java

MIT License

Copyright (c) 2026 Arrival Alarm Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import CoreLocation

enum PlaceCoordinateTransform {
    private static let axis = 6_378_245.0
    private static let eccentricity = 0.00669342162296594323

    static func fromGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard insideTransformRegion(coordinate) else { return coordinate }
        let x = coordinate.longitude - 105
        let y = coordinate.latitude - 35
        let latitudeRadians = coordinate.latitude * .pi / 180
        let sine = sin(latitudeRadians)
        let magic = 1 - eccentricity * sine * sine
        let root = sqrt(magic)
        let latitudeOffset = latitudeDelta(x: x, y: y) * 180 / (axis * (1 - eccentricity) / (magic * root) * .pi)
        let longitudeOffset = longitudeDelta(x: x, y: y) * 180 / (axis / root * cos(latitudeRadians) * .pi)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude - latitudeOffset,
            longitude: coordinate.longitude - longitudeOffset
        )
    }

    static func fromBD09(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard insideTransformRegion(coordinate) else { return coordinate }
        let x = coordinate.longitude - 0.0065
        let y = coordinate.latitude - 0.006
        let angle = Double.pi * 3_000 / 180
        let distance = hypot(x, y) - 0.00002 * sin(y * angle)
        let theta = atan2(y, x) - 0.000003 * cos(x * angle)
        return fromGCJ02(CLLocationCoordinate2D(latitude: distance * sin(theta), longitude: distance * cos(theta)))
    }

    private static func insideTransformRegion(_ point: CLLocationCoordinate2D) -> Bool {
        (72.004...137.8347).contains(point.longitude) && (0.8293...55.8271).contains(point.latitude)
    }

    private static func latitudeDelta(x: Double, y: Double) -> Double {
        let base = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        let short = 20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)
        let long = 160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)
        return base + commonDelta(x) + (short + long) * 2 / 3
    }

    private static func longitudeDelta(x: Double, y: Double) -> Double {
        let base = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        let short = 20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)
        let long = 150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)
        return base + commonDelta(x) + (short + long) * 2 / 3
    }

    private static func commonDelta(_ x: Double) -> Double {
        (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
    }
}
