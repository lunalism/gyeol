import GyeolCore
import SwiftUI

@main
struct GyeolApp: App {
    var body: some Scene {
        WindowGroup {
            // Referencing GyeolCore so the link is real, not dead-stripped.
            Text("결 — schema \(GyeolDocument.empty.schemaVersion.major).\(GyeolDocument.empty.schemaVersion.minor)")
                .padding(40)
        }
    }
}
