import Foundation

/// A password or code in memory. It can't be printed, logged, mirrored or encoded by accident: it
/// isn't Codable, and every description prints a placeholder. The only way out is `reveal()`, and only
/// the code that hands a value to a browser or to the fake helper calls it.
public struct Secret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable, Equatable, Sendable {
    private let value: String
    public init(_ value: String) { self.value = value }
    public func reveal() -> String { value }
    public var isEmpty: Bool { value.isEmpty }
    public var description: String { "<secret>" }
    public var debugDescription: String { "<secret>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct Credential: Sendable {
    public var username: String
    public var password: Secret
    public init(username: String, password: Secret) {
        self.username = username
        self.password = password
    }
}
