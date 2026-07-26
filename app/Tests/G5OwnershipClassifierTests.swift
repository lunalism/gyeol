import Foundation
import Testing

// The g5 ownership gate's parser, tested as a pure function over the
// `leaks --traceTree` output string. The failure paths matter most: the
// output format is private and will change eventually, and on that day
// the gate must answer UNVERIFIED (nil → exit 2 upstream), never "clean".
// Fixture lines are abbreviated from REAL captured trees (M2.2).

private let header = """
Process: Gyeol [12345]
Path: /Users/dev/DerivedData/Build/Products/Release/Gyeol.app/Contents/MacOS/Gyeol
Tracing: <GyeolDocumentFile 0x8a176a000> [1024]

Found 3 roots referencing: <GyeolDocumentFile 0x8a176a000> [1024]

"""

private let systemOnlyTree = header + """
    3 <GyeolDocumentFile 0x8a176a000> [1024]
      2 <NSKVONotifying__TtGC7SwiftUI13NSHostingViewV5Gyeol12DocumentView_ 0x8a0010000> [2048]   +536: __strong _rootView.file 0x8a0010218
      + 1 <NSKVONotifying_NSWindow 0x8a1785680> [640]    +32: _firstResponder 0x8a17856a0
      + ! 1 Region __DATA_DIRTY /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit __DATA_DIRTY __common: 'NSApp' 0x1ee624a70
      + 1 <Gyeol.PlaybackController 0x8a1234000> [512]    +64: something 0x8a1234040
      + ! 1 Region __DATA_DIRTY /usr/lib/dyld __DATA_DIRTY __common: '_main_thread' + 568 0x1ee5c9fb8
      1 Kernel Pointers Into User Space
"""

private let staticLeakTree = header + """
    3 <GyeolDocumentFile 0x8a176a000> [1024]
      2 <NSKVONotifying_NSWindow 0x8a1785680> [640]    +32: _firstResponder 0x8a17856a0
      + 1 Region __DATA_DIRTY /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit __DATA_DIRTY __common: 'NSApp' 0x1ee624a70
      1 Region Gyeol __DATA __data: 'static AppDelegate.deliberateLeakForGateTest' 0x102aed1c8
"""

private let blockLeakTree = header + """
    3 <GyeolDocumentFile 0x8a176a000> [1024]
      2 <__NSMallocBlock__ 0x8a1007780> [64]  Gyeol  closure #1 () -> () in Gyeol.AppDelegate.runG5Probe  0x1001a0000    +56: __strong [capture] 0x8a10077b8
      + 2 <NSTimer 0x8a1888000> [128]    +32: _block 0x8a1888020
      +   2 Region __DATA_DIRTY /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation __DATA_DIRTY __bss: '__CFRunLoop' 0x1ee600000
      1 Region __DATA_DIRTY /usr/lib/dyld __DATA_DIRTY __common: '_main_thread' + 568 0x1ee5c9fb8
"""

private let metadataCacheTree = header + """
    3 <GyeolDocumentFile 0x8a176a000> [1024]
      1 Region Gyeol __DATA __data: 'demangling cache variable for type metadata for (String, Swift.AnyObject?)' 0x100321200 --> offset 5176
      1 Region Gyeol __DATA __bss: 'metadata instantiation cache for protocol conformance descriptor for GyeolDocument' 0x102afcce0 --> offset 7648
      1 Region __DATA_DIRTY /usr/lib/dyld __DATA_DIRTY __common: '_main_thread' + 568 0x1ee5c9fb8
"""

@Suite struct G5OwnershipClassifierTests {

    // MARK: - UNVERIFIED paths (nil → exit 2 upstream)

    @Test func emptyOutputIsUnverified() {
        #expect(G5OwnershipClassifier.classify(tree: "", imageName: "Gyeol") == nil)
    }

    @Test func missingTracingAnchorIsUnverified() {
        let tree = "Some future leaks format\nFound 3 roots referencing: <X>\n    3 Region Gyeol __DATA"
        #expect(G5OwnershipClassifier.classify(tree: tree, imageName: "Gyeol") == nil)
    }

    @Test func missingRootCountIsUnverified() {
        let tree = "Tracing: <GyeolDocumentFile 0x1> [1024]\n    3 <GyeolDocumentFile 0x1> [1024]\n      1 Region Gyeol __DATA __data: 'static X' 0x2"
        #expect(G5OwnershipClassifier.classify(tree: tree, imageName: "Gyeol") == nil)
    }

    @Test func unparseableRootCountIsUnverified() {
        let tree = "Tracing: <X>\nFound ??? roots referencing: <X>\n    1 Region Gyeol __DATA"
        #expect(G5OwnershipClassifier.classify(tree: tree, imageName: "Gyeol") == nil)
    }

    /// Roots are declared but no root FORM we recognize appears anywhere:
    /// the format moved under us. Certifying "clean" here would be the
    /// gate lying on the exact day it matters.
    @Test func declaredRootsWithZeroRecognizedFormsIsUnverified() {
        let tree = """
        Tracing: <GyeolDocumentFile 0x1> [1024]
        Found 5 roots referencing: <GyeolDocumentFile 0x1> [1024]
            5 <GyeolDocumentFile 0x1> [1024]
              5 <SomeFutureRootKind fancy-new-format>
        """
        #expect(G5OwnershipClassifier.classify(tree: tree, imageName: "Gyeol") == nil)
    }

    // MARK: - Classification

    @Test func systemOnlyTreeHasNoAppOwnedLines() throws {
        let report = try #require(G5OwnershipClassifier.classify(
            tree: systemOnlyTree, imageName: "Gyeol"))
        #expect(report.appOwnedLines.isEmpty)
        #expect(report.rootCount == 3)
    }

    /// Codex P1's exact scenario: module-qualified app TYPE names
    /// (`Gyeol.PlaybackController`, the SwiftUI hosting view's mangled
    /// `…Gyeol12DocumentView…`) appear as object nodes in a system-owned
    /// tree and must not be classified — a type name does not say who
    /// owns the object.
    @Test func appTypedObjectNodesAreNotOwnership() throws {
        let report = try #require(G5OwnershipClassifier.classify(
            tree: systemOnlyTree, imageName: "Gyeol"))
        #expect(!systemOnlyTree.split(separator: "\n")
            .filter { $0.contains("Gyeol.PlaybackController") }.isEmpty)
        #expect(report.appOwnedLines.isEmpty)
    }

    @Test func staticRootInOurImageIsFlagged() throws {
        let report = try #require(G5OwnershipClassifier.classify(
            tree: staticLeakTree, imageName: "Gyeol"))
        #expect(report.appOwnedLines.count == 1)
        #expect(report.appOwnedLines[0].contains("deliberateLeakForGateTest"))
    }

    /// The block/closure branch — the gate's primary use case (M2.1's
    /// unremoved observer). The root is the SYSTEM run loop; only the
    /// block's image attribution can catch it.
    @Test func appBlockOnSystemRootedPathIsFlagged() throws {
        let report = try #require(G5OwnershipClassifier.classify(
            tree: blockLeakTree, imageName: "Gyeol"))
        #expect(report.appOwnedLines.count == 1)
        #expect(report.appOwnedLines[0].contains("__NSMallocBlock__"))
    }

    /// The EXACT rendering measured from the --g5-block-leak self-test: a
    /// Swift closure handed to Timer shows as a reabstraction THUNK, not
    /// as "closure #1 in …" — no "closure" keyword anywhere. The line is
    /// caught by `__NSMallocBlock__` + the image-attribution column, and
    /// this fixture pins that against a demangler format change.
    @Test func measuredTimerThunkRenderingIsFlagged() throws {
        let tree = header + """
            3 <GyeolDocumentFile 0x8a176a000> [1024]
              + 19 <__NSMallocBlock__ 0xc436dd5f0> [48]  Gyeol  thunk for @escaping @callee_guaranteed @Sendable (@guaranteed NSTimer) -> ()  0x1024e7ef0    +40:  0xc436dd618
              1 Region __DATA_DIRTY /usr/lib/dyld __DATA_DIRTY __common: '_main_thread' + 568 0x1ee5c9fb8
        """
        let report = try #require(G5OwnershipClassifier.classify(tree: tree, imageName: "Gyeol"))
        #expect(report.appOwnedLines.count == 1)
        #expect(report.appOwnedLines[0].contains("NSTimer"))
    }

    @Test func runtimeMetadataCachesAreExcluded() throws {
        let report = try #require(G5OwnershipClassifier.classify(
            tree: metadataCacheTree, imageName: "Gyeol"))
        #expect(report.appOwnedLines.isEmpty)
    }

    /// The image name is a parameter (derived from the process at the
    /// call site): a renamed app must keep catching its own roots.
    @Test func imageNameIsNotHardcoded() throws {
        let renamed = staticLeakTree.replacingOccurrences(of: "Region Gyeol ", with: "Region Kyeol ")
        let report = try #require(G5OwnershipClassifier.classify(
            tree: renamed, imageName: "Kyeol"))
        #expect(report.appOwnedLines.count == 1)
        let missed = try #require(G5OwnershipClassifier.classify(
            tree: renamed, imageName: "Gyeol"))
        #expect(missed.appOwnedLines.isEmpty)
    }
}
