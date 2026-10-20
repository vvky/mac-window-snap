import Foundation
import CoreGraphics

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let primary = CGRect(x: 0, y: 25, width: 2048, height: 1127)
let below = CGRect(x: 329, y: 1177, width: 1440, height: 817)
let right = CGRect(x: 2048, y: 357, width: 1180, height: 795)
let left = CGRect(x: -1440, y: -200, width: 1440, height: 875)
let screens = [primary, below, right, left]

expect(WindowGeometry.screen(for: CGRect(x: 2200, y: 450, width: 800, height: 500), in: screens) == right,
       "Select the display with the largest overlap, not the primary display")
expect(WindowGeometry.screen(for: CGRect(x: -1300, y: -100, width: 700, height: 400), in: screens) == left,
       "Negative desktop coordinates must work")
expect(WindowGeometry.screen(for: CGRect(x: 1800, y: 450, width: 800, height: 500), in: screens) == right,
       "A spanning window follows its majority overlap")
expect(WindowGeometry.screen(for: CGRect(x: 650, y: 1350, width: 720, height: 420), in: screens) == below,
       "Vertically stacked monitors use global top-left coordinates")
expect(WindowGeometry.screen(for: CGRect(x: 5000, y: 400, width: 600, height: 400), in: screens) == right,
       "Disconnected-display windows recover onto the nearest screen")
expect(WindowGeometry.screen(for: primary, in: []) == nil, "No display is not an error")
let actualTerminalSize = CGSize(width: 766, height: 520)
let position = WindowGeometry.centered(actualTerminalSize, in: right)
expect(abs(position.x + actualTerminalSize.width / 2 - right.midX) <= 0.5,
       "Center using Terminal's actual cell-rounded width")
expect(abs(position.y + actualTerminalSize.height / 2 - right.midY) <= 0.5,
       "Exclude the menu bar and Dock when centering")
print("Geometry: 8 behavioral checks passed")

func decode(_ values: [String: Any]) -> Settings? {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return nil }
    return try? PropertyListDecoder().decode(Settings.self, from: data)
}

expect(decode(["fraction": 0.65])?.applications == [], "Missing selection must not manage unrelated apps")
expect(decode(["fraction": 0.7, "applications": ["com.apple.Terminal", "com.mitchellh.ghostty"]])?.applications == ["com.apple.Terminal", "com.mitchellh.ghostty"], "Both apps can be selected")
expect(decode(["fraction": 0.7, "applications": ["com.mitchellh.ghostty"]])?.applications == ["com.mitchellh.ghostty"], "Ghostty-only selection")
expect(decode(["fraction": 0.7, "applications": [String]()])?.applications == [], "An empty list pauses all application management")
expect(decode(["fraction": 0.7, "applications": ["iterm2"]]) == nil, "Unsupported applications are rejected")
expect(decode(["fraction": 0.7, "applications": ["com.mitchellh.ghostty", "com.mitchellh.ghostty"]]) == nil, "Duplicate observers must not be configured")
expect(decode(["fraction": Double.nan]) == nil, "NaN is not a valid fraction")
expect(decode(["fraction": 0.2]) == nil, "Out-of-range fractions are rejected")

let running = [RunningApplication(pid: 10, bundleIdentifier: "com.apple.Terminal"),
               RunningApplication(pid: 20, bundleIdentifier: "com.mitchellh.ghostty"),
               RunningApplication(pid: 21, bundleIdentifier: "com.mitchellh.ghostty"),
               RunningApplication(pid: 30, bundleIdentifier: "unrelated.app")]
expect(ApplicationSelection.desired(running, applications: ["com.apple.Terminal"]) == [10: "com.apple.Terminal"], "Unselected Ghostty and unrelated apps remain untouched")
expect(ApplicationSelection.desired(running, applications: ["com.apple.Terminal", "com.mitchellh.ghostty"]) == [10: "com.apple.Terminal", 20: "com.mitchellh.ghostty", 21: "com.mitchellh.ghostty"], "Independent app instances are managed in one process")
expect(ApplicationSelection.desired(Array(running.dropFirst()), applications: ["com.apple.Terminal", "com.mitchellh.ghostty"]) == [20: "com.mitchellh.ghostty", 21: "com.mitchellh.ghostty"], "Terminal quitting must not stop Ghostty")
expect(ApplicationSelection.desired(running, applications: ["com.mitchellh.ghostty"]) == [20: "com.mitchellh.ghostty", 21: "com.mitchellh.ghostty"], "Changing selection drops only the disabled app")
expect(ApplicationSelection.desired(running, applications: []) == [:], "No selection means no observers")

expect(WindowPolicy.manages("com.mitchellh.ghostty", identifier: nil, role: "AXWindow", subrole: "AXStandardWindow"), "Normal Ghostty windows are eligible")
expect(WindowPolicy.manages("com.apple.Terminal", identifier: nil, role: "AXWindow", subrole: "AXStandardWindow"), "Normal Terminal windows remain eligible")
expect(!WindowPolicy.manages("com.mitchellh.ghostty", identifier: "com.mitchellh.ghostty.quickTerminal", role: "AXWindow", subrole: "AXStandardWindow"), "Quick Terminal is excluded by its official identifier")
expect(!WindowPolicy.manages("com.mitchellh.ghostty", identifier: nil, role: "AXWindow", subrole: "AXFloatingWindow"), "Floating panels are excluded even without an identifier")
expect(!WindowPolicy.manages("com.mitchellh.ghostty", identifier: nil, role: "AXWindow", subrole: "AXDialog"), "Preferences/dialogs are excluded")
expect(!WindowPolicy.manages("com.mitchellh.ghostty", identifier: nil, role: "AXWindow", subrole: nil), "An unknown window type must not be resized")
print("Applications: 19 config, selection and window-policy checks passed")

expect(decode(["fraction": 0.65, "applications": ["com.termius-dmg.mac"]])?.applications == ["com.termius-dmg.mac"], "Termius-only selection")
expect(decode(["fraction": 0.65, "applications": ["com.apple.Terminal", "com.mitchellh.ghostty", "com.termius-dmg.mac"]])?.applications == ["com.apple.Terminal", "com.mitchellh.ghostty", "com.termius-dmg.mac"], "All three apps can be selected")
expect(decode(["fraction": 0.65, "applications": ["com.termius-dmg.mac", "com.termius-dmg.mac"]]) == nil, "Duplicate Termius selection is rejected")
let withTermius = running + [RunningApplication(pid: 40, bundleIdentifier: "com.termius-dmg.mac")]
expect(ApplicationSelection.desired(withTermius, applications: ["com.termius-dmg.mac"]) == [40: "com.termius-dmg.mac"], "Termius bundle mapping is explicit")
expect(ApplicationSelection.desired(withTermius, applications: ["com.apple.Terminal", "com.mitchellh.ghostty", "com.termius-dmg.mac"]) == [10: "com.apple.Terminal", 20: "com.mitchellh.ghostty", 21: "com.mitchellh.ghostty", 40: "com.termius-dmg.mac"], "Three apps share one process without sharing sessions")
expect(ApplicationSelection.desired(withTermius, applications: ["com.apple.Terminal", "com.mitchellh.ghostty"]) == [10: "com.apple.Terminal", 20: "com.mitchellh.ghostty", 21: "com.mitchellh.ghostty"], "Disabled Termius is not managed")
expect(WindowPolicy.manages("com.termius-dmg.mac", identifier: nil, role: "AXWindow", subrole: "AXStandardWindow"), "Standard Termius windows are eligible")
expect(!WindowPolicy.manages("com.termius-dmg.mac", identifier: nil, role: "AXWindow", subrole: "AXDialog"), "Termius dialogs are excluded")
print("Termius: 8 config, selection and standard-window checks passed")

expect(decode(["fraction": 0.75, "applications": ["org.example.Editor"]])?.applications == ["org.example.Editor"], "Arbitrary bundle IDs are supported")
expect(ApplicationSelection.desired([RunningApplication(pid: 55, bundleIdentifier: "org.example.Editor")], applications: ["org.example.Editor"]) == [55: "org.example.Editor"], "Generic applications attach by exact bundle ID")
expect(decode(["fraction": 0.75, "applications": ["terminal"]])?.applications == ["com.apple.Terminal"], "Legacy selections migrate")
expect(decode(["fraction": 0.75, "applications": ["terminal", "com.apple.Terminal"]]) == nil, "Migration cannot create duplicate observers")
expect(Settings().applications.isEmpty && Settings().fraction == 0.75, "New installs require explicit application selection")
