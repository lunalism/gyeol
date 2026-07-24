import Foundation

/// Project-wide render settings.
///
/// Nothing beyond frame rate and render dimensions on purpose: v1 exposes
/// no color space and no audio sample rate, and an unused field invites
/// someone to wire it up.
public struct ProjectSettings: Hashable, Sendable {
    public var frameRate: FrameRate
    public var renderWidth: Int32 {
        didSet { precondition(renderWidth > 0, "renderWidth must be positive") }
    }
    public var renderHeight: Int32 {
        didSet { precondition(renderHeight > 0, "renderHeight must be positive") }
    }

    public init(frameRate: FrameRate, renderWidth: Int32, renderHeight: Int32) {
        precondition(renderWidth > 0, "renderWidth must be positive")
        precondition(renderHeight > 0, "renderHeight must be positive")
        self.frameRate = frameRate
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
    }
}

extension ProjectSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case frameRate, renderWidth, renderHeight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int32.self, forKey: .renderWidth)
        guard width > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .renderWidth, in: container,
                debugDescription: "renderWidth must be positive, got \(width)")
        }
        let height = try container.decode(Int32.self, forKey: .renderHeight)
        guard height > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .renderHeight, in: container,
                debugDescription: "renderHeight must be positive, got \(height)")
        }
        self.frameRate = try container.decode(FrameRate.self, forKey: .frameRate)
        self.renderWidth = width
        self.renderHeight = height
    }
}
