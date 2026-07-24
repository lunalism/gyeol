import Foundation
import Testing
@testable import GyeolCore

@Suite struct FrameRateTests {
    @Test(arguments: FrameRate.allCases)
    func roundTripsAsStableString(rate: FrameRate) throws {
        let encoder = GyeolCoding.makeEncoder()
        let data1 = try encoder.encode([rate])
        let decoded = try GyeolCoding.makeDecoder().decode([FrameRate].self, from: data1)
        #expect(decoded == [rate])
        #expect(try encoder.encode(decoded) == data1)
        #expect(String(decoding: data1, as: UTF8.self).contains("\"\(rate.rawValue)\""))
    }

    @Test func frameDurationsAreExactRationals() throws {
        func rt(_ value: Int64, _ timescale: Int32) throws -> RationalTime {
            try RationalTime(value: value, timescale: timescale)
        }
        // NTSC rates as exact fractions, never decimal approximations.
        #expect(try FrameRate.fps23_976.frameDuration == rt(1001, 24_000))
        #expect(try FrameRate.fps24.frameDuration == rt(1, 24))
        #expect(try FrameRate.fps25.frameDuration == rt(1, 25))
        #expect(try FrameRate.fps29_97.frameDuration == rt(1001, 30_000))
        #expect(try FrameRate.fps30.frameDuration == rt(1, 30))
        #expect(try FrameRate.fps50.frameDuration == rt(1, 50))
        #expect(try FrameRate.fps59_94.frameDuration == rt(1001, 60_000))
        #expect(try FrameRate.fps60.frameDuration == rt(1, 60))
    }

    @Test(arguments: FrameRate.allCases)
    func everyFrameDurationIsIntegerTicksAtDocumentTimescale(rate: FrameRate) throws {
        // The reason the project timescale is 120000: every supported rate's
        // frame duration must be an integer tick count.
        let ticks = try rate.frameDuration.converted(to: DocumentTime.timescale)
        #expect(ticks.timescale == 120_000)
        #expect(ticks.value > 0)
    }

    @Test func unknownIdentifierThrows() {
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode([FrameRate].self, from: Data(#"["31"]"#.utf8))
        }
        // An index or float never decodes — the identifier is a string.
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode([FrameRate].self, from: Data(#"[0]"#.utf8))
        }
    }
}

@Suite struct ProjectSettingsTests {
    @Test func byteIdentityRoundTrip() throws {
        let encoder = GyeolCoding.makeEncoder()
        let settings = ProjectSettings(frameRate: .fps59_94, renderWidth: 1080, renderHeight: 1920)
        let data1 = try encoder.encode(settings)
        let decoded = try GyeolCoding.makeDecoder().decode(ProjectSettings.self, from: data1)
        #expect(decoded == settings)
        #expect(try encoder.encode(decoded) == data1)
    }

    @Test(arguments: [
        #"{"frameRate": "30", "renderWidth": 0, "renderHeight": 1080}"#,
        #"{"frameRate": "30", "renderWidth": 1920, "renderHeight": -1}"#,
        #"{"frameRate": "31", "renderWidth": 1920, "renderHeight": 1080}"#,  // unknown rate
    ])
    func invalidSettingsThrowAtDecode(json: String) {
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        }
    }
}
