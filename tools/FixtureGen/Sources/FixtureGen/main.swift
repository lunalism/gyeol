import AVFoundation
import CryptoKit
import Foundation
import GyeolCore

// Usage:
//   FixtureGen <output-directory>              — M2.1 GUI-walkthrough fixture
//   FixtureGen <output-directory> --three-hour — M2.2 virtualization fixture
//
// M2.1 mode writes clip24.mov (24fps, 96 frames, gray ramp) and Mixed.gyeol:
// 30fps project, clip at 0.5s, trailing space after the clip.
//
// M2.2 mode writes clip10s24.mov (24fps, 10 s, 240 frames, with a stereo
// tone audio track) and ThreeHour.gyeol: a 3-hour 30fps project whose ONE
// media source is referenced 1,000 times across the fixed 3+2 tracks, plus
// 3,600 subtitle segments and 60 markers.
//
// WHY one small source × 1,000 references, not a real 3-hour file: this is
// the shape of real projects — few sources, many cuts — and it works the
// per-clip path (query, layout, draw) HARDER while keeping the repository
// small. NOTE: this fixture does NOT exercise the decode path. A single 10s
// H.264 source decodes trivially no matter how often it is referenced.
// That is deliberate — M2.2 measures virtualization (visible-range queries,
// draw time, resident memory), not decoding; decode was measured in M1.4.
//
// The mixed-rate property of the M2.1 fixture is kept: a 30fps PROJECT
// holding 24fps CLIPS, so §6.2's source-rate/project-rate separation keeps
// its consumer in every fixture consumer downstream.

guard CommandLine.arguments.count > 1 else {
    print("usage: FixtureGen <output-directory> [--three-hour]")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let threeHourMode = CommandLine.arguments.contains("--three-hour")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Source media writer

/// Writes an H.264 movie at 24fps with the frame number encoded as a gray
/// ramp, optionally with a 48 kHz stereo Int16 tone track whose amplitude
/// envelope varies over time (so waveform peaks are visibly non-constant).
func writeSource(to mediaURL: URL, frameCount: Int, includeAudio: Bool) throws {
    try? FileManager.default.removeItem(at: mediaURL)
    let writer = try AVAssetWriter(outputURL: mediaURL, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 1280,
        AVVideoHeightKey: 720,
    ])
    video.expectsMediaDataInRealTime = false
    video.mediaTimeScale = 24
    writer.movieTimeScale = 24
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: video,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280,
            kCVPixelBufferHeightKey as String: 720,
        ])
    writer.add(video)

    var audio: AVAssetWriterInput?
    if includeAudio {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        audio = input
    }

    guard writer.startWriting() else { fatalError("\(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    // INTERLEAVED appends: writing one whole track before the other
    // deadlocks — the writer stalls isReadyForMoreMediaData on the first
    // input waiting for the other track's data to interleave (measured:
    // the all-video-then-all-audio order hung this tool). Alternate in
    // ~0.5 s slices instead.
    let sampleRate = 48_000
    let totalAudioFrames = audio == nil ? 0 : frameCount * sampleRate / 24
    var audioFormat: CMAudioFormatDescription?
    if audio != nil {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &audioFormat) == noErr, audioFormat != nil else {
            fatalError("audio format description failed")
        }
    }

    func appendAudioChunk(startFrame: Int, count: Int) {
        guard let audio, let audioFormat else { return }
        while !audio.isReadyForMoreMediaData { usleep(2000) }
        var samples = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count {
            let t = Double(startFrame + i) / Double(sampleRate)
            // 220 Hz tone under a slow amplitude envelope: peaks differ
            // tile to tile, so a mipmap that samples the wrong region is
            // visibly wrong instead of coincidentally right.
            let envelope = 0.2 + 0.8 * abs(sin(.pi * t / 2.5))
            let value = Int16(max(-32767, min(32767, envelope * 30_000 * sin(2 * .pi * 220 * t))))
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { fatalError("block buffer failed") }
        samples.withUnsafeBytes { raw in
            guard CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount) == noErr else {
                fatalError("block buffer fill failed")
            }
        }
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: audioFormat,
            sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: Int32(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer else { fatalError("sample buffer failed") }
        guard audio.append(sampleBuffer) else {
            fatalError("\(String(describing: writer.error))")
        }
    }

    var audioWritten = 0
    for n in 0..<frameCount {
        while !video.isReadyForMoreMediaData { usleep(2000) }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &maybeBuffer)
        let buffer = maybeBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        // Visible motion: brightness ramps per frame so playback is obvious.
        memset(CVPixelBufferGetBaseAddress(buffer), Int32((n * 2) % 255), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 24)) else {
            fatalError("\(String(describing: writer.error))")
        }
        // Keep audio caught up to the video timeline, half-second slices.
        let audioTarget = min(totalAudioFrames, (n + 1) * sampleRate / 24)
        while audioWritten < audioTarget {
            let count = min(sampleRate / 2, audioTarget - audioWritten)
            appendAudioChunk(startFrame: audioWritten, count: count)
            audioWritten += count
        }
    }
    video.markAsFinished()
    audio?.markAsFinished()

    let group = DispatchGroup()
    group.enter()
    writer.finishWriting { group.leave() }
    group.wait()
    guard writer.status == .completed else { fatalError("\(String(describing: writer.error))") }
}

/// Same algorithm as MediaResolver: SHA-256 over the first 4 MiB + size.
func fingerprint(of mediaURL: URL) throws -> (digestBase64: String, size: Int64, raw: Data) {
    let attrs = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
    let size = attrs[.size] as! Int64
    let handle = try FileHandle(forReadingFrom: mediaURL)
    let prefix = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
    try handle.close()
    let digest = Data(SHA256.hash(data: prefix))
    return (digest.base64EncodedString(), size, digest)
}

// MARK: - M2.2 three-hour fixture

if threeHourMode {
    let mediaURL = outDir.appendingPathComponent("clip10s24.mov")
    try writeSource(to: mediaURL, frameCount: 240, includeAudio: true)  // 10 s at 24fps
    let print3 = try fingerprint(of: mediaURL)

    func ticks(seconds: Int64) -> DocumentTime {
        DocumentTime(exactly: try! RationalTime(value: seconds * 120_000, timescale: 120_000))!
    }
    func ticksExact(_ raw: Int64) -> DocumentTime {
        DocumentTime(exactly: try! RationalTime(value: raw, timescale: 120_000))!
    }
    func uuid(_ prefix: String, _ n: Int) -> UUID {
        UUID(uuidString: String(format: "\(prefix)-2222-4222-8222-%012d", n))!
    }

    let mediaID = MediaID(rawValue: uuid("AAAAAAAA", 1))
    let clipDuration = ticks(seconds: 10)

    var clipSerial = 0
    func clips(count: Int, spacingSeconds: Int64) -> [Clip] {
        (0..<count).map { i in
            clipSerial += 1
            return Clip(
                id: ClipID(rawValue: uuid("CCCCCCCC", clipSerial)),
                timelineStart: ticks(seconds: Int64(i) * spacingSeconds),
                duration: clipDuration,
                source: .media(MediaSource(mediaID: mediaID, sourceStart: .zero)))
        }
    }

    // 1,000 references across the fixed 3+2 layout. V0 carries the bulk
    // back-to-back-ish (10 s clips every 12 s — real cut density), the
    // upper video tracks are sparse overlays, and the audio tracks give the
    // waveform cache real consumers. Total = 900+40+20+30+10 = 1,000.
    let tracks = [
        Track(id: TrackID(rawValue: uuid("BBBBBBBB", 1)), kind: .video,
              clips: clips(count: 900, spacingSeconds: 12)),
        Track(id: TrackID(rawValue: uuid("BBBBBBBB", 2)), kind: .video,
              clips: clips(count: 40, spacingSeconds: 270)),
        Track(id: TrackID(rawValue: uuid("BBBBBBBB", 3)), kind: .video,
              clips: clips(count: 20, spacingSeconds: 540)),
        Track(id: TrackID(rawValue: uuid("BBBBBBBB", 4)), kind: .audio,
              clips: clips(count: 30, spacingSeconds: 360)),
        Track(id: TrackID(rawValue: uuid("BBBBBBBB", 5)), kind: .audio,
              clips: clips(count: 10, spacingSeconds: 1_080)),
    ]

    // 3,600 segments, one every 3 s across the full 3 hours. Every 50th is
    // 15 s long — overlapping the next four — so the overlap-aware query
    // correction (maxSubtitleDuration) has real work; the rest are 2.8 s.
    let subtitles = (0..<3_600).map { i in
        SubtitleSegment(
            id: SubtitleID(rawValue: uuid("DDDDDDDD", i + 1)),
            start: ticks(seconds: Int64(i) * 3),
            duration: i.isMultiple(of: 50) ? ticks(seconds: 15) : ticksExact(336_000),
            text: "Segment \(i) — 자막 픽스처")
    }

    let markers = (0..<60).map { i in
        Marker(
            id: MarkerID(rawValue: uuid("EEEEEEEE", i + 1)),
            time: ticks(seconds: Int64(i) * 180),
            label: "M\(i)")
    }

    let document = GyeolDocument(
        schemaVersion: .current,
        settings: ProjectSettings(frameRate: .fps30, renderWidth: 1280, renderHeight: 720),
        media: [mediaID: MediaReference(
            relativePath: "clip10s24.mov",
            contentFingerprint: ContentFingerprint(value: print3.raw, byteSize: print3.size),
            displayName: "clip10s24.mov",
            duration: clipDuration)],
        tracks: tracks,
        duration: ticks(seconds: 10_800),  // exactly 3 h; trailing space past the last clip end
        subtitles: subtitles,
        markers: markers)

    let packageURL = outDir.appendingPathComponent("ThreeHour.gyeol")
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try GyeolCoding.makeEncoder().encode(document)
        .write(to: packageURL.appendingPathComponent("document.json"))
    print("fixture written: \(packageURL.path)")
    print("media: \(mediaURL.path) (open the package with the media beside it)")
    exit(0)
}

// MARK: - M2.1 mixed-rate fixture (unchanged behavior)

let mediaURL = outDir.appendingPathComponent("clip24.mov")
try writeSource(to: mediaURL, frameCount: 96, includeAudio: false)  // 4 s at 24fps
let printM = try fingerprint(of: mediaURL)

let mediaID = "AAAAAAAA-3333-4333-8333-000000000001"
let body = """
{
  "duration" : 600000,
  "markers" : [],
  "media" : {
    "\(mediaID)" : {
      "contentFingerprint" : { "byteSize" : \(printM.size), "value" : "\(printM.digestBase64)" },
      "displayName" : "clip24.mov",
      "duration" : 480000,
      "relativePath" : "clip24.mov"
    }
  },
  "schemaVersion" : { "major" : 1, "minor" : 0 },
  "settings" : { "frameRate" : "30", "renderHeight" : 720, "renderWidth" : 1280 },
  "subtitleStyle" : {
    "fontSize" : 500,
    "outlineColor" : { "alpha" : 255, "blue" : 0, "green" : 0, "red" : 0 },
    "outlineWidth" : 40,
    "position" : { "x" : 5000, "y" : 9000 },
    "textColor" : { "alpha" : 255, "blue" : 255, "green" : 255, "red" : 255 }
  },
  "subtitles" : [],
  "tracks" : [
    {
      "clips" : [
        {
          "audio" : { "fadeIn" : 0, "fadeOut" : 0, "volume" : 10000 },
          "duration" : 480000,
          "effects" : [],
          "id" : "CCCCCCCC-3333-4333-8333-000000000001",
          "source" : { "kind" : "media", "mediaID" : "\(mediaID)", "sourceStart" : 0 },
          "timelineStart" : 60000
        }
      ],
      "id" : "BBBBBBBB-3333-4333-8333-000000000001",
      "isMuted" : false,
      "kind" : "video"
    }
  ]
}
"""
let packageURL = outDir.appendingPathComponent("Mixed.gyeol")
try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
try Data(body.utf8).write(to: packageURL.appendingPathComponent("document.json"))
print("fixture written: \(packageURL.path)")
print("media: \(mediaURL.path) (open the package with the media beside it)")
