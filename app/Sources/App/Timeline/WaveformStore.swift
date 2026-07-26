import AVFoundation
import Foundation
import os

/// The waveform peak cache (PRD §7.4-2, D28): mipmap levels over fixed-size
/// tiles, keyed by CONTENT HASH, stored OUTSIDE the document under
/// `~/Library/Caches/dev.gyeol.Gyeol/waveforms/`. Everything here is
/// recomputable from the source media, so the OS emptying Caches costs one
/// recomputation, never data.
///
/// RENDERING NEVER WAITS ON IO (§5.2): `tile(...)` answers from memory or
/// returns nil, scheduling the disk read / computation in the background;
/// the renderer draws the region empty and `onUpdate` triggers a redraw
/// when the tile lands. Async tile arrival is exactly the statefulness
/// §7.4-3 exempts the timeline view from.
///
/// NUMBERS (D28 fixes the structure only; these were chosen in M2.2 and
/// reported in the milestone write-up):
///
/// - Base resolution 512 samples/peak (the 부록 C assumption).
/// - Tile = 1,024 peaks (4 KiB): small enough that one visible clip touches
///   a handful, large enough that a 3-hour level-0 chain is ~1,000 tiles.
/// - Mipmap levels halve until a level fits one tile, so any zoom picks a
///   level with ≥ 1 peak per point and bounded tile count.
/// - Memory bound 32 MiB, LRU by tile: a full 3-hour mono chain is ~8 MiB
///   (부록 C's 16 MB is stereo; we fold to mono for the lane), so the bound
///   holds two whole 3-hour projects — a single project can never evict its
///   own working set — while staying irrelevant next to the 310 MB thumbnail
///   problem deferred to M2.4.
///
/// PTS RULE (§5.3, §7.4-2): peaks are indexed by the sample position DERIVED
/// FROM EACH BUFFER'S PTS, not by arrival order. Min/max folding into a
/// bucket is order-independent, so this is "sort by PTS before recording"
/// without the sort — a decoder returning buffers in any order lands every
/// sample in the right bucket.
@MainActor
final class WaveformStore {
    static let shared = WaveformStore()

    nonisolated static let samplesPerPeakBase = 512
    nonisolated static let peaksPerTile = 1024
    nonisolated static let memoryLimitBytes = 32 * 1024 * 1024

    nonisolated struct Peak {
        var minValue: Int16
        var maxValue: Int16
    }

    nonisolated struct Meta {
        let sampleRate: Double
        let sampleCount: Int64
        /// Number of mipmap levels; level k covers 512·2^k samples per peak.
        let levelCount: Int

        func peakCount(level: Int) -> Int {
            let samplesPerPeak = Int64(WaveformStore.samplesPerPeakBase) << level
            return Int((sampleCount + samplesPerPeak - 1) / samplesPerPeak)
        }
    }

    nonisolated private struct TileKey: Hashable {
        let mediaKey: String
        let level: Int
        let index: Int
    }

    private let log = Logger(subsystem: "dev.gyeol.Gyeol", category: "Waveform")
    private var metas: [String: Meta] = [:]
    private var tiles: [TileKey: [Peak]] = [:]
    private var lastUse: [TileKey: UInt64] = [:]
    private var useClock: UInt64 = 0
    private var totalPeakBytes = 0
    private var inFlight: Set<String> = []
    private var tileLoadsInFlight: Set<TileKey> = []

    /// Posted on the main actor whenever a tile or meta arrives; every
    /// document window's timeline answers with setNeedsDisplay. NOTE (PRD
    /// 부록 A-36): paths that rely on this asynchronous arrival may be
    /// unreliable under HEADLESS xctest — a window that never appears has
    /// been measured not cancelling (or running) SwiftUI/main-queue work on
    /// schedule. Tests cover the synchronous math via `injectForTesting`;
    /// the async arrival is exercised in the running app.
    nonisolated static let didUpdateNotification = Notification.Name("dev.gyeol.Gyeol.waveformDidUpdate")

    private func postUpdate() {
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    private let cacheRoot = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.gyeol.Gyeol/waveforms", isDirectory: true)

    // MARK: - Queries (memory-only, never blocking)

    func meta(mediaKey: String, mediaURL: URL) -> Meta? {
        if let meta = metas[mediaKey] { return meta }
        beginComputeIfNeeded(mediaKey: mediaKey, mediaURL: mediaURL)
        return nil
    }

    /// The tile, if resident. A miss schedules the disk read (or the full
    /// computation when the cache directory has nothing) and returns nil —
    /// the caller draws empty and repaints on `onUpdate`.
    func tile(mediaKey: String, level: Int, index: Int, mediaURL: URL) -> [Peak]? {
        let key = TileKey(mediaKey: mediaKey, level: level, index: index)
        if let tile = tiles[key] {
            useClock += 1
            lastUse[key] = useClock
            return tile
        }
        guard let meta = metas[mediaKey] else {
            beginComputeIfNeeded(mediaKey: mediaKey, mediaURL: mediaURL)
            return nil
        }
        scheduleTileLoad(key: key, meta: meta)
        return nil
    }

    // MARK: - Tile load (disk → memory)

    private func scheduleTileLoad(key: TileKey, meta: Meta) {
        guard !tileLoadsInFlight.contains(key) else { return }
        tileLoadsInFlight.insert(key)
        let url = levelFileURL(mediaKey: key.mediaKey, level: key.level)
        let peakCount = meta.peakCount(level: key.level)
        let start = key.index * Self.peaksPerTile
        guard start < peakCount else {
            tileLoadsInFlight.remove(key)
            return
        }
        let count = min(Self.peaksPerTile, peakCount - start)
        Task.detached(priority: .utility) {
            let loaded: [Peak]? = Self.readPeaks(from: url, startPeak: start, count: count)
            await MainActor.run {
                self.tileLoadsInFlight.remove(key)
                if let loaded {
                    self.insertTile(key: key, peaks: loaded)
                    self.postUpdate()
                }
            }
        }
    }

    private nonisolated static func readPeaks(from url: URL, startPeak: Int, count: Int) -> [Peak]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let recordSize = 4  // Int16 min + Int16 max, little endian
        guard (try? handle.seek(toOffset: UInt64(startPeak * recordSize))) != nil,
              let data = try? handle.read(upToCount: count * recordSize),
              data.count == count * recordSize else { return nil }
        var peaks = [Peak](repeating: Peak(minValue: 0, maxValue: 0), count: count)
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                peaks[i] = Peak(
                    minValue: Int16(littleEndian: values[i * 2]),
                    maxValue: Int16(littleEndian: values[i * 2 + 1]))
            }
        }
        return peaks
    }

    private func insertTile(key: TileKey, peaks: [Peak]) {
        tiles[key] = peaks
        useClock += 1
        lastUse[key] = useClock
        totalPeakBytes += peaks.count * 4
        // LRU eviction against the byte bound. Linear min-scan per evicted
        // tile: the map holds at most limit/4KiB ≈ 8,000 tiles, evictions
        // are rare (only past the bound), and a heap here would be a cache
        // for the cache.
        while totalPeakBytes > Self.memoryLimitBytes, tiles.count > 1 {
            guard let victim = lastUse.min(by: { $0.value < $1.value })?.key else { break }
            totalPeakBytes -= (tiles[victim]?.count ?? 0) * 4
            tiles[victim] = nil
            lastUse[victim] = nil
        }
    }

    // MARK: - Computation (source → disk, then meta in memory)

    private func beginComputeIfNeeded(mediaKey: String, mediaURL: URL) {
        guard !inFlight.contains(mediaKey) else { return }
        inFlight.insert(mediaKey)
        let root = cacheRoot
        Task.detached(priority: .utility) {
            let meta = await Self.loadOrCompute(mediaKey: mediaKey, mediaURL: mediaURL, root: root)
            await MainActor.run {
                self.inFlight.remove(mediaKey)
                if let meta {
                    self.metas[mediaKey] = meta
                    self.postUpdate()
                }
            }
        }
    }

    private nonisolated static func loadOrCompute(
        mediaKey: String, mediaURL: URL, root: URL
    ) async -> Meta? {
        let dir = root.appendingPathComponent(mediaKey, isDirectory: true)
        let metaURL = dir.appendingPathComponent("meta.plist")
        if let meta = readMeta(at: metaURL) { return meta }
        do {
            return try await compute(mediaURL: mediaURL, into: dir, metaURL: metaURL)
        } catch {
            Logger(subsystem: "dev.gyeol.Gyeol", category: "Waveform")
                .error("waveform computation failed for \(mediaURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private nonisolated static func readMeta(at url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let rate = plist["sampleRate"] as? Double,
              let count = plist["sampleCount"] as? Int64 ?? (plist["sampleCount"] as? Int).map(Int64.init),
              let levels = plist["levelCount"] as? Int else { return nil }
        return Meta(sampleRate: rate, sampleCount: count, levelCount: levels)
    }

    private nonisolated static func compute(
        mediaURL: URL, into dir: URL, metaURL: URL
    ) async throws -> Meta {
        let asset = AVURLAsset(url: mediaURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "no audio track in \(mediaURL.lastPathComponent)"])
        }
        let reader = try AVAssetReader(asset: asset)
        // Decoded PCM, NOT outputSettings nil: nil returns the encoded
        // stream in decode order. Even decoded, the PTS rule below stays —
        // buckets are addressed by each buffer's PTS, never arrival order.
        let sampleRate = 48_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }

        let duration = try await asset.load(.duration)
        let sampleCount = Int64((duration.seconds * sampleRate).rounded(.up))
        let basePeakCount = Int((sampleCount + Int64(samplesPerPeakBase) - 1) / Int64(samplesPerPeakBase))
        var base = [Peak](
            repeating: Peak(minValue: Int16.max, maxValue: Int16.min), count: max(1, basePeakCount))

        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            // PTS-addressed bucket start — the §5.3 ordering rule, enforced
            // by construction instead of a sort.
            let startSample = Int64((pts.seconds * sampleRate).rounded())
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    let idx = startSample + Int64(i)
                    guard idx >= 0 else { continue }
                    let bucket = Int(idx) / samplesPerPeakBase
                    guard bucket < base.count else { break }
                    let v = samples[i]
                    if v < base[bucket].minValue { base[bucket].minValue = v }
                    if v > base[bucket].maxValue { base[bucket].maxValue = v }
                }
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        // Buckets no sample reached (rounding tail) flatten to silence.
        for i in base.indices where base[i].minValue > base[i].maxValue {
            base[i] = Peak(minValue: 0, maxValue: 0)
        }

        // Mipmap chain: halve until one tile holds a whole level.
        var levels: [[Peak]] = [base]
        while levels[levels.count - 1].count > peaksPerTile {
            let previous = levels[levels.count - 1]
            var next = [Peak]()
            next.reserveCapacity((previous.count + 1) / 2)
            var i = 0
            while i < previous.count {
                let a = previous[i]
                let b = i + 1 < previous.count ? previous[i + 1] : a
                next.append(Peak(
                    minValue: min(a.minValue, b.minValue),
                    maxValue: max(a.maxValue, b.maxValue)))
                i += 2
            }
            levels.append(next)
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (level, peaks) in levels.enumerated() {
            var data = Data(capacity: peaks.count * 4)
            for peak in peaks {
                withUnsafeBytes(of: peak.minValue.littleEndian) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: peak.maxValue.littleEndian) { data.append(contentsOf: $0) }
            }
            try data.write(to: dir.appendingPathComponent("level\(level).peaks"))
        }
        let meta = Meta(sampleRate: sampleRate, sampleCount: sampleCount, levelCount: levels.count)
        let plist: [String: Any] = [
            "sampleRate": meta.sampleRate,
            "sampleCount": meta.sampleCount,
            "levelCount": meta.levelCount,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: metaURL)
        return meta
    }

    private func levelFileURL(mediaKey: String, level: Int) -> URL {
        cacheRoot.appendingPathComponent(mediaKey, isDirectory: true)
            .appendingPathComponent("level\(level).peaks")
    }

    // MARK: - Test seam

    /// Direct meta/tile injection so eviction and addressing are testable
    /// without AVFoundation or disk (부록 A-36: async paths are unreliable
    /// under headless xctest).
    func injectForTesting(mediaKey: String, meta: Meta, levelPeaks: [[Peak]]) {
        metas[mediaKey] = meta
        for (level, peaks) in levelPeaks.enumerated() {
            var index = 0
            var offset = 0
            while offset < peaks.count {
                let count = min(Self.peaksPerTile, peaks.count - offset)
                insertTile(
                    key: TileKey(mediaKey: mediaKey, level: level, index: index),
                    peaks: Array(peaks[offset..<offset + count]))
                offset += count
                index += 1
            }
        }
    }

    var residentTileBytesForTesting: Int { totalPeakBytes }
}
