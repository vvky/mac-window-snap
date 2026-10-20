import Foundation
import CoreGraphics

typealias ManagedApplication = String

func validBundleIdentifier(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
}

struct Settings: Codable {
    var fraction: Double = 0.75
    var applications: [ManagedApplication] = []

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fraction = try values.decode(Double.self, forKey: .fraction)
        // Read legacy selections during upgrades; new configurations use bundle identifiers.
        applications = try values.decodeIfPresent([ManagedApplication].self, forKey: .applications) ?? []
        let legacy = ["terminal": "com.apple.Terminal", "ghostty": "com.mitchellh.ghostty", "termius": "com.termius-dmg.mac"]
        applications = applications.map { legacy[$0] ?? $0 }
        guard applications.allSatisfy(validBundleIdentifier), fraction.isFinite, (0.3...0.95).contains(fraction),
              Set(applications).count == applications.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid fraction or duplicate applications"))
        }
    }

    static func load(from url: URL) -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Settings.self, from: data)
    }
}

enum WindowPolicy {
    static func manages(_ application: ManagedApplication, identifier: String?, role: String?, subrole: String?) -> Bool {
        // The native Quick Terminal uses this stable identifier and AXFloatingWindow.
        if application == "com.mitchellh.ghostty" && identifier == "com.mitchellh.ghostty.quickTerminal" { return false }
        // Do not resize preferences, dialogs, floating panels, or unknown window types.
        return role == "AXWindow" && subrole == "AXStandardWindow"
    }
}

struct RunningApplication {
    let pid: Int32
    let bundleIdentifier: String
}

enum ApplicationSelection {
    static func desired(_ running: [RunningApplication], applications: [ManagedApplication]) -> [Int32: ManagedApplication] {
        var result: [Int32: ManagedApplication] = [:]
        for process in running {
            if let target = applications.first(where: { $0 == process.bundleIdentifier }) {
                result[process.pid] = target
            }
        }
        return result
    }
}

enum WindowGeometry {
    static func screen(for window: CGRect, in screens: [CGRect]) -> CGRect? {
        // Prefer overlap. If completely off-screen, recover onto the nearest display.
        screens.min { lhs, rhs in
            let left = window.intersection(lhs), right = window.intersection(rhs)
            let leftArea = left.isNull ? 0 : left.width * left.height
            let rightArea = right.isNull ? 0 : right.width * right.height
            if leftArea != rightArea { return leftArea > rightArea }
            func distance(_ screen: CGRect) -> CGFloat {
                let dx = window.midX - screen.midX, dy = window.midY - screen.midY
                return dx * dx + dy * dy
            }
            return distance(lhs) < distance(rhs)
        }
    }

    static func centered(_ size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(x: (screen.midX - size.width / 2).rounded(),
                y: (screen.midY - size.height / 2).rounded())
    }
}
