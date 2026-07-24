import Foundation

/// One applied effect: an identifier plus its parameter tree.
///
/// Parameters are preserved verbatim even when `identifier` is unknown to
/// this build — this is the only place in the schema where unknown data
/// survives a load/save cycle. Nothing here normalizes, reorders, or drops
/// anything; `GyeolValue` carries the tree untouched.
///
/// There is deliberately no enabled/bypass flag: v1 has no effect UI to
/// toggle one, and a dormant flag in the schema is a compatibility burden
/// with no reader.
public struct EffectInstance: Codable, Hashable, Sendable {
    public var identifier: String
    public var parameters: GyeolValue

    public init(identifier: String, parameters: GyeolValue) {
        self.identifier = identifier
        self.parameters = parameters
    }
}
