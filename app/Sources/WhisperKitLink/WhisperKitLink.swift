// D6 premise check: get WhisperKit's binaries into the bundle. Link only —
// no API is called anywhere (M3 owns the integration). The typealias forces
// the module to actually link; a bare `import` of an unused module can be
// dropped by the build system.
import WhisperKit

typealias LinkedWhisperKit = WhisperKit
