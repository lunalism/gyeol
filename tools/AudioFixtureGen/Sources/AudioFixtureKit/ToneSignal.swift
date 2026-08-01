import Foundation

/// One stretch of the generated signal. `amplitude == 0` is silence, and
/// silence still advances the phase accumulator — see `ToneSignal`.
///
/// The duration is whole SECONDS, not samples: every fixture boundary must
/// land on a whole number of tone periods (220 Hz × 1 s = 220 periods), and
/// expressing it in seconds makes that property visible in the spec instead
/// of hidden in a sample count.
public struct ToneSegment: Hashable, Sendable {
    public let seconds: Int
    public let amplitude: Double

    public init(seconds: Int, amplitude: Double) {
        self.seconds = seconds
        self.amplitude = amplitude
    }
}

public enum ToneSignal {
    /// Peak of the Int16 range used for full scale. 32767 rather than 32768
    /// so amplitude 1.0 cannot overflow the positive side.
    public static let fullScale = 32_767.0

    /// Generates the whole file as one continuous oscillator.
    ///
    /// **The phase accumulator is an INTEGER and is never reset.** This is
    /// the single load-bearing property of this generator. A phase reset at
    /// a buffer boundary produces a step discontinuity that sounds exactly
    /// like the cut-point click 부록 A-38 ③ is hunting — the fixture would
    /// then manufacture the very defect it is supposed to detect, and the
    /// human listener has no way to tell the two apart. There is no buffer
    /// boundary here at all: the file is produced in one pass.
    ///
    /// Why integer and not `phase += 2 * .pi * f / sr`: a Double accumulator
    /// drifts, so the file would not end on the zero crossing the spec
    /// claims, and the drift depends on the sample count (i.e. on the
    /// segmentation) rather than on the signal. Counting `(f × i) mod sr`
    /// keeps the argument to `sin` an exact rational multiple of 2π at every
    /// sample, for any sample rate — including 44100, where one 220 Hz
    /// period is 200.4545… samples and therefore never lands on a sample.
    ///
    /// Silence advances the accumulator too, so a tone that resumes after a
    /// silent stretch resumes IN PHASE with where it would have been.
    public static func samples(
        sampleRate: Int,
        frequencyHz: Int,
        segments: [ToneSegment]
    ) -> [Int16] {
        let total = segments.reduce(0) { $0 + $1.seconds * sampleRate }
        var out = [Int16]()
        out.reserveCapacity(total)
        var phase = 0  // (frequencyHz × sampleIndex) mod sampleRate
        for segment in segments {
            let count = segment.seconds * sampleRate
            for _ in 0..<count {
                let value = segment.amplitude
                    * sin(2 * Double.pi * Double(phase) / Double(sampleRate))
                    * fullScale
                out.append(Int16(max(-32_768, min(32_767, value.rounded()))))
                phase = (phase + frequencyHz) % sampleRate
            }
        }
        return out
    }
}
