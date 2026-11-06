import Foundation

/// Plex responses vary between server versions (numbers as strings, single objects
/// where arrays are expected). These helpers read whatever arrives and never let one
/// odd field throw away a whole library.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Decodes any JSON value and discards it. Used to step past elements that failed to decode.
private struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
}

extension KeyedDecodingContainer where Key == AnyKey {
    func string(_ key: String) -> String? {
        let k = AnyKey(key)
        if let v = try? decodeIfPresent(String.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return String(v) }
        return nil
    }

    func int(_ key: String) -> Int? {
        let k = AnyKey(key)
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }

    func double(_ key: String) -> Double? {
        let k = AnyKey(key)
        if let v = try? decodeIfPresent(Double.self, forKey: k) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Double(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        let k = AnyKey(key)
        if let v = try? decodeIfPresent(Bool.self, forKey: k) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: k) { return v != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s == "1" || s.lowercased() == "true" }
        return nil
    }

    /// Decodes an array element by element, skipping the ones that fail.
    /// Also accepts a single object where an array was expected.
    func list<T: Decodable>(_ key: String) -> [T] {
        let k = AnyKey(key)
        if var array = try? nestedUnkeyedContainer(forKey: k) {
            var out: [T] = []
            while !array.isAtEnd {
                if let value = try? array.decode(T.self) {
                    out.append(value)
                } else if (try? array.decode(Skip.self)) == nil {
                    break
                }
            }
            return out
        }
        if let single = try? decodeIfPresent(T.self, forKey: k) { return [single] }
        return []
    }

    /// Plex tag arrays look like `[{"tag": "Drama"}]`.
    func tags(_ key: String) -> [String] {
        (list(key) as [PlexTag]).map(\.tag).filter { !$0.isEmpty }
    }
}

struct PlexTag: Decodable {
    let tag: String
    init(from decoder: Decoder) throws {
        tag = try decoder.container(keyedBy: AnyKey.self).string("tag") ?? ""
    }
}

/// A top-level JSON array decoded leniently.
struct LossyArray<T: Decodable>: Decodable {
    let items: [T]
    init(from decoder: Decoder) throws {
        var array = try decoder.unkeyedContainer()
        var out: [T] = []
        while !array.isAtEnd {
            if let value = try? array.decode(T.self) {
                out.append(value)
            } else if (try? array.decode(Skip.self)) == nil {
                break
            }
        }
        items = out
    }
}

func missingField(_ name: String, _ decoder: Decoder) -> DecodingError {
    .keyNotFound(AnyKey(name), .init(codingPath: decoder.codingPath, debugDescription: "Missing \(name)"))
}
