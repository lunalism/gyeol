import AudioFixtureKit
import Foundation

// Usage:
//   audio-fixture-gen <output-directory>
//
// Writes the three PCM WAV media files and the six .gyeol packages of
// 부록 A-38's audio verification set. The canonical output directory is
// `fixtures/audio/` at the repository root: the media there is gitignored
// (megabytes, regenerable) and the six packages are committed.

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: audio-fixture-gen <output-directory>\n".utf8))
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let report = try AudioFixtures.generate(into: outDir)

for media in report.media {
    print("""
    media  \(media.spec.fileName)  \(media.spec.sampleRate) Hz  \
    \(media.spec.sampleCount) samples  \(media.byteSize) bytes  \
    sha256=\(media.fileDigest.map { String(format: "%02x", $0) }.joined())
    """)
}
for package in report.packages {
    print("doc    \(package.lastPathComponent)")
}
print("""
click-control      quarter period: \(AudioFixtures.quarterPeriodTicks) ticks, \
residual \(AudioFixtures.quarterPeriodResidualTicks.numerator)/\
\(AudioFixtures.quarterPeriodResidualTicks.denominator) tick
click-control-weak half period:    \(AudioFixtures.halfPeriodTicks) ticks, \
residual +\(AudioFixtures.halfPeriodResidualTicks.numerator)/\
\(AudioFixtures.halfPeriodResidualTicks.denominator) tick
""")
