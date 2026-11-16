import CoreLocation
import Foundation

enum PlaceInput {
    case keyword(String)
    case coordinates(ImportedPlace)
    case unreadable

    struct ImportedPlace {
        let name: String?
        let coordinate: CLLocationCoordinate2D
        let note: String

        var destination: ArrivalDestination {
            ArrivalDestination(name: name ?? "导入的地点", address: nil, coordinate: coordinate)
        }
    }

    private enum CoordinateSystem {
        case wgs84, gcj02, bd09, unknown

        var note: String {
            switch self {
            case .wgs84: "请确认地图上的位置。"
            case .gcj02, .bd09: "已转换地图坐标，请确认地图上的位置。"
            case .unknown: "坐标来源未知，请确认地图上的位置。"
            }
        }
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"(?i)(?:https?://|arrivalalarm://|geo:|amapuri://|iosamap://|androidamap://|baidumap://|qqmap://|maps://)[^\s<>"）。]+"#)
    private static let pairPattern = try! NSRegularExpression(pattern: #"(?<![.\d])([+-]?\d{1,3}(?:\.\d+)?)\s*[,，]\s*([+-]?\d{1,3}(?:\.\d+)?)(?![.\d])"#)

    static func isArrivalLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "arrivalalarm" && url.host?.lowercased() == "set"
    }

    static func parse(_ input: String) -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= SharedPlaceInbox.inputLimit else { return .unreadable }
        let range = NSRange(text.startIndex..., in: text)
        if let match = linkPattern.firstMatch(in: text, range: range),
           let linkRange = Range(match.range, in: text) {
            let name = text.replacingCharacters(in: linkRange, with: "")
            guard let link = URLComponents(string: String(text[linkRange])) else { return .unreadable }
            return parse(link, sharedName: name)
        }
        if let match = pairPattern.firstMatch(in: text, range: range),
           let pairRange = Range(match.range, in: text) {
            let values = pair(in: String(text[pairRange]))
            let coordinates = coordinate(latitude: values?.first, longitude: values?.second)
                ?? coordinate(latitude: values?.second, longitude: values?.first)
            guard let coordinates else { return .unreadable }
            return .coordinates(ImportedPlace(
                name: cleanName(text.replacingCharacters(in: pairRange, with: "")),
                coordinate: coordinates, note: CoordinateSystem.unknown.note
            ))
        }
        return .keyword(text)
    }

    private static func parse(_ link: URLComponents, sharedName: String) -> Self {
        let scheme = link.scheme?.lowercased()
        let host = link.host?.lowercased() ?? ""
        if scheme == "arrivalalarm", host != "set" { return .unreadable }
        var items = link.queryItems ?? []
        if items.count == 1, let first = items.first,
           ["dlat", "lat", "latitude"].contains(first.name.lowercased()), first.value?.contains("&") == true {
            // 分享文本可能把查询参数之间的 & 一并编码。
            var expanded = link
            expanded.query = link.query
            items = expanded.queryItems ?? items
        }
        func value(_ names: String...) -> String? {
            for name in names {
                if let item = items.first(where: { $0.name.lowercased() == name }),
                   let result = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                    return result
                }
            }
            return nil
        }
        let system: CoordinateSystem
        switch scheme {
        case "arrivalalarm", "geo", "maps": system = .wgs84
        case "amapuri", "androidamap", "iosamap", "qqmap": system = .gcj02
        case "baidumap": system = .bd09
        default:
            if inDomain(host, "amap.com") || inDomain(host, "map.qq.com") {
                system = .gcj02
            } else if inDomain(host, "baidu.com") {
                system = .bd09
            } else {
                system = .unknown
            }
        }
        var point = coordinate(
            latitude: value("dlat", "lat", "latitude").flatMap(Double.init),
            longitude: value("dlon", "dlng", "lng", "lon", "longitude").flatMap(Double.init)
        )
        let eastFirst = value("to", "dest", "destination", "position", "center")
        let query = value("q")
        let pathCoordinate = scheme == "geo" ? link.path : link.path.split(separator: "@").dropFirst().first.map(String.init)
        // geo 链接常用 q 指定真实坐标，路径仍写 0,0。
        let northFirst = value("location", "coord", "ll", "sll") ?? query.flatMap { pair(in: $0) == nil ? nil : $0 } ?? pathCoordinate
        if point == nil, let values = pair(in: eastFirst) {
            point = coordinate(latitude: values.second, longitude: values.first)
        }
        if point == nil, let values = pair(in: northFirst) {
            point = coordinate(latitude: values.first, longitude: values.second)
        }
        let embeddedName = eastFirst?.split(separator: ",", maxSplits: 2).dropFirst(2).first.map(String.init)
        let queryName = query.flatMap { name -> String? in
            guard pair(in: name) != nil else { return name }
            guard let start = name.firstIndex(of: "("), let end = name.lastIndex(of: ")"), start < end else { return nil }
            return String(name[name.index(after: start)..<end])
        }
        let name = [value("dname", "poiname", "title", "name"), embeddedName, queryName, value("address", "addr"), sharedName]
            .compactMap { $0.flatMap(cleanName) }.first
        guard let point else {
            if scheme == "arrivalalarm" || scheme == "geo" { return .unreadable }
            return name.map(Self.keyword) ?? .unreadable
        }
        let converted = switch system {
        case .gcj02: PlaceCoordinateTransform.fromGCJ02(point)
        case .bd09: PlaceCoordinateTransform.fromBD09(point)
        case .wgs84, .unknown: point
        }
        return .coordinates(ImportedPlace(name: name, coordinate: converted, note: system.note))
    }

    private static func inDomain(_ hostname: String, _ domain: String) -> Bool {
        hostname == domain || hostname.hasSuffix("." + domain)
    }

    private static func pair(in text: String?) -> (first: Double, second: Double)? {
        guard let text,
              let match = pairPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let first = Range(match.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
              let second = Range(match.range(at: 2), in: text).flatMap({ Double(text[$0]) }) else { return nil }
        return (first, second)
    }

    private static func coordinate(latitude: Double?, longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let result = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(result) ? result : nil
    }

    private static func cleanName(_ name: String) -> String? {
        var text = name
        for (open, close): (Character, Character) in [("「", "」"), ("【", "】")] {
            if let start = text.firstIndex(of: open), let end = text.lastIndex(of: close), start < end {
                text = String(text[text.index(after: start)..<end])
                break
            }
        }
        text = text.replacingOccurrences(
            of: #"(?:复制|打开|查看|分享自|来自)(?:链接)?|(?:高德|百度|腾讯)地图(?:APP)?"#,
            with: " ", options: [.regularExpression, .caseInsensitive]
        )
        let trimmed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty ? nil : String(trimmed.prefix(100))
    }
}
