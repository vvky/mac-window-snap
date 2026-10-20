import AppKit
import ApplicationServices

@main
struct RuntimeChecks {
    static func main() {
        let helper = WindowHelper()
        let terminal = ApplicationSession("com.apple.Terminal", pid: 10001, owner: helper)
        let ghostty = ApplicationSession("com.mitchellh.ghostty", pid: 10002, owner: helper)
        let secondGhostty = ApplicationSession("com.mitchellh.ghostty", pid: 10003, owner: helper)
        let termius = ApplicationSession("com.termius-dmg.mac", pid: 10004, owner: helper)
        helper.sessions = [terminal.pid: terminal, ghostty.pid: ghostty, secondGhostty.pid: secondGhostty, termius.pid: termius]
        // AXUIElement creation is local; no attribute query or window mutation is made.
        let window = WindowState(AXUIElementCreateApplication(terminal.pid))
        let correction = DispatchWorkItem { fatalError("A canceled correction must never execute") }
        window.correction = correction
        terminal.windows = [window]
        terminal.retry = DispatchWorkItem { fatalError("A stopped session must not reattach") }
        helper.retainSessions([ghostty.pid, secondGhostty.pid, termius.pid])
        precondition(helper.sessions.count == 3 && helper.sessions[terminal.pid] == nil)
        precondition(helper.sessions[ghostty.pid] === ghostty && helper.sessions[secondGhostty.pid] === secondGhostty)
        precondition(terminal.windows.isEmpty && terminal.retry == nil && correction.isCancelled)
        helper.retainSessions([secondGhostty.pid, termius.pid])
        precondition(helper.sessions.count == 2 && helper.sessions[secondGhostty.pid] === secondGhostty && helper.sessions[termius.pid] === termius)
        helper.retainSessions([termius.pid])
        precondition(helper.sessions.count == 1 && helper.sessions[termius.pid] === termius)
        helper.retainSessions([])
        precondition(helper.sessions.isEmpty)
        print("Runtime: independent session teardown and pending-work cancellation passed (no UI access)")
    }
}
