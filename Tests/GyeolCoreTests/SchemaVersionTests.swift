import Foundation
import Testing
@testable import GyeolCore

private func v(_ major: Int, _ minor: Int) -> SchemaVersion {
    SchemaVersion(major: major, minor: minor)
}

@Suite struct SchemaVersionOrderingTests {
    @Test func majorDominatesMinor() {
        #expect(v(1, 9) < v(2, 0))
        #expect(v(2, 0) > v(1, 9))
        #expect(v(1, 0) < v(1, 1))
        #expect(v(1, 1) == v(1, 1))
        #expect(!(v(1, 1) < v(1, 1)))
    }

    @Test func sortsByMajorThenMinor() {
        let sorted = [v(2, 0), v(1, 3), v(1, 0), v(3, 1), v(1, 2)].sorted()
        #expect(sorted == [v(1, 0), v(1, 2), v(1, 3), v(2, 0), v(3, 1)])
    }
}

@Suite struct SchemaVersionCompatibilityTests {
    let ours = v(2, 3)

    @Test func sameMajorOlderOrEqualMinorIsCompatible() {
        #expect(ours.compatibility(ofFileVersion: v(2, 0)) == .compatible)
        #expect(ours.compatibility(ofFileVersion: v(2, 2)) == .compatible)
        #expect(ours.compatibility(ofFileVersion: v(2, 3)) == .compatible)  // boundary: equal
    }

    @Test func sameMajorNewerMinorIsReadableWithLoss() {
        #expect(ours.compatibility(ofFileVersion: v(2, 4)) == .readableWithLoss)  // boundary: +1
        #expect(ours.compatibility(ofFileVersion: v(2, 99)) == .readableWithLoss)
    }

    @Test func newerMajorIsUnsupported() {
        // Boundary major+1, and minor 0 < ours: a smaller minor does not
        // rescue a newer major.
        #expect(ours.compatibility(ofFileVersion: v(3, 0)) == .unsupported)
        #expect(ours.compatibility(ofFileVersion: v(9, 0)) == .unsupported)
    }

    @Test func olderMajorRequiresMigration() {
        // Boundary major-1, and a large minor does not rescue an older major.
        #expect(ours.compatibility(ofFileVersion: v(1, 0)) == .migrationRequired)
        #expect(ours.compatibility(ofFileVersion: v(1, 99)) == .migrationRequired)
    }

    @Test func currentIsCompatibleWithItself() {
        #expect(SchemaVersion.current.compatibility(ofFileVersion: .current) == .compatible)
    }
}

@Suite struct SchemaVersionPreconditionTests {
    @Test func negativeMajorAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            var version = SchemaVersion(major: 1, minor: 0)
            version.major = -1
        }
    }

    @Test func negativeMinorAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            var version = SchemaVersion(major: 1, minor: 0)
            version.minor = -1
        }
    }
}

@Suite struct SchemaVersionCodableTests {
    @Test func encodesAsObjectWithMajorAndMinor() throws {
        let data = try GyeolCoding.makeEncoder().encode(v(1, 0))
        let json = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(json as? [String: Any])
        #expect(Set(dict.keys) == ["major", "minor"])
        #expect(dict["major"] as? Int == 1)
        #expect(dict["minor"] as? Int == 0)
    }

    @Test func negativeComponentsAreRejectedAtDecode() throws {
        let decoder = GyeolCoding.makeDecoder()
        #expect(throws: (any Error).self) {
            try decoder.decode(SchemaVersion.self, from: Data(#"{"major": 1, "minor": -1}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try decoder.decode(SchemaVersion.self, from: Data(#"{"major": -1, "minor": 0}"#.utf8))
        }
    }

    @Test func zeroZeroIsLegalAtDecode() throws {
        // Only negatives are rejected; 0.0 is a valid version.
        let decoded = try GyeolCoding.makeDecoder().decode(
            SchemaVersion.self, from: Data(#"{"major": 0, "minor": 0}"#.utf8))
        #expect(decoded == v(0, 0))
    }

    @Test(arguments: [SchemaVersion(major: 1, minor: 0), SchemaVersion(major: 2, minor: 17)])
    func byteIdentityRoundTrip(version: SchemaVersion) throws {
        let encoder = GyeolCoding.makeEncoder()
        let data1 = try encoder.encode(version)
        let decoded = try GyeolCoding.makeDecoder().decode(SchemaVersion.self, from: data1)
        #expect(decoded == version)
        #expect(try encoder.encode(decoded) == data1)
    }
}
