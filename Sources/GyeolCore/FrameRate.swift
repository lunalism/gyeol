import Foundation

/// The closed set of supported frame rates.
///
/// Deliberately not a free-form number: §4.1 requires the time→frame
/// mapping (L1) to be tested against exactly this set, and an arbitrary
/// rate would have no test backing it. Adding a case here means adding it
/// to the L1 test matrix.
///
/// Encodes as a stable string identifier (`"23.976"`, `"24"`, …), not an
/// index (reordering would corrupt every document) or a float (the schema
/// has none). The synthesized Codable throws on an unknown identifier.
///
/// No time-to-frame conversion lives here — that is L1 (`FrameMapping`).
public enum FrameRate: String, Codable, CaseIterable, Hashable, Sendable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97 = "29.97"
    case fps30 = "30"
    case fps50 = "50"
    case fps59_94 = "59.94"
    case fps60 = "60"

    /// The exact duration of one frame, as a rational.
    ///
    /// NTSC rates are exact fractions — 23.976 fps is exactly 24000/1001
    /// frames per second, so one frame lasts 1001/24000 s. Never the
    /// decimal approximation: 1/23.976 in binary floating point is what
    /// desynchronizes preview from export.
    public var frameDuration: RationalTime {
        switch self {
        case .fps23_976: RationalTime(unchecked: 1001, timescale: 24_000)
        case .fps24: RationalTime(unchecked: 1, timescale: 24)
        case .fps25: RationalTime(unchecked: 1, timescale: 25)
        case .fps29_97: RationalTime(unchecked: 1001, timescale: 30_000)
        case .fps30: RationalTime(unchecked: 1, timescale: 30)
        case .fps50: RationalTime(unchecked: 1, timescale: 50)
        case .fps59_94: RationalTime(unchecked: 1001, timescale: 60_000)
        case .fps60: RationalTime(unchecked: 1, timescale: 60)
        }
    }
}
