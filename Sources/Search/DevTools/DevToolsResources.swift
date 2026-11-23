import Foundation

enum DevToolsResources {
    private static let folder = Bundle.module.resourceURL?.appendingPathComponent("Resources", isDirectory: true)

    static func script(_ name: String) -> String {
        if let url = resource(name, in: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        assertionFailure("Missing DevTools script: \(name)")
        return ""
    }

    static func decode<Value: Decodable>(_ type: Value.Type, named name: String) -> Value? {
        if let url = resource(name, in: "data"),
           let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder().decode(type, from: data) {
            return value
        }
        assertionFailure("Missing or invalid DevTools data: \(name)")
        return nil
    }

    private static func resource(_ name: String, in directory: String) -> URL? {
        folder?.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(name)
    }
}
