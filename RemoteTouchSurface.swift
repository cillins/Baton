//
//  RemoteTouchSurface.swift
//  Baton
//
//  Framework-free touch-surface identity check, kept separate so it can be
//  tested without linking Apple's private MultitouchSupport framework.
//

import Foundation

enum RemoteTouchSurface {
    /// Known Siri Remote touch surfaces are about 12.6M raw area units;
    /// Magic Trackpads are at least several times larger. Keep generous
    /// headroom for remote firmware/model variation while rejecting trackpads.
    static let maxSurfaceArea: Int64 = 30_000_000

    static func isEligible(width: Int32, height: Int32, builtIn: Bool) -> Bool {
        guard !builtIn, width > 0, height > 0 else { return false }
        return Int64(width) * Int64(height) <= maxSurfaceArea
    }
}
