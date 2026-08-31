import Foundation

/// A user edit to the auto-computed camera path (BUILD_PLAN §6, editor is M6). Persisted in
/// `project.json`; merged over the auto-solved clusters before the spring runs.
struct CameraOverride: Codable, Equatable, Identifiable {
    enum Action: String, Codable { case add, move, delete }

    var id: UUID = UUID()
    var action: Action
    /// Video-timeline seconds this override applies at.
    var time: Double
    /// For add/move: target center in source pixels + zoom scale. Nil for delete.
    var centerX: Double?
    var centerY: Double?
    var scale: Double?
    /// For delete: which auto cluster (by index) to suppress.
    var clusterIndex: Int?
}
