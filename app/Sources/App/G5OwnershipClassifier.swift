import Foundation

/// The g5 ownership gate's PARSER, factored out of the probe as a pure
/// function over the `leaks --traceTree` output string so the failure
/// paths are unit-testable (the spawn itself stays in the probe): the
/// leaks output format is private and WILL change eventually, and when it
/// does, the gate must say UNVERIFIED — never "clean".
///
/// Classification is BY LINE KIND. A type name never says who OWNS an
/// object (Codex review P1: the inspected object itself and intermediate
/// app-typed nodes appear in every tree, qualified as
/// `Gyeol.PlaybackController` etc., and matching them fails exactly the
/// system-owned survivor the gate exists to permit):
///
/// - ROOT lines (`Region …`): app-owned iff the region lives in OUR image
///   (a static/global of ours). Compiler-emitted runtime caches in our
///   image are bookkeeping under conservative scan, not ownership —
///   excluded (both exclusion patterns were measured false positives).
/// - BLOCK/CLOSURE lines (`__NSMallocBlock__` / `_block_invoke` /
///   `closure`): app-owned iff attributed to our image or our module
///   symbols — an unremoved observer block of ours (the M2.1 class of
///   bug) is compiled into our image and lands here.
/// - OBJECT nodes (`<Type 0x…>`): never classified.
///
/// WHAT THE GATE ACTUALLY MEASURES (narrower than "no retain path owned
/// by app code" — a gate must not claim more than it measures): it
/// catches (a) static/global roots in our image and (b) blocks or
/// closures compiled into our image, anywhere on a path. It does NOT
/// catch a system-created object directly retaining one of ours — by this
/// gate's definition that is the system's reference, not our bug.
/// Stack-region roots cannot be attributed and are left unflagged.
enum G5OwnershipClassifier {
    struct Report {
        let appOwnedLines: [String]
        let rootCount: Int
        let tree: String
    }

    /// nil means UNVERIFIED — the caller must exit 2, not report clean.
    /// Anchors: the `Tracing:` header, a parseable `Found N roots
    /// referencing` count, and (when N > 0) at least one root form we
    /// recognize. Any of them missing means the format moved under us and
    /// we did not determine ownership.
    static func classify(
        tree: String,
        imageName: String,
        moduleSymbols: [String] = ["GyeolCore", "GyeolPlayback"]
    ) -> Report? {
        guard !tree.isEmpty, tree.contains("Tracing:") else { return nil }
        guard let rootCount = tree.split(separator: "\n")
            .first(where: { $0.contains("roots referencing") })
            .flatMap({ line in Int(line.split(separator: " ").dropFirst().first ?? "") }),
            rootCount >= 0 else {
            return nil
        }
        let structuralLines = tree.split(separator: "\n").map(String.init).filter { line in
            let trimmed = line.drop(while: { $0 == " " })
            guard let first = trimmed.first else { return false }
            return first.isNumber || first == "+" || first == "!" || first == ":" || first == "|"
        }
        // Roots were announced but none of the root forms we know appear:
        // the format moved under us — refuse to certify.
        let recognizedRoots = structuralLines.filter {
            $0.contains("Region ") || $0.contains("Kernel Pointers")
        }
        guard rootCount == 0 || !recognizedRoots.isEmpty else { return nil }

        let appOwned = structuralLines.filter { line in
            if line.contains("Region ") {
                // Compiler-emitted runtime caches live in our image but
                // hold type descriptors, not object references — a root
                // "through" one is conservative-scan noise, not ownership.
                // Both forms were MEASURED as false positives: 'metadata
                // instantiation cache for protocol conformance descriptor'
                // and 'demangling cache variable for type metadata for
                // (String, Swift.AnyObject?)' — the latter minted by the
                // gate's own survivors tuple. No real static of ours can
                // be named into this exclusion.
                guard !line.contains("metadata"),
                      !line.contains("witness table") else { return false }
                return line.contains("Region \(imageName) ")
                    || line.contains("\(imageName).app")
            }
            if line.contains("__NSMallocBlock__")
                || line.contains("_block_invoke")
                || line.contains("closure") {
                return line.contains("  \(imageName)  ")
                    || line.contains("\(imageName).")
                    || moduleSymbols.contains(where: line.contains)
            }
            // Object nodes: a type name does not say who owns the object.
            return false
        }
        return Report(appOwnedLines: appOwned, rootCount: rootCount, tree: tree)
    }
}
