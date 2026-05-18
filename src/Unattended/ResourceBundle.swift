import Foundation

extension Bundle {
    /// Custom resource bundle accessor that works both for standalone binaries
    /// (where SPM places the bundle next to the executable) and for .app bundles
    /// (where the bundle lives in Contents/Resources/).
    ///
    /// SPM's auto-generated `Bundle.module` only checks `Bundle.main.bundleURL`
    /// (the .app root), which doesn't match `Contents/Resources/` in a .app bundle.
    /// This accessor checks `resourceURL` first, then `bundleURL`, then the build path.
    static let lumeResources: Bundle = {
        let bundleName = "bushel_bushel.bundle"

        // 0. SPM-managed test/build context. `Bundle.module` is the auto-generated
        //    accessor SPM emits inside this target. In the test runner, Bundle.main
        //    points at the test executable rather than the bushel binary, so the
        //    .resourceURL / .bundleURL checks below all miss; Bundle.module always
        //    resolves to the actual resource bundle when we're being driven by
        //    `swift test`.
        if FileManager.default.fileExists(atPath: Bundle.module.bundlePath) {
            return Bundle.module
        }

        // 1. .app bundle: Contents/Resources/
        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent(bundleName).path
            if let bundle = Bundle(path: path) {
                return bundle
            }
        }

        // 2. Standalone binary: next to the executable
        let mainPath = Bundle.main.bundleURL.appendingPathComponent(bundleName).path
        if let bundle = Bundle(path: mainPath) {
            return bundle
        }

        // 3. Development fallback: SPM build directory
        #if DEBUG
        // During development, try the build directory
        let buildPath = Bundle.main.bundleURL.appendingPathComponent(bundleName).path
        if let bundle = Bundle(path: buildPath) {
            return bundle
        }
        #endif

        fatalError("Could not load resource bundle '\(bundleName)' from Bundle.module / resourceURL / bundleURL")
    }()

    /// Filesystem root of the lume resource bundle, computed ONCE at first use
    /// from the running executable's location. Use this instead of
    /// `Bundle.lumeResources.url(forResource:)` for files served by the HTTP
    /// daemon and unattended-install presets.
    ///
    /// Why bypass Foundation's `url(forResource:)`: in long-running daemons we
    /// observed `Bundle.url(forResource:withExtension:)` returning `nil` for
    /// files that demonstrably still exist on disk, in clusters of a few
    /// seconds, then recovering. The pattern correlates with macOS sleep/wake
    /// cycles — Foundation's internal directory-enumeration cache appears to
    /// race with FSEvents/memory-pressure invalidations on resume, and during
    /// the rebuild window the lookup misses. A direct filesystem path doesn't
    /// touch that cache. (See `dashboard.html missing from resource bundle`
    /// log clusters; introduced in bushel.21.)
    static let lumeResourceURL: URL = {
        let bundleName = "bushel_bushel.bundle"

        // Prefer Bundle.lumeResources.resourceURL when available — covers the
        // test runner and any .app-bundle layout where the resource bundle
        // lives inside Contents/Resources/.
        if let resourceURL = Bundle.lumeResources.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        // Standalone-binary path: derive from the running executable's
        // directory. Bundle.main.executableURL is set at process launch and
        // doesn't change; computing this once at first use is enough.
        if let exec = Bundle.main.executableURL {
            let candidate = exec.deletingLastPathComponent().appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Last resort: trust whatever Bundle.lumeResources thinks its path is.
        // This may not actually exist on disk, but callers will get nil from
        // their existence checks and surface a clean error.
        return URL(fileURLWithPath: Bundle.lumeResources.bundlePath)
    }()

    /// Resilient resource lookup. Returns the URL only if the file exists on
    /// disk right now. Use this instead of `Bundle.lumeResources.url(forResource:)`
    /// for daemon-served resources (see `lumeResourceURL` for rationale).
    ///
    /// `relativePath` may include subdirectories (e.g. "novnc/vnc.html") —
    /// SPM's `url(forResource:)` handles those awkwardly; this helper just
    /// appends path components directly.
    static func lumeResource(_ relativePath: String) -> URL? {
        let url = lumeResourceURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
