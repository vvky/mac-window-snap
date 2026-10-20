import AppKit
import ApplicationServices

let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MacWindowSnap")

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func windowSize(_ element: AXUIElement) -> CGSize? {
    guard let raw = attribute(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &size) else { return nil }
    return size
}

final class WindowState {
    let element: AXUIElement
    var screen: CGRect?
    var deferred = false
    var generation = 0
    var correction: DispatchWorkItem?
    init(_ element: AXUIElement) { self.element = element }
    deinit { correction?.cancel() }
}

final class ApplicationSession {
    let application: ManagedApplication
    let pid: pid_t
    weak var owner: WindowHelper?
    var observer: AXObserver?
    var windows: [WindowState] = []
    var retry: DispatchWorkItem?
    var error: String?

    init(_ application: ManagedApplication, pid: pid_t, owner: WindowHelper) {
        self.application = application; self.pid = pid; self.owner = owner
    }

    func stop() {
        retry?.cancel(); retry = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        for state in windows { state.correction?.cancel() }
        windows = []
    }
}

final class WindowHelper {
    var sessions: [pid_t: ApplicationSession] = [:]
    var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    var mouseMonitor: Any?
    var signalSource: DispatchSourceSignal?
    var settings = Settings()
    var configIsValid = false
    var lastError: String?
    var adjusting = false
    var dragging: Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }

    func status() {
        var applications: [[String: Any]] = []
        for application in settings.applications {
            let active = sessions.values.filter { $0.application == application }.sorted { $0.pid < $1.pid }
            if active.isEmpty {
                applications.append(["application": application, "bundleIdentifier": application,
                                     "pid": 0, "observerActive": false, "windowCount": 0, "error": ""])
            }
            for session in active {
                applications.append(["application": application, "bundleIdentifier": application,
                                     "pid": session.pid, "observerActive": session.observer != nil,
                                     "windowCount": session.windows.count, "error": session.error ?? ""])
            }
        }
        let errors = sessions.values.sorted { $0.pid < $1.pid }.compactMap { session in
            session.error.map { "\(session.application):\($0)" }
        }
        let data: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "trusted": AXIsProcessTrusted(),
            "managedApplications": settings.applications, "applications": applications,
            "mouseMonitorActive": mouseMonitor != nil, "fraction": settings.fraction,
            "error": lastError ?? errors.first ?? "", "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let encoded = try PropertyListSerialization.data(fromPropertyList: data, format: .xml, options: 0)
            try encoded.write(to: support.appendingPathComponent("status.plist"), options: .atomic)
        } catch { NSLog("Cannot write helper status: %@", String(describing: error)) }
    }

    func updateMouseMonitor() {
        let needed = sessions.values.contains { $0.observer != nil }
        if !needed, let monitor = mouseMonitor { NSEvent.removeMonitor(monitor); mouseMonitor = nil }
        guard needed, mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                guard let self, !self.dragging else { return }
                for session in self.sessions.values {
                    for state in session.windows where state.deferred {
                        state.deferred = false; self.adjust(state, in: session)
                    }
                }
            }
        }
        if mouseMonitor == nil { lastError = "mouse_monitor_unavailable" }
    }

    func synchronize() {
        let trusted = AXIsProcessTrusted()
        if configIsValid, settings.applications.isEmpty {
            retainSessions([]); updateMouseMonitor(); lastError = nil; status(); return
        }
        guard configIsValid, trusted else {
            for session in sessions.values { session.stop() }
            sessions = [:]; updateMouseMonitor()
            lastError = configIsValid ? "accessibility_required" : "invalid_settings"
            status(); return
        }
        lastError = nil
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap { app -> RunningApplication? in
            guard let bundleIdentifier = app.bundleIdentifier else { return nil }
            return RunningApplication(pid: app.processIdentifier, bundleIdentifier: bundleIdentifier)
        }
        let desired = ApplicationSelection.desired(running, applications: settings.applications)
        retainSessions(Set(desired.keys))
        for (pid, application) in desired {
            if let session = sessions[pid] {
                if session.observer != nil { scan(session) }
                else if session.retry == nil { attach(session) }
            } else {
                let session = ApplicationSession(application, pid: pid, owner: self)
                sessions[pid] = session
                attach(session)
            }
        }
        updateMouseMonitor(); status()
    }

    func retainSessions(_ pids: Set<pid_t>) {
        for pid in Array(sessions.keys) where !pids.contains(pid) { sessions.removeValue(forKey: pid)?.stop() }
    }

    func attach(_ session: ApplicationSession, attempt: Int = 0) {
        guard sessions[session.pid] === session else { return }
        session.retry = nil
        guard AXIsProcessTrusted() else { synchronize(); return }
        var candidate: AXObserver?
        let result = AXObserverCreate(session.pid, { _, element, notification, context in
            guard let context else { return }
            let session = Unmanaged<ApplicationSession>.fromOpaque(context).takeUnretainedValue()
            session.owner?.event(element, notification as String, in: session)
        }, &candidate)
        guard result == .success, let candidate else { scheduleRetry(session, attempt, error: "observer_\(result.rawValue)"); return }
        let application = AXUIElementCreateApplication(session.pid)
        let context = Unmanaged.passUnretained(session).toOpaque()
        let registration = AXObserverAddNotification(candidate, application, kAXWindowCreatedNotification as CFString, context)
        guard registration == .success else { scheduleRetry(session, attempt, error: "window_created_\(registration.rawValue)"); return }
        session.observer = candidate; session.error = nil
        _ = AXObserverAddNotification(candidate, application, kAXFocusedWindowChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate), .commonModes)
        updateMouseMonitor()
        scan(session)
    }

    func scheduleRetry(_ session: ApplicationSession, _ attempt: Int, error: String) {
        session.stop(); session.error = error
        updateMouseMonitor(); status()
        // Bounded retries only while one application's AX tree is starting up.
        guard attempt < 8 else { return }
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.attach(session, attempt: attempt + 1)
        }
        session.retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func eligible(_ element: AXUIElement, for application: ManagedApplication) -> Bool {
        WindowPolicy.manages(application, identifier: attribute(element, kAXIdentifierAttribute) as? String,
                             role: attribute(element, kAXRoleAttribute) as? String,
                             subrole: attribute(element, kAXSubroleAttribute) as? String)
    }

    func scan(_ session: ApplicationSession) {
        guard let observer = session.observer,
              let current = attribute(AXUIElementCreateApplication(session.pid), kAXWindowsAttribute) as? [AXUIElement] else { return }
        session.windows.removeAll { state in !current.contains { CFEqual($0, state.element) } }
        for element in current where !session.windows.contains(where: { CFEqual($0.element, element) }) {
            guard eligible(element, for: session.application) else { continue }
            let state = WindowState(element)
            session.windows.append(state)
            for name in [kAXMovedNotification, kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification] {
                let result = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(session).toOpaque())
                if result != .success { session.error = "\(name)_\(result.rawValue)" }
            }
            adjust(state, in: session)
        }
        status()
    }

    func event(_ element: AXUIElement, _ name: String, in session: ApplicationSession) {
        guard sessions[session.pid] === session else { return }
        if name == kAXWindowCreatedNotification || name == kAXFocusedWindowChangedNotification { scan(session); return }
        if name == kAXUIElementDestroyedNotification {
            session.windows.removeAll { CFEqual($0.element, element) }; status(); return
        }
        if let state = session.windows.first(where: { CFEqual($0.element, element) }) { adjust(state, in: session) }
    }

    func center(_ state: WindowState, on screen: CGRect) -> AXError {
        guard let size = windowSize(state.element) else { return .cannotComplete }
        var position = WindowGeometry.centered(size, in: screen)
        return AXUIElementSetAttributeValue(state.element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &position)!)
    }

    func adjust(_ state: WindowState, in session: ApplicationSession) {
        if dragging { state.deferred = true; state.correction?.cancel(); return }
        guard !adjusting, sessions[session.pid] === session, eligible(state.element, for: session.application),
              (attribute(state.element, kAXMinimizedAttribute) as? Bool) != true,
              (attribute(state.element, "AXFullScreen") as? Bool) != true,
              let raw = attribute(state.element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID(),
              let size = windowSize(state.element), let primary = NSScreen.screens.first else { return }
        var origin = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &origin) else { return }
        let screens = NSScreen.screens.map { screen -> CGRect in
            let f = screen.visibleFrame
            return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        }
        guard let screen = WindowGeometry.screen(for: CGRect(origin: origin, size: size), in: screens), state.screen != screen else { return }
        guard mouseMonitor != nil else { return }
        adjusting = true
        defer { adjusting = false }
        state.correction?.cancel(); state.generation += 1
        let generation = state.generation
        var target = CGSize(width: (screen.width * settings.fraction).rounded(), height: (screen.height * settings.fraction).rounded())
        let resize = AXUIElementSetAttributeValue(state.element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &target)!)
        guard resize == .success else { session.error = "resize_\(resize.rawValue)"; status(); return }
        let previous = state.screen
        state.screen = screen
        let move = center(state, on: screen)
        guard move == .success else { state.screen = previous; session.error = "move_\(move.rawValue)"; status(); return }
        // Correct once after the application applies its own size constraints.
        let correction = DispatchWorkItem { [weak self, weak state, weak session] in
            guard let self, let state, let session, self.sessions[session.pid] === session,
                  state.generation == generation, state.screen == screen else { return }
            if self.dragging { state.deferred = true; state.screen = nil; return }
            guard (attribute(state.element, "AXFullScreen") as? Bool) != true,
                  (attribute(state.element, kAXMinimizedAttribute) as? Bool) != true else { return }
            _ = self.center(state, on: screen)
        }
        state.correction = correction
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: correction)
    }

    func reload() {
        guard let next = Settings.load(from: support.appendingPathComponent("settings.plist")) else {
            lastError = "invalid_settings"; status(); return
        }
        settings = next; configIsValid = true
        synchronize()
        for session in sessions.values { for state in session.windows { state.screen = nil; adjust(state, in: session) } }
        status()
    }

    func start() {
        if let stored = Settings.load(from: support.appendingPathComponent("settings.plist")) { settings = stored; configIsValid = true }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      self.settings.applications.contains(where: { $0 == app.bundleIdentifier }) else { return }
                self.synchronize()
            }
            tokens.append((center, token))
        }
        let screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for session in self.sessions.values { for state in session.windows { state.screen = nil; self.adjust(state, in: session) } }
        }
        tokens.append((NotificationCenter.default, screens))
        signal(SIGHUP, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        signalSource?.setEventHandler { [weak self] in self?.reload() }
        signalSource?.resume()
        if CommandLine.arguments.contains("--request-permission") {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        synchronize()
    }
}

#if !TESTING
@main
struct MacWindowSnapApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let helper = WindowHelper()
        helper.start()
        withExtendedLifetime(helper) { app.run() }
    }
}
#endif
