import Foundation

/// Reads a saved setting written by an earlier version: what it holds is laid over today's defaults, so a field added
/// since (a new filter, say) takes its default instead of the whole setting being thrown away.
public enum LenientJSON {
    public static func decode<T: Codable>(_ type: T.Type, from data: Data, over fallback: T) -> T {
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        guard let base = (try? JSONEncoder().encode(fallback)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }),
              let saved = try? JSONSerialization.jsonObject(with: data),
              let merged = try? JSONSerialization.data(withJSONObject: overlay(saved, on: base))
        else { return fallback }
        return (try? JSONDecoder().decode(type, from: merged)) ?? fallback
    }

    /// Saved values over the defaults, object by object; anything else is the saved value.
    static func overlay(_ saved: Any, on base: Any) -> Any {
        guard var object = base as? [String: Any], let savedObject = saved as? [String: Any] else { return saved }
        for (key, value) in savedObject {
            object[key] = object[key].map { overlay(value, on: $0) } ?? value
        }
        return object
    }
}
