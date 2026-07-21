import Foundation

@main
enum RemoteTouchSurfaceTests {
    static func main() {
        let cases: [(String, Bool, Bool)] = [
            ("A1513-sized external surface", RemoteTouchSurface.isEligible(width: 3460, height: 3640, builtIn: false), true),
            ("Magic Trackpad 2", RemoteTouchSurface.isEligible(width: 15600, height: 11040, builtIn: false), false),
            ("older Magic Trackpad", RemoteTouchSurface.isEligible(width: 9000, height: 8000, builtIn: false), false),
            ("built-in surface", RemoteTouchSurface.isEligible(width: 3460, height: 3640, builtIn: true), false),
            ("zero dimensions", RemoteTouchSurface.isEligible(width: 0, height: 0, builtIn: false), false),
            ("negative dimensions", RemoteTouchSurface.isEligible(width: -1, height: 3640, builtIn: false), false),
            ("threshold inclusive", RemoteTouchSurface.isEligible(width: 30_000_000, height: 1, builtIn: false), true),
            ("above threshold", RemoteTouchSurface.isEligible(width: 30_000_001, height: 1, builtIn: false), false),
        ]

        var failures = 0
        for (name, actual, expected) in cases {
            if actual == expected {
                print("✓ \(name)")
            } else {
                failures += 1
                print("✗ \(name): expected \(expected), got \(actual)")
            }
        }
        if failures > 0 { exit(1) }
    }
}
