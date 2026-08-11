/// Namespace and version marker for the Tim Method core library.
///
/// This target holds all tracking, counting, and Tim Method engine code
/// shared between the app and the `timmethod-eval` CLI (see SPEC §15). It
/// must stay importable from a headless macOS command-line tool, so it never
/// imports SwiftUI, UIKit, or anything `UIApplication`-shaped.
public enum TimMethodCore {
    /// Semantic version of the core library, bumped alongside meaningful
    /// algorithm changes so eval reports can be tied to a specific build.
    public static let version = "0.1.0"
}
