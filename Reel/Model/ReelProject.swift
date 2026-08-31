import Foundation

/// Bump when the on-disk shape changes (§6: refuse-newer, migrate-older).
let kReelSchemaVersion = 1

/// The persisted settings/metadata of a `.reelproj` document package (BUILD_PLAN §6).
///
/// A project on disk is a folder shown as a file:
/// ```
/// MyDemo.reelproj/
///   raw.mov  events.json  cursor.json  window.json  project.json  thumbnail.png
/// ```
/// `raw.mov` is never touched — that is what makes re-edit + re-export infinite and lossless.
struct ReelProject: Codable, Equatable {
    var schemaVersion: Int = kReelSchemaVersion

    /// First video sample PTS in seconds (§5.0 step 2) — the anchor that converts absolute
    /// host-clock event stamps into video-timeline times. Stored for provenance; the JSON
    /// timelines are already normalized to zero at write time.
    var recordingStartTime: Double
    /// Video duration in seconds.
    var duration: Double

    var geometry: GeometrySnapshot

    // Edit state ------------------------------------------------------------
    var trimIn: Double = 0
    var trimOut: Double = -1            // <0 ⇒ use `duration`
    var fps: Int = 60
    var codec: String = "h264"          // "h264" | "hevc"
    var theme: Theme = .default
    var overrides: [CameraOverride] = []
    /// Auto-remove long silent+idle spans on export (on-device silence + input-idle detection).
    var autoRemoveSilence: Bool = true

    var effectiveTrimOut: Double { trimOut < 0 ? duration : min(trimOut, duration) }
    var editedDuration: Double { max(0, effectiveTrimOut - trimIn) }
}

// MARK: - Document package IO

enum ReelDocumentError: Error, LocalizedError {
    case schemaTooNew(found: Int, supported: Int)
    case missingComponent(String)

    var errorDescription: String? {
        switch self {
        case let .schemaTooNew(found, supported):
            return "This project was made by a newer version of Reel (schema \(found) > \(supported))."
        case let .missingComponent(name):
            return "The project is missing \(name)."
        }
    }
}

/// Reads/writes the `.reelproj` bundle. Pure Foundation so it stays in the test-compilable Model.
struct ReelDocument: Identifiable {
    var id: URL { url }
    let url: URL                         // the .reelproj directory
    var project: ReelProject
    var events: [InputEvent]
    var cursor: [CursorSample]
    var window: [WindowSample]

    static let rawMovieName = "raw.mov"

    var rawMovieURL: URL { url.appendingPathComponent(Self.rawMovieName) }

    // Write ----------------------------------------------------------------
    /// Persists the JSON sidecars + project.json. Callers place `raw.mov` and `thumbnail.png`
    /// into `url` separately (they are large binaries).
    func writeSidecars() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(project).write(to: url.appendingPathComponent("project.json"))
        try enc.encode(events).write(to: url.appendingPathComponent("events.json"))
        try enc.encode(cursor).write(to: url.appendingPathComponent("cursor.json"))
        try enc.encode(window).write(to: url.appendingPathComponent("window.json"))
    }

    // Read -----------------------------------------------------------------
    static func open(_ url: URL) throws -> ReelDocument {
        let dec = JSONDecoder()
        func load<T: Decodable>(_ name: String, _ type: T.Type, optional: Bool = false) throws -> T? {
            let f = url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: f.path) else {
                if optional { return nil }
                throw ReelDocumentError.missingComponent(name)
            }
            return try dec.decode(T.self, from: Data(contentsOf: f))
        }
        guard let project = try load("project.json", ReelProject.self) else {
            throw ReelDocumentError.missingComponent("project.json")
        }
        guard project.schemaVersion <= kReelSchemaVersion else {
            throw ReelDocumentError.schemaTooNew(found: project.schemaVersion, supported: kReelSchemaVersion)
        }
        let events = try load("events.json", [InputEvent].self, optional: true) ?? []
        let cursor = try load("cursor.json", [CursorSample].self, optional: true) ?? []
        let window = try load("window.json", [WindowSample].self, optional: true) ?? []
        return ReelDocument(url: url, project: project, events: events, cursor: cursor, window: window)
    }
}
