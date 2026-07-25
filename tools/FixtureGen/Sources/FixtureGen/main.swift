import AVFoundation
import CryptoKit
import Foundation

// Usage: FixtureGen <output-directory>
// Writes clip24.mov (24fps, 96 frames, frame number burned in as gray
// level) and Mixed.gyeol beside it: 30fps project, clip at 0.5s, stored
// duration 4.5s (0.5s leading empty + 4s clip + trailing none? clip 4s →
// content end 4.5s, duration 5s → 0.5s trailing space).

guard CommandLine.arguments.count > 1 else {
    print("usage: FixtureGen <output-directory>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let mediaURL = outDir.appendingPathComponent("clip24.mov")

let writer = try AVAssetWriter(outputURL: mediaURL, fileType: .mov)
try? FileManager.default.removeItem(at: mediaURL)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 1280,
    AVVideoHeightKey: 720,
])
input.expectsMediaDataInRealTime = false
input.mediaTimeScale = 24
writer.movieTimeScale = 24
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 1280,
        kCVPixelBufferHeightKey as String: 720,
    ])
writer.add(input)
guard writer.startWriting() else { fatalError("\(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
for n in 0..<96 {  // 4 s at 24fps
    while !input.isReadyForMoreMediaData { usleep(2000) }
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
}
input.markAsFinished()
let group = DispatchGroup()
group.enter()
writer.finishWriting { group.leave() }
group.wait()
guard writer.status == .completed else { fatalError("\(String(describing: writer.error))") }

// Fingerprint: same algorithm as MediaResolver (SHA-256 over first 4 MiB
// + byte size).
let attrs = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
let size = attrs[.size] as! Int64
let handle = try FileHandle(forReadingFrom: mediaURL)
let prefix = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
try handle.close()
let digest = Data(SHA256.hash(data: prefix)).base64EncodedString()

let mediaID = "AAAAAAAA-3333-4333-8333-000000000001"
let body = """
{
  "duration" : 600000,
  "markers" : [],
  "media" : {
    "\(mediaID)" : {
      "contentFingerprint" : { "byteSize" : \(size), "value" : "\(digest)" },
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
