import CoreMedia
import Foundation

/// The one clock shared by capture and events (BUILD_PLAN §5.2). SCK frame PTS ride the host
/// time clock, so stamping each CGEvent with the SAME clock makes event.t and frame PTS directly
/// comparable. We read it explicitly instead of trusting `CGEventGetTimestamp`, whose units are
/// a trap (mach ticks on Apple Silicon, not ns).
enum HostClock {
    /// Current host-clock time in **seconds**.
    static func now() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}
