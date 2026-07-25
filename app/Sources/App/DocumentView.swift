import GyeolCore
import SwiftUI

/// The document window's content for M1: a summary, the newer-minor
/// warning (F12), and a single mutation affordance so the autosave round
/// trip can be exercised before M2 brings real editing.
struct DocumentView: View {
    let file: GyeolDocumentFile
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if file.openedWithNewerMinor {
                newerMinorWarning
            }
            summary
            // M1 autosave-verification affordance, not an editing feature:
            // real editing is M2. This exists so "edit → autosave → reopen"
            // can be walked in the running app.
            Button("마커 추가 (autosave 검증용)") {
                addMarker()
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 300)
        .id(revision)
    }

    /// F12 (PRD §5.6.3): fires once, at open, when the file's minor version
    /// is newer than this build. Placeholder copy — final wording is the
    /// user's call; the content it must carry: made by a newer Gyeol,
    /// opening is safe, SAVING from this build may drop fields it does not
    /// understand.
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

    private var summary: some View {
        let document = file.document
        return VStack(alignment: .leading, spacing: 4) {
            Text("스키마 \(document.schemaVersion.major).\(document.schemaVersion.minor)")
            Text("미디어 \(document.media.count) · 트랙 \(document.tracks.count) · 자막 \(document.subtitles.count) · 마커 \(document.markers.count)")
        }
        .foregroundStyle(.secondary)
        .font(.callout)
    }

    private func addMarker() {
        var document = file.document
        let nextTicks = (document.markers.last?.time.ticks ?? -120_000) + 120_000
        let nextTime = DocumentTime(exactly: try! RationalTime(value: nextTicks, timescale: 120_000))!
        document.markers.append(Marker(id: MarkerID(), time: nextTime, label: "M\(document.markers.count + 1)"))
        file.replaceDocument(document)
        revision += 1
    }
}
