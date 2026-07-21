//
//  Theme.swift
//  Baton
//
//  Design tokens ported from web/src/styles.css. Each token maps a CSS variable
//  to a SwiftUI Color that resolves per appearance. Light/dark come from the
//  CSS :root and :root[data-appearance=dark] / auto prefers-color-scheme blocks.
//

import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Codable, Hashable {
    case auto, light, dark

    var displayName: String {
        switch self {
        case .auto:  return "跟随系统"
        case .light: return "浅色"
        case .dark:  return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .auto:   return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    /// Build a SwiftUI Color from a light/dark hex pair. Used by every theme
    /// token below. Pass hex strings without the leading "#".
    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            var v: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&v)
            let r = CGFloat((v >> 16) & 0xff) / 255
            let g = CGFloat((v >> 8)  & 0xff) / 255
            let b = CGFloat(v & 0xff) / 255
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }))
    }

    // Surfaces
    static let batonBg           = dynamic(light: "ffffff", dark: "1d1d1f")
    static let batonSurface      = dynamic(light: "f5f5f7", dark: "000000")
    static let batonSurfaceWarm  = dynamic(light: "fbfbfd", dark: "151516")
    // The legacy CSS deliberately lifts the sidebar above the pure-black
    // detail surface in dark mode (`.sidebar { background: var(--bg) }`).
    // In light mode it continues to use the regular grouped surface.
    static let batonSidebar      = dynamic(light: "f5f5f7", dark: "1d1d1f")

    // Text
    static let batonFg           = dynamic(light: "1d1d1f", dark: "f5f5f7")
    static let batonFg2          = dynamic(light: "424245", dark: "d2d2d7")
    static let batonMuted        = dynamic(light: "6e6e73", dark: "a1a1a6")
    static let batonMeta         = dynamic(light: "86868b", dark: "86868b")

    // Borders
    static let batonBorder       = dynamic(light: "d2d2d7", dark: "38383a")
    static let batonBorderSoft   = dynamic(light: "e8e8ed", dark: "2c2c2e")

    // Accent (Apple link blue)
    static let batonAccent        = dynamic(light: "0071e3", dark: "2997ff")
    static let batonAccentHover   = dynamic(light: "0077ed", dark: "47a8ff")
    static let batonAccentActive  = dynamic(light: "0066cc", dark: "0a84ff")
    static let batonAccentOn      = Color.white

    // Semantic
    static let batonSuccess       = dynamic(light: "16a34a", dark: "30d158")
    static let batonWarn          = dynamic(light: "eab308", dark: "ffd60a")
    static let batonDanger        = dynamic(light: "dc2626", dark: "ff453a")
}

/// Spacing scale from --space-1..--space-12 in styles.css. Use these instead of
/// raw numeric literals so we stay in lock-step with the design tokens.
enum Spacing {
    static let s1: CGFloat  = 4
    static let s2: CGFloat  = 8
    static let s3: CGFloat  = 12
    static let s4: CGFloat  = 16
    static let s5: CGFloat  = 20
    static let s6: CGFloat  = 24
    static let s8: CGFloat  = 32
    static let s12: CGFloat = 48
}

/// Radii from --radius-sm/md/lg/pill.
enum Radius {
    static let sm: CGFloat   = 8
    static let md: CGFloat   = 12
    static let lg: CGFloat   = 18
    static let pill: CGFloat = 980
}

/// CSS animation/motion tokens. Use these as `.animation(.easeInOut(duration: Motion.base), ...)`.
enum Motion {
    static let fast: Double  = 0.15
    static let base: Double  = 0.22
    static let modal: Double = 0.22
}

/// Typography. CSS uses SF Pro Display / Text / Mono with a specific size ramp
/// (11/12/13/15/17/20/30/...). Pin the PostScript names so we don't get the
/// subtly-different `.system(design:)` mappings.
enum BatonFont {
    static func display(size: CGFloat, weight: SwiftUI.Font.Weight = .regular, tracking: CGFloat = -0.3) -> Font {
        // Tracking is applied via .tracking() at the call site since Font lacks a tracking parameter.
        _ = tracking
        return .custom("SF Pro Display", size: size, relativeTo: .body).weight(weight)
    }
    static func text(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> Font {
        .custom("SF Pro Text", size: size, relativeTo: .body).weight(weight)
    }
    static func mono(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> Font {
        .custom("SF Mono", size: size, relativeTo: .body).weight(weight)
    }
}

/// Shadows from --shadow-card/popover/toast/btn/window. Apply with .shadow(...) on the view.
struct BatonShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    static let card    = BatonShadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
    static let popover = BatonShadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
    static let btn     = BatonShadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 2)
    static let modal   = BatonShadow(color: .black.opacity(0.22), radius: 60, x: 0, y: 24)
}

extension View {
    func batonCardShadow() -> some View {
        // --shadow-card = 0 1px 3px rgba(0,0,0,0.12), 0 0 0 0.5px rgba(0,0,0,0.04).
        // Approximate via a soft shadow + 0.5pt stroke that approximates the 0.5px ring.
        self.shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
    }

    func batonModalShadow() -> some View {
        // --modal = 0 24px 60px rgba(0,0,0,0.22), 0 2px 8px rgba(0,0,0,0.08).
        self.shadow(color: .black.opacity(0.22), radius: 60, x: 0, y: 24)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }

    func batonPopoverShadow() -> some View {
        // --shadow-popover = 0 1px 3px rgba(0,0,0,0.25).
        self.shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
    }

    /// Apply the design-system focus ring (4px accent at 65% opacity).
    func batonFocusRing<S: Shape>(_ shape: S) -> some View {
        self.overlay(shape.stroke(Color.batonAccent.opacity(0.35), lineWidth: 4))
    }
}
