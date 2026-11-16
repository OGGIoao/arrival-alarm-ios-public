import CoreLocation
import Foundation

struct AMapPlaceSearch {
    static let preferenceKey = "usesAMapPlaceSearch"
    static let configured: Self? = {
        #if DEBUG
        if let key = Bundle.main.object(forInfoDictionaryKey: "ArrivalAMapSearchKey") as? String,
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(key: key)
        }
        #endif
        return nil
    }()

    private static let session = URLSession(configuration: .ephemeral)
    private let key: String

    func suggestions(for query: String) async throws -> [Entry] {
        let response = try await request(path: "/v3/assistant/inputtips", query: query, options: [
            .init(name: "datatype", value: "poi")
        ])
        return Array((response.tips ?? []).filter { !$0.name.isEmpty }.prefix(8))
    }

    func results(for query: String) async throws -> [ArrivalDestination] {
        let response = try await request(path: "/v3/place/text", query: query, options: [
            .init(name: "offset", value: "12")
        ])
        return (response.pois ?? []).compactMap(\.destination)
    }

    private func request(path: String, query: String, options: [URLQueryItem]) async throws -> Response {
        let parts = query.replacingOccurrences(of: "＋", with: "+").split(separator: "+", maxSplits: 1)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "restapi.amap.com"
        components.path = path
        components.queryItems = options + [
            .init(name: "key", value: key),
            .init(name: "keywords", value: parts.last.map(String.init) ?? query),
            .init(name: "output", value: "JSON")
        ]
        if parts.count == 2 {
            components.queryItems?.append(.init(name: "city", value: String(parts[0])))
        }
        guard let url = components.url else { throw URLError(.badURL) }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.status == "1" else { throw URLError(.badServerResponse) }
        return decoded
    }

    private struct Response: Decodable {
        let status: String
        let tips: [Entry]?
        let pois: [Entry]?
    }

    struct Entry: Decodable, Identifiable {
        let id = UUID()
        let name: String
        let address: String?
        private let location: String?
        private let category: String?

        private enum CodingKeys: String, CodingKey {
            case name, address, location, type, district, cityname, adname
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? values.decode(String.self, forKey: .name)) ?? ""
            location = try? values.decode(String.self, forKey: .location)
            category = try? values.decode(String.self, forKey: .type)
            let parts = [CodingKeys.district, .cityname, .adname, .address]
                .compactMap { try? values.decode(String.self, forKey: $0) }
                .filter { !$0.isEmpty }
            address = parts.isEmpty ? nil : parts.joined()
        }

        var destination: ArrivalDestination? {
            guard !name.isEmpty, let parts = location?.split(separator: ","), parts.count == 2,
                  let longitude = Double(parts[0]), let latitude = Double(parts[1]) else { return nil }
            let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(point) else { return nil }
            return ArrivalDestination(
                name: name, address: address, coordinate: PlaceCoordinateTransform.fromGCJ02(point),
                isPublicTransport: category?.contains("地铁站") == true
            )
        }
    }
}
