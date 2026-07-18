import Foundation

public enum OriginError: Error, Equatable, Sendable {
    case invalid
}

public enum OriginNormalizer {
    public static func normalize(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw OriginError.invalid
        }

        components.scheme = "https"
        components.host = host
        components.path = ""
        if components.port == 443 {
            components.port = nil
        }
        guard let normalized = components.string,
              URL(string: normalized)?.host != nil
        else {
            throw OriginError.invalid
        }
        return normalized
    }
}
