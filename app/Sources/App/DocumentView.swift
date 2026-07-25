import GyeolCore
import GyeolPlayback
import SwiftUI

/// The document window: playback lives HERE now (G12) — there is no
/// standalone player window. One `PlaybackController` per view, and one
/// view per document window, which is what makes the controller
/// per-document (G4) and its `deinit` teardown load-bearing (F6).
///
/// OBSERVATION (G2): NSDocument is not Observable, so `GyeolDocumentFile`
/// adopts the `@Observable` macro. Reading `file.document` inside `body`
/// and inside `.task(id:)` registers SwiftUI dependency tracking, and every
/// mutation path writes that one property (`replaceDocument`, `read`), so
/// open, edit, revert and undo all flow through the same tracked write —
/// no `.id(revision)` manual refresh, no parallel view model to drift.
///
/// `file` is deliberately STRONG (the G5 decision, upheld by the M2.1
/// reconciliation round): the cycle document → windowController → window →
/// hosting view → this view → document is broken by `NSDocument.close()` —
/// verified in the RUNNING APP (`--g5-probe`: document, controller, and
/// player all deinit right after close). The headless suite's residual
/// "leak" is a harness artifact (see DocumentLifecycleMeasurement's
/// header). A weak reference would put an optional unwrap on every read of
/// the document for a lifetime problem the app does not have.
struct DocumentView: View {
    let file: GyeolDocumentFile
    /// Owned by the document (see GyeolDocumentFile.playback); the view is
    /// a client. Document ownership is what makes teardown at close
    /// unconditional (G5).
    let playback: PlaybackController

    var body: some View {
        VStack(spacing: 12) {
            if file.openedWithNewerMinor {
                newerMinorWarning
            }
            PlayerLayerView(player: playback.player)
                .frame(minWidth: 640, minHeight: 360)
                .background(.black)
            transport
            status
        }
        .padding()
        // The G1 rebuild entry: any replacement of the document value —
        // open is the first, edits and undo arrive in M2.3 — retriggers
        // this task and rebuilds the composition through the epoch-guarded
        // load path.
        .task(id: file.document) {
            await reload()
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button {
                Task { await playback.step(by: -1) }
            } label: { Image(systemName: "backward.frame.fill") }
                .disabled(playback.loadState != .ready || playback.isPlaying)
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(playback.loadState != .ready || playback.frameCount == 0)
            Button {
                Task { await playback.step(by: 1) }
            } label: { Image(systemName: "forward.frame.fill") }
                .disabled(playback.loadState != .ready || playback.isPlaying)
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 4) {
            switch playback.loadState {
            case .empty:
                Text("불러오는 중…").foregroundStyle(.secondary)
            case .loading:
                ProgressView()
            case .failed(let message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            case .ready:
                HStack(spacing: 12) {
                    if let rate = playback.projectRate {
                        Text("\(rate.rawValue) fps")
                    }
                    Text("frame \(playback.playheadFrame) / \(playback.frameCount)")
                        .monospacedDigit()
                    Text(playback.clockDisplay).foregroundStyle(.secondary)
                }
                if let report = playback.lastStopReport {
                    Text(report)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// F12 (PRD §5.6.3): fires once, at open, when the file's minor version
    /// is newer than this build.
    private var newerMinorWarning: some View {
        Label {
            Text("""
            이 프로젝트는 더 새로운 버전의 결에서 만들어졌습니다 \
            (스키마 \(file.document.schemaVersion.major).\(file.document.schemaVersion.minor)). \
            열 수는 있지만, 이 버전에서 저장하면 이 버전이 모르는 정보가 사라질 수 있습니다.
            """)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func reload() async {
        // Resolve the pool BEFORE building. Reconnect UI is M2.5 (S6);
        // until then an unresolvable reference is a loud failed load, not
        // a silent skip.
        guard let packageURL = file.fileURL else {
            // Untitled documents have no package on disk and can hold no
            // resolvable media yet; an empty pool loads an empty timeline.
            if file.document.media.isEmpty {
                await playback.load(document: file.document, mediaURLs: [:])
            } else {
                playback.reportLoadFailure("문서가 저장되기 전에는 상대 경로 미디어를 해석할 수 없습니다")
            }
            return
        }
        var urls: [MediaID: URL] = [:]
        for (id, reference) in file.document.media {
            let resolution = MediaResolver.resolve(
                reference: reference,
                bookmark: file.bookmarks[id],
                packageURL: packageURL)
            switch resolution {
            case .resolved(let url):
                urls[id] = url
            case .resolvedAndHealed(let url, let freshBookmark):
                urls[id] = url
                file.storeBookmark(freshBookmark, for: id)
            case .needsReconnect(let reason):
                playback.reportLoadFailure(
                    "미디어를 찾을 수 없습니다: \(reference.displayName) (\(String(describing: reason))) — 재연결 UI는 M2.5")
                return
            }
        }
        await playback.load(document: file.document, mediaURLs: urls)
    }
}
