import Foundation
import Testing
@testable import GyeolCore

private func docTime(_ ticks: Int64) -> DocumentTime {
    DocumentTime(exactly: try! RationalTime(value: ticks, timescale: 120_000))!
}

private func clip(start: Int64, duration: Int64) -> Clip {
    Clip(
        id: ClipID(),
        timelineStart: docTime(start),
        duration: docTime(duration),
        source: .generator(identifier: "test", parameters: .object([:])))
}

private func track(_ clips: [Clip]) -> Track {
    Track(id: TrackID(), kind: .video, clips: clips)
}

private func segment(start: Int64, duration: Int64) -> SubtitleSegment {
    SubtitleSegment(id: SubtitleID(), start: docTime(start), duration: docTime(duration), text: "t")
}

private func marker(_ time: Int64) -> Marker {
    Marker(id: MarkerID(), time: docTime(time), label: "m")
}

@Suite struct VisibleRangeClipTests {
    @Test func emptyTrackYieldsNothing() {
        let result = VisibleRange.visibleClips(in: track([]), from: docTime(0), to: docTime(100))
        #expect(result.isEmpty)
    }

    @Test func emptyOrInvertedViewportYieldsNothing() {
        let t = track([clip(start: 0, duration: 100)])
        #expect(VisibleRange.visibleClips(in: t, from: docTime(50), to: docTime(50)).isEmpty)
        #expect(VisibleRange.visibleClips(in: t, from: docTime(60), to: docTime(50)).isEmpty)
    }

    /// The §5.2 correction: a clip whose start lies LEFT of the viewport but
    /// whose end lies inside must be found by the one-step-back scan.
    @Test func clipStraddlingLeftEdgeIsVisible() {
        let straddler = clip(start: 0, duration: 100)
        let inside = clip(start: 150, duration: 50)
        let t = track([straddler, inside])
        let visible = Array(VisibleRange.visibleClips(in: t, from: docTime(50), to: docTime(200)))
        #expect(visible.map(\.id) == [straddler.id, inside.id])
    }

    /// A clip spanning the whole viewport (starts before, ends after) is the
    /// same one-step-back case seen from both edges.
    @Test func clipSpanningEntireViewportIsVisible() {
        let spanning = clip(start: 0, duration: 1_000)
        let t = track([spanning])
        let visible = Array(VisibleRange.visibleClips(in: t, from: docTime(400), to: docTime(600)))
        #expect(visible.map(\.id) == [spanning.id])
    }

    /// Half-open on both sides: ending exactly at the viewport start, or
    /// starting exactly at the viewport end, is NOT visible.
    @Test func exactBoundaryContactIsNotVisible() {
        let before = clip(start: 0, duration: 100)   // ends exactly at 100
        let after = clip(start: 300, duration: 50)   // starts exactly at 300
        let t = track([before, after])
        let visible = VisibleRange.visibleClips(in: t, from: docTime(100), to: docTime(300))
        #expect(visible.isEmpty)
    }

    /// A clip starting exactly at the viewport start needs no correction and
    /// must not be duplicated by the step-back.
    @Test func clipStartingExactlyAtViewportStart() {
        let exact = clip(start: 100, duration: 50)
        let earlier = clip(start: 0, duration: 100)  // ends exactly at 100 — invisible
        let t = track([earlier, exact])
        let visible = Array(VisibleRange.visibleClips(in: t, from: docTime(100), to: docTime(300)))
        #expect(visible.map(\.id) == [exact.id])
    }

    @Test func middleWindowOfManyClips() {
        // 100 abutting clips of 10 ticks each: [0,10), [10,20), …
        let clips = (0..<100).map { clip(start: Int64($0) * 10, duration: 10) }
        let t = track(clips)
        // Viewport [25, 55): straddler [20,30), then [30,40), [40,50), straddler [50,60).
        let visible = Array(VisibleRange.visibleClips(in: t, from: docTime(25), to: docTime(55)))
        #expect(visible.map(\.timelineStart.ticks) == [20, 30, 40, 50])
    }

    @Test func viewportEntirelyPastAllClipsYieldsNothing() {
        let t = track([clip(start: 0, duration: 100)])
        #expect(VisibleRange.visibleClips(in: t, from: docTime(500), to: docTime(900)).isEmpty)
    }

    @Test func viewportEntirelyBeforeAllClipsYieldsNothing() {
        let t = track([clip(start: 500, duration: 100)])
        #expect(VisibleRange.visibleClips(in: t, from: docTime(0), to: docTime(400)).isEmpty)
    }
}

@Suite struct VisibleRangeSubtitleTests {
    @Test func emptySubtitlesYieldNothing() {
        let result = VisibleRange.visibleSubtitles(
            in: [], from: docTime(0), to: docTime(100), maxSubtitleDuration: docTime(0))
        #expect(Array(result).isEmpty)
    }

    /// The overlap correction: subtitles may overlap, so SEVERAL can
    /// straddle the left edge at once — the clip guarantee (at most one)
    /// does not hold, and maxSubtitleDuration bounds the back-scan instead.
    @Test func multipleStraddlersAreAllFound() {
        let a = segment(start: 0, duration: 300)    // straddles
        let b = segment(start: 50, duration: 300)   // straddles
        let c = segment(start: 90, duration: 50)    // ends at 140, entirely before viewport
        let d = segment(start: 100, duration: 20)   // ends 120, entirely before viewport
        let subtitles = [a, b, c, d]
        let visible = Array(VisibleRange.visibleSubtitles(
            in: subtitles, from: docTime(200), to: docTime(400),
            maxSubtitleDuration: docTime(300)))
        #expect(visible.map(\.id) == [a.id, b.id])
    }

    /// A long segment straddling the viewport is found exactly when
    /// maxSubtitleDuration honors the caller's contract (≥ true maximum).
    @Test func longStraddlerFoundUnderHonestMaxDuration() {
        let long = segment(start: 0, duration: 100_000)
        let visible = Array(VisibleRange.visibleSubtitles(
            in: [long], from: docTime(90_000), to: docTime(95_000),
            maxSubtitleDuration: docTime(100_000)))
        #expect(visible.map(\.id) == [long.id])
    }

    @Test func exactBoundaryContactIsNotVisible() {
        let endsAtStart = segment(start: 0, duration: 100)     // ends exactly at 100
        let startsAtEnd = segment(start: 300, duration: 100)   // starts exactly at 300
        let visible = Array(VisibleRange.visibleSubtitles(
            in: [endsAtStart, startsAtEnd], from: docTime(100), to: docTime(300),
            maxSubtitleDuration: docTime(100)))
        #expect(visible.isEmpty)
    }

    @Test func overlappingSegmentsInsideViewportAllAppear() {
        let a = segment(start: 100, duration: 100)
        let b = segment(start: 120, duration: 100)  // overlaps a
        let c = segment(start: 120, duration: 30)   // same start as b
        let visible = Array(VisibleRange.visibleSubtitles(
            in: [a, b, c], from: docTime(0), to: docTime(500),
            maxSubtitleDuration: docTime(100)))
        #expect(visible.count == 3)
    }

    /// Viewport start at 0 with a nonzero maxDuration: the back-scan floor
    /// goes negative, which must simply clamp, not trap.
    @Test func viewportAtOriginWithBackScanBelowZero() {
        let s = segment(start: 0, duration: 50)
        let visible = Array(VisibleRange.visibleSubtitles(
            in: [s], from: docTime(0), to: docTime(10),
            maxSubtitleDuration: docTime(1_000_000)))
        #expect(visible.map(\.id) == [s.id])
    }
}

@Suite struct VisibleRangeMarkerTests {
    @Test func halfOpenOnBothEdges() {
        let atStart = marker(100)
        let inside = marker(200)
        let atEnd = marker(300)
        let visible = Array(VisibleRange.visibleMarkers(
            in: [atStart, inside, atEnd], from: docTime(100), to: docTime(300)))
        #expect(visible.map(\.id) == [atStart.id, inside.id])
    }

    @Test func emptyAndOutsideCases() {
        #expect(VisibleRange.visibleMarkers(in: [], from: docTime(0), to: docTime(10)).isEmpty)
        let m = [marker(50)]
        #expect(VisibleRange.visibleMarkers(in: m, from: docTime(60), to: docTime(100)).isEmpty)
        #expect(VisibleRange.visibleMarkers(in: m, from: docTime(0), to: docTime(50)).isEmpty)
        #expect(VisibleRange.visibleMarkers(in: m, from: docTime(50), to: docTime(50)).isEmpty)
    }

    @Test func duplicateTimesAllReturned() {
        let markers = [marker(100), marker(100), marker(100)]
        let visible = VisibleRange.visibleMarkers(in: markers, from: docTime(100), to: docTime(101))
        #expect(visible.count == 3)
    }
}
