import CoreLocation
import Foundation

enum WalkingMap: CaseIterable {
    case amap, baidu

    var name: String {
        switch self {
        case .amap: "高德地图"
        case .baidu: "百度地图"
        }
    }

    func route(to destination: ArrivalDestination) -> URL? {
        let coordinate = destination.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        var components = URLComponents()
        switch self {
        case .amap:
            components.scheme = "iosamap"
            components.host = "path"
            // 坐标由定位和搜索统一成 WGS84，高德接收后转换。
            components.queryItems = [
                URLQueryItem(name: "sourceApplication", value: "别坐过站"),
                URLQueryItem(name: "dlat", value: String(coordinate.latitude)),
                URLQueryItem(name: "dlon", value: String(coordinate.longitude)),
                URLQueryItem(name: "dname", value: destination.name),
                URLQueryItem(name: "dev", value: "1"),
                URLQueryItem(name: "t", value: "2")
            ]
        case .baidu:
            components.scheme = "baidumap"
            components.host = "map"
            components.path = "/walknavi"
            components.queryItems = [
                URLQueryItem(name: "destination", value: "\(coordinate.latitude),\(coordinate.longitude)"),
                URLQueryItem(name: "coord_type", value: "wgs84"),
                URLQueryItem(name: "src", value: "ios.oggioao.arrivalalarm")
            ]
        }
        // 地点名里的加号按字面传递，避免被地图 App 按表单规则解成空格。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
