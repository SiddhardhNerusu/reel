import CoreGraphics
import Foundation

/// Records the input-event timeline that drives auto-zoom (BUILD_PLAN §5.2).
///
/// ONE listen-only session tap on a dedicated CFRunLoop thread. The callback is microscopic:
/// stamp `HostClock.now()`, read the global location, enqueue, return. Everything is stored in
/// **absolute host-clock seconds + global top-left points**; the coordinator normalizes to the
/// video timeline and maps to source pixels when it writes the `.reelproj` sidecars.
final class EventTapRecorder {

    struct RawEvent {
        var t: Double            // absolute host-clock seconds
        var location: CGPoint    // global, top-left points
        var kind: InputEvent.Kind
    }
    struct RawCursor {
        var t: Double
        var location: CGPoint
    }

    // Written only from the tap thread; read only after `stop()` joins it ⇒ no lock needed.
    private(set) var events: [RawEvent] = []
    private(set) var cursor: [RawCursor] = []

    /// Element bounds (global top-left points) resolved for each click, keyed by its index in
    /// `events`. Filled asynchronously off the tap thread; drained in `stop()`. Empty unless
    /// Accessibility is trusted.
    private let axLock = NSLock()
    private var resolvedRects: [Int: CGRect] = [:]
    private let axQueue = DispatchQueue(label: "com.neeklabs.reel.ax", qos: .userInitiated)
    /// Set true (after the AX grant) to resolve clicked-element rects for smarter zoom targeting.
    var resolvesElements = false

    var elementRects: [Int: CGRect] {
        axLock.lock(); defer { axLock.unlock() }; return resolvedRects
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    // Cross-thread handshake (fixes the start/stop teardown race). `ready` is signaled by the tap
    // thread AFTER it publishes runLoop/runLoopSource and enables the tap — a happens-before
    // barrier so stop() can never read them as a racing nil. `finished` is signaled once the run
    // loop has actually exited, replacing an unbounded `isExecuting` busy-wait.
    private var readySem = DispatchSemaphore(value: 0)
    private var finishedSem = DispatchSemaphore(value: 0)

    /// True if a listen-only tap could be created (SP-2: may need no TCC grant for mouse-only).
    private(set) var isActive = false

    private static let mask: CGEventMask = {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return isActive }
        events.removeAll(keepingCapacity: true)
        cursor.removeAll(keepingCapacity: true)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EventTapRecorder>.fromOpaque(userInfo).takeUnretainedValue()
            me.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)   // listen-only ⇒ never swallow the event
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isActive = false
            return false
        }
        self.tap = tap
        isActive = true

        // Fresh semaphores per run (DispatchSemaphore can't be reset); captured strongly by the
        // thread so they fire even if `self` is racing deallocation.
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        readySem = ready
        finishedSem = finished

        // Run the tap on its own thread so nothing else can stall its callback (§5.2).
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { ready.signal(); finished.signal(); return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            let rl = CFRunLoopGetCurrent()
            self.runLoopSource = source
            self.runLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()          // publish runLoop/source + barrier BEFORE the loop runs
            CFRunLoopRun()
            finished.signal()       // the loop has exited; buffers are safe to read
        }
        thread.name = "com.neeklabs.reel.eventtap"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
        return true
    }

    func stop() {
        guard isActive else { return }
        // Wait until the thread has published runLoop/source (bounded — never hang the caller).
        _ = readySem.wait(timeout: .now() + 2)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop, let source = runLoopSource {
            // Enqueue teardown ONTO the run loop so it works whether the loop is already running
            // or hasn't started yet (a bare CFRunLoopStop before the loop runs is a no-op).
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        _ = finishedSem.wait(timeout: .now() + 2)   // the run loop exited (bounded)
        axQueue.sync {}                              // drain any in-flight element resolutions
        tap = nil
        runLoopSource = nil
        runLoop = nil
        thread = nil
        isActive = false
    }

    // Called ONLY on the tap thread. Keep it tiny (§5.2 — heavy work ⇒ tap disabled by timeout).
    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let t = HostClock.now()
        let loc = event.location

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            cursor.append(RawCursor(t: t, location: loc))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let idx = events.count
            events.append(RawEvent(t: t, location: loc, kind: .click))
            cursor.append(RawCursor(t: t, location: loc))
            // Resolve WHICH element was clicked, off the tap thread (AX IPC can be slow).
            if resolvesElements {
                axQueue.async { [weak self] in
                    guard let self, let rect = ElementResolver.elementRect(atGlobalPoint: loc) else { return }
                    self.axLock.lock(); self.resolvedRects[idx] = rect; self.axLock.unlock()
                }
            }
        case .scrollWheel:
            events.append(RawEvent(t: t, location: loc, kind: .scroll))
        default:
            break
        }
    }
}
