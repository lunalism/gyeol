import GyeolCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct GyeolApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var controller = PlaybackController()
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 12) {
            PlayerLayerView(player: controller.player)
                .frame(minWidth: 640, minHeight: 360)
                .background(.black)

            HStack(spacing: 16) {
                Button("열기…") { showImporter = true }
                Button {
                    Task { await controller.step(by: -1) }
                } label: { Image(systemName: "backward.frame.fill") }
                    .disabled(controller.loadState != .ready || controller.isPlaying)
                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(controller.loadState != .ready)
                Button {
                    Task { await controller.step(by: 1) }
                } label: { Image(systemName: "forward.frame.fill") }
                    .disabled(controller.loadState != .ready || controller.isPlaying)
            }

            statusView
        }
        .padding()
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result {
                Task { await controller.open(url: url) }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(spacing: 4) {
            switch controller.loadState {
            case .empty:
                Text("파일을 열어 주세요").foregroundStyle(.secondary)
            case .loading:
                ProgressView()
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            case .ready:
                HStack(spacing: 12) {
                    if let rate = controller.projectRate {
                        Text("\(rate.rawValue) fps")
                    }
                    Text("frame \(controller.playheadFrame)\(controller.frameCount.map { " / \($0)" } ?? " / ?")")
                        .monospacedDigit()
                    Text(controller.clockDisplay).foregroundStyle(.secondary)
                }
                if let report = controller.lastPauseReport {
                    Text(report)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
