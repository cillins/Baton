//
//  RemoteArt.swift
//  Baton
//
//  Renders the gen1 / gen2 Siri Remote SVG art used in the detail-art column.
//  The parser supports the subset of SVG the artwork
//  uses: <path d>, <circle>, <rect>, plus fill/stroke via attribute or
//  inline style. gen2's body has a linearGradient reference
//  (url(#paint0_linear_478_85)) which we substitute with a vertical
//  LinearGradient matching the stops (#e8e8ed -> #86868b).
//

import SwiftUI

/// A drawable shape extracted from one SVG primitive.
enum ArtShape {
    case path(Path, fill: ShapeFill, evenOdd: Bool)
    case ellipse(CGRect, fill: ShapeFill)
    case ellipseStroked(CGRect, stroke: Color, lineWidth: CGFloat)
    case rect(CGRect, cornerRadius: CGFloat, fill: ShapeFill)
}

/// Fill type for a shape - either a solid color or the gen2 body gradient.
enum ShapeFill {
    case color(Color)
    /// gen2 body: vertical gradient #e8e8ed (top) -> #86868b (bottom).
    /// Same in light and dark mode (the SVG is hardcoded, not appearance-aware).
    case bodyGradient
}

/// One rendered remote (a list of shapes drawn back-to-front).
struct RemoteArt {
    let width: CGFloat
    let height: CGFloat
    let shapes: [ArtShape]
}

/// Public entry points keyed by the stable `gen1` / `gen2` generation tags.
enum RemoteArtCatalog {
    static func art(for generation: String) -> RemoteArt {
        switch generation {
        case "gen1": return parseSVG(RemoteArtSVGs.gen1, defaultSize: CGSize(width: 238, height: 773))
        case "gen2": return parseSVG(RemoteArtSVGs.gen2, defaultSize: CGSize(width: 238, height: 920))
        default:     return parseSVG(RemoteArtSVGs.gen2, defaultSize: CGSize(width: 238, height: 920))
        }
    }
}

/// Raw SVG strings for the remote artwork.
private enum RemoteArtSVGs {
    static let gen2 = """
<svg width="238" height="920" viewBox="0 0 238 920" fill="none" xmlns="http://www.w3.org/2000/svg"><g clip-path="url(#clip0_478_85)"><path d="M0 46C0 20.5949 20.5949 0 46 0H192C217.405 0 238 20.5949 238 46V874C238 899.405 217.405 920 192 920H46C20.5949 920 0 899.405 0 874V46Z" fill="url(#paint0_linear_478_85)"/><circle cx="189.5" cy="48.5" r="19.5" style="stroke:#86868b" stroke-width="2"/><path d="M212 448V551C210.46 573.349 191.74 591 169 591C146.26 591 127.54 573.349 126 551V448C126 424.252 145.252 405 169 405C192.748 405 212 424.252 212 448Z" style="fill:#1d1d1f"/><circle cx="69" cy="548" r="43" style="fill:#1d1d1f"/><circle cx="169" cy="348" r="43" style="fill:#1d1d1f"/><circle cx="69" cy="348" r="43" style="fill:#1d1d1f"/><circle cx="69" cy="448" r="43" style="fill:#1d1d1f"/><circle cx="119" cy="193" r="105" style="fill:#1d1d1f"/><rect x="112" y="44" width="14" height="6" rx="3" style="fill:#1d1d1f"/><path fill-rule="evenodd" clip-rule="evenodd" d="M119 251C151.033 251 177 225.033 177 193C177 160.967 151.033 135 119 135C86.9675 135 61 160.967 61 193C61 225.033 86.9675 251 119 251ZM119 252C151.585 252 178 225.585 178 193C178 160.415 151.585 134 119 134C86.4152 134 60 160.415 60 193C60 225.585 86.4152 252 119 252Z" style="fill:#424245"/><circle cx="213" cy="193" r="3" style="fill:#d2d2d7"/><circle cx="25" cy="193" r="3" style="fill:#d2d2d7"/><circle cx="119" cy="287" r="3" transform="rotate(90 119 287)" style="fill:#d2d2d7"/><circle cx="119" cy="99" r="3" transform="rotate(90 119 99)" style="fill:#d2d2d7"/><path d="M157.754 355.391H179.762C181.707 355.391 182.691 354.441 182.691 352.461V339.734C182.691 337.754 181.707 336.805 179.762 336.805H157.754C155.809 336.805 154.824 337.754 154.824 339.734V352.461C154.824 354.441 155.809 355.391 157.754 355.391ZM157.812 353.48C157.062 353.48 156.734 353.176 156.734 352.402V339.793C156.734 339.02 157.062 338.715 157.812 338.715H179.703C180.441 338.715 180.781 339.02 180.781 339.793V352.402C180.781 353.176 180.441 353.48 179.703 353.48H157.812ZM162.559 359.188H174.957C175.473 359.188 175.895 358.766 175.895 358.25C175.895 357.734 175.473 357.312 174.957 357.312H162.559C162.043 357.312 161.621 357.734 161.621 358.25C161.621 358.766 162.043 359.188 162.559 359.188Z" style="fill:#e8e8ed"/><path d="M74.1016 457.23C74.6875 457.23 75.1562 456.785 75.1562 456.211V439.805C75.1562 439.23 74.6875 438.785 74.1016 438.785C73.5273 438.785 73.0586 439.23 73.0586 439.805V456.211C73.0586 456.785 73.5273 457.23 74.1016 457.23ZM81.5781 457.23C82.1523 457.23 82.6211 456.785 82.6211 456.211V439.805C82.6211 439.23 82.1523 438.785 81.5781 438.785C80.9922 438.785 80.5234 439.23 80.5234 439.805V456.211C80.5234 456.785 80.9922 457.23 81.5781 457.23ZM56.4883 456.785C56.957 456.785 57.3438 456.645 57.8008 456.375L69.1211 449.719C69.918 449.238 70.293 448.676 70.293 448.008C70.293 447.328 69.9297 446.777 69.1211 446.297L57.8008 439.641C57.332 439.371 56.957 439.23 56.4883 439.23C55.5859 439.23 54.8242 439.91 54.8242 441.188V454.828C54.8242 456.105 55.5859 456.785 56.4883 456.785ZM57.0273 454.57C56.875 454.57 56.7461 454.465 56.7461 454.254V441.762C56.7461 441.551 56.875 441.445 57.0273 441.445C57.0977 441.445 57.1797 441.48 57.2852 441.539L67.7031 447.715C67.8555 447.797 67.9375 447.867 67.9375 448.008C67.9375 448.148 67.8555 448.219 67.7031 448.301L57.2852 454.477C57.1914 454.535 57.0977 454.57 57.0273 454.57Z" style="fill:#e8e8ed"/><path d="M169.024 459.485C169.659 459.485 170.192 458.965 170.192 458.343V450.522H177.81C178.432 450.522 178.978 449.989 178.978 449.342C178.978 448.707 178.432 448.174 177.81 448.174H170.192V440.341C170.192 439.706 169.659 439.186 169.024 439.186C168.377 439.186 167.844 439.706 167.844 440.341V448.174H160.227C159.604 448.174 159.059 448.707 159.059 449.342C159.059 449.989 159.604 450.522 160.227 450.522H167.844V458.343C167.844 458.965 168.377 459.485 169.024 459.485Z" style="fill:#e8e8ed"/><path d="M160.227 549.522H177.81C178.432 549.522 178.978 548.989 178.978 548.342C178.978 547.707 178.432 547.174 177.81 547.174H160.227C159.604 547.174 159.059 547.707 159.059 548.342C159.059 548.989 159.604 549.522 160.227 549.522Z" style="fill:#e8e8ed"/><path d="M75.3574 552.389V540.176C75.3574 539.363 74.748 538.69 73.9102 538.69C73.3262 538.69 72.9326 538.97 72.2979 539.541L67.1182 544.124L68.4893 545.508L72.9834 541.433C73.0469 541.369 73.1104 541.331 73.1865 541.331C73.2754 541.331 73.3389 541.395 73.3389 541.509V550.37L75.3574 552.389ZM79.293 561.212C79.6611 561.58 80.2705 561.58 80.626 561.212C80.9814 560.844 80.9814 560.26 80.626 559.892L59.8945 539.173C59.5264 538.817 58.9297 538.805 58.5615 539.173C58.2061 539.528 58.2061 540.138 58.5615 540.493L79.293 561.212ZM63.2207 554.306H66.6484C66.75 554.306 66.8516 554.331 66.9277 554.407L72.2979 559.206C72.8945 559.739 73.3389 559.993 73.9355 559.993C74.4434 559.993 74.8496 559.752 75.1289 559.32L73.5293 557.733L67.918 552.681C67.6768 552.465 67.5117 552.414 67.1943 552.414H63.3477C62.9033 552.414 62.7129 552.211 62.7129 551.779V546.892L61.1514 545.343C60.8594 545.736 60.6943 546.308 60.6943 547.057V551.652C60.6943 553.442 61.5322 554.306 63.2207 554.306Z" style="fill:#e8e8ed"/><path d="M60.5117 348.329C60.5117 348.672 60.6514 348.964 60.9053 349.218L70.3633 358.485C70.5918 358.701 70.8838 358.828 71.2266 358.828C71.8994 358.828 72.4326 358.308 72.4326 357.622C72.4326 357.279 72.293 356.987 72.0771 356.759L63.4443 348.329L72.0771 339.887C72.293 339.671 72.4326 339.354 72.4326 339.036C72.4326 338.351 71.8994 337.83 71.2266 337.83C70.8838 337.83 70.5918 337.944 70.3633 338.173L60.9053 347.428C60.6514 347.694 60.5117 347.986 60.5117 348.329Z" style="fill:#e8e8ed"/><path d="M189.499 48.7705C190.197 48.7705 190.659 48.2764 190.659 47.5352V38.7051C190.659 37.9639 190.197 37.459 189.499 37.459C188.801 37.459 188.328 37.9639 188.328 38.7051V47.5352C188.328 48.2764 188.801 48.7705 189.499 48.7705ZM189.499 59.2441C195.289 59.2441 200.069 54.4639 200.069 48.6631C200.069 45.6123 198.737 42.9375 196.857 41.1436C195.729 40.0156 194.097 41.4873 195.268 42.7012C196.836 44.2051 197.792 46.3105 197.803 48.6631C197.813 53.2715 194.097 56.9775 189.499 56.9775C184.891 56.9775 181.195 53.2715 181.195 48.6631C181.206 46.2998 182.162 44.1943 183.73 42.6904C184.901 41.4766 183.258 40.0156 182.13 41.1328C180.25 42.9268 178.918 45.6123 178.918 48.6631C178.918 54.4639 183.698 59.2441 189.499 59.2441Z" style="fill:#1d1d1f"/></g><defs><linearGradient id="paint0_linear_478_85" x1="119" y1="0" x2="119" y2="920" gradientUnits="userSpaceOnUse"><stop style="stop-color:#e8e8ed"/><stop offset="1" style="stop-color:#86868b"/></linearGradient><clipPath id="clip0_478_85"><rect width="238" height="920" fill="white"/></clipPath></defs></svg>
"""

    static let gen1 = """
<svg width="238" height="773" viewBox="0 0 238 773" fill="none" xmlns="http://www.w3.org/2000/svg"><g clip-path="url(#clip0_52_462)"><path d="M0 336H238V729C238 753.301 218.301 773 194 773H44C19.6995 773 0 753.301 0 729V336Z" fill="#0D0D0F"/><path d="M0 44C0 19.6995 19.6995 0 44 0H194C218.301 0 238 19.6995 238 44V336H0V44Z" fill="#434142"/><path opacity="0.5" d="M132 383.5C132 362.237 149.237 345 170.5 345C191.763 345 209 362.237 209 383.5V489.5C209 510.763 191.763 528 170.5 528C149.237 528 132 510.763 132 489.5V383.5Z" fill="#333333"/><path d="M169.5 378C169.5 377.448 169.948 377 170.5 377C171.052 377 171.5 377.448 171.5 378V385.5H179C179.552 385.5 180 385.948 180 386.5C180 387.052 179.552 387.5 179 387.5H171.5V395C171.5 395.552 171.052 396 170.5 396C169.948 396 169.5 395.552 169.5 395V387.5H162C161.448 387.5 161 387.052 161 386.5C161 385.948 161.448 385.5 162 385.5H169.5V378Z" fill="#C4C4C4"/><path d="M180 486C180 485.448 179.552 485 179 485H162C161.448 485 161 485.448 161 486C161 486.552 161.448 487 162 487H179C179.552 487 180 486.552 180 486Z" fill="#C4C4C4"/><path opacity="0.5" d="M109 487C109 510.196 90.196 529 67 529C43.804 529 25 510.196 25 487C25 463.804 43.804 445 67 445C90.196 445 109 463.804 109 487Z" fill="#333333"/><path d="M72 481C72 480.448 72.4477 480 73 480C73.5523 480 74 480.448 74 481V493C74 493.552 73.5523 494 73 494C72.4477 494 72 493.552 72 493V481Z" fill="#C4C4C4"/><path d="M55.7902 480.521C54.791 479.902 53.5 480.621 53.5 481.796V492.313C53.5 493.453 54.7201 494.176 55.7197 493.629L64.7343 488.7C65.7427 488.148 65.7817 486.714 64.8048 486.109L55.7902 480.521Z" fill="#C4C4C4"/><path d="M80 480C79.4477 480 79 480.448 79 481V493C79 493.552 79.4477 494 80 494C80.5523 494 81 493.552 81 493V481C81 480.448 80.5523 480 80 480Z" fill="#C4C4C4"/><path opacity="0.5" d="M109 387C109 410.196 90.196 429 67 429C43.804 429 25 410.196 25 387C25 363.804 43.804 345 67 345C90.196 345 109 363.804 109 387Z" fill="#333333"/><path d="M67 372C64.2385 372 62 374.239 62 377V389C62 391.761 64.2385 394 67 394C69.7615 394 72 391.761 72 389V377C72 374.239 69.7615 372 67 372Z" fill="#C4C4C4"/><path d="M58 384C58 383.448 58.4478 383 59 383C59.5522 383 60 383.448 60 384V389C60 392.866 63.134 396 67 396C70.866 396 74 392.866 74 389V384C74 383.448 74.4478 383 75 383C75.5522 383 76 383.448 76 384V389C76 393.633 72.5 397.448 68 397.945V400H72C72.5522 400 73 400.448 73 401C73 401.552 72.5522 402 72 402H62C61.4478 402 61 401.552 61 401C61 400.448 61.4478 400 62 400H66V397.945C61.5 397.448 58 393.633 58 389V384Z" fill="#C4C4C4"/><path opacity="0.5" d="M213 287C213 310.196 194.196 329 171 329C147.804 329 129 310.196 129 287C129 263.804 147.804 245 171 245C194.196 245 213 263.804 213 287Z" fill="#333333"/><path fill-rule="evenodd" clip-rule="evenodd" d="M156 277C156 275.895 156.895 275 158 275H184C185.105 275 186 275.895 186 277V292C186 293.105 185.105 294 184 294H158C156.895 294 156 293.105 156 292V277ZM158 277H184V292H158V277Z" fill="#C4C4C4"/><path d="M167 297C166.448 297 166 297.448 166 298C166 298.552 166.448 299 167 299H175C175.552 299 176 298.552 176 298C176 297.448 175.552 297 175 297H167Z" fill="#C4C4C4"/><path opacity="0.5" d="M109 287C109 310.196 90.196 329 67 329C43.804 329 25 310.196 25 287C25 263.804 43.804 245 67 245C90.196 245 109 263.804 109 287Z" fill="#333333"/><path fill-rule="evenodd" clip-rule="evenodd" d="M67 324C87.4345 324 104 307.435 104 287C104 266.565 87.4345 250 67 250C46.5655 250 30 266.565 30 287C30 307.435 46.5655 324 67 324ZM67 329C90.196 329 109 310.196 109 287C109 263.804 90.196 245 67 245C43.804 245 25 263.804 25 287C25 310.196 43.804 329 67 329Z" fill="#C4C4C4"/><path d="M54.2227 293V281.021H52.0645L48.1963 290.567H48.1299L44.2534 281.021H42.1035V293H43.7969V284.184H43.855L47.4741 293H48.8521L52.4629 284.184H52.521V293H54.2227Z" fill="#C4C4C4"/><path d="M64.8842 291.389H59.14V287.67H64.5771V286.126H59.14V282.624H64.8842V281.021H57.2807V293H64.8842V291.389Z" fill="#C4C4C4"/><path d="M69.4529 293V284.176H69.5276L75.7366 293H77.4134V281.021H75.6038V289.854H75.5374L69.3284 281.021H67.6434V293H69.4529Z" fill="#C4C4C4"/><path d="M82.3391 281.021H80.4797V288.791C80.4797 291.373 82.3225 293.199 85.3273 293.199C88.3322 293.199 90.175 291.373 90.175 288.791V281.021H88.3239V288.633C88.3239 290.343 87.2365 291.547 85.3273 291.547C83.4182 291.547 82.3391 290.343 82.3391 288.633V281.021Z" fill="#C4C4C4"/><path d="M110 30.5C110 28.567 111.567 27 113.5 27H124.5C126.433 27 128 28.567 128 30.5C128 32.433 126.433 34 124.5 34H113.5C111.567 34 110 32.433 110 30.5Z" fill="#0D0D0F"/></g><defs><clipPath id="clip0_52_462"><rect width="238" height="773" fill="white"/></clipPath></defs></svg>
"""
}

/// Parse the supported SVG subset.
private func parseSVG(_ svg: String, defaultSize: CGSize) -> RemoteArt {
    var shapes: [ArtShape] = []
    shapes.append(contentsOf: parseElements(in: svg))
    return RemoteArt(width: defaultSize.width, height: defaultSize.height, shapes: shapes)
}

private func parseElements(in svg: String) -> [ArtShape] {
    var result: [ArtShape] = []
    var idx = svg.startIndex
    while idx < svg.endIndex {
        guard let openTag = svg.range(of: "<", range: idx..<svg.endIndex) else { break }
        let tail = svg[openTag.upperBound...]
        guard tail.first == "/" || tail.hasPrefix("path") || tail.hasPrefix("circle") || tail.hasPrefix("rect") else {
            if let next = svg.range(of: "<", range: openTag.upperBound..<svg.endIndex) {
                idx = next.lowerBound
                continue
            } else { break }
        }
        guard let close = svg.range(of: ">", range: openTag.upperBound..<svg.endIndex) else { break }
        let tagStr = String(svg[openTag.upperBound..<close.lowerBound])
        if !tagStr.hasSuffix("/") {
            idx = close.upperBound
            continue
        }
        let inner = String(tagStr.dropLast())
        let attrs = parseAttributes(inner)
        if inner.hasPrefix("path ") || inner.hasPrefix("path/") {
            if let d = attrs["d"], let fill = resolvedFill(attrs: attrs) {
                let path = pathFromD(d)
                if let p = path {
                    result.append(.path(
                        p,
                        fill: fill,
                        evenOdd: attrs["fill-rule"] == "evenodd"
                    ))
                }
            }
        } else if inner.hasPrefix("circle ") {
            if let cx = Double(attrs["cx"] ?? ""), let cy = Double(attrs["cy"] ?? ""),
               let r = Double(attrs["r"] ?? "") {
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                if let fill = resolvedFill(attrs: attrs) {
                    result.append(.ellipse(rect, fill: fill))
                } else if let stroke = resolvedStroke(attrs: attrs) {
                    // Circle with stroke but no fill (e.g. gen2 IR receiver).
                    let lw = CGFloat(Double(attrs["stroke-width"] ?? "") ?? 1)
                    result.append(.ellipseStroked(rect, stroke: stroke, lineWidth: lw))
                }
            }
        } else if inner.hasPrefix("rect ") {
            if let x = Double(attrs["x"] ?? "0"), let y = Double(attrs["y"] ?? "0"),
               let w = Double(attrs["width"] ?? "0"), let h = Double(attrs["height"] ?? "0"),
               let fill = resolvedFill(attrs: attrs) {
                let rx = CGFloat(Double(attrs["rx"] ?? "") ?? 0)
                let rect = CGRect(x: x, y: y, width: w, height: h)
                result.append(.rect(rect, cornerRadius: rx, fill: fill))
            }
        }
        idx = close.upperBound
    }
    return result
}

private func parseAttributes(_ tag: String) -> [String: String] {
    var attrs: [String: String] = [:]
    var idx = tag.startIndex
    while idx < tag.endIndex {
        while idx < tag.endIndex, tag[idx] == " " || tag[idx] == "\t" || tag[idx] == "\n" {
            idx = tag.index(after: idx)
        }
        guard idx < tag.endIndex else { break }
        let keyStart = idx
        while idx < tag.endIndex, tag[idx] != "=" && tag[idx] != " " {
            idx = tag.index(after: idx)
        }
        let key = String(tag[keyStart..<idx])
        guard idx < tag.endIndex, tag[idx] == "=" else {
            if !key.isEmpty { attrs[key] = "" }
            continue
        }
        idx = tag.index(after: idx)
        guard idx < tag.endIndex else { break }
        let quote = tag[idx]
        guard quote == "\"" || quote == "'" else { continue }
        idx = tag.index(after: idx)
        let valStart = idx
        while idx < tag.endIndex, tag[idx] != quote {
            idx = tag.index(after: idx)
        }
        let val = String(tag[valStart..<idx])
        if idx < tag.endIndex { idx = tag.index(after: idx) }
        attrs[key] = val
    }
    return attrs
}

/// Resolve the fill for an element. Checks `fill` attribute first, then
/// `style="fill:#hex"`. Returns nil for `fill="none"` or when no fill is
/// specified (caller can then check for stroke).
private func resolvedFill(attrs: [String: String]) -> ShapeFill? {
    // Direct fill attribute.
    if let fill = attrs["fill"], !fill.isEmpty {
        if fill == "none" { return nil }
        if fill.hasPrefix("url(#") { return .bodyGradient }
        if let c = colorFromHex(fill) { return .color(c) }
    }
    // style="fill:#hex"
    if let style = attrs["style"] {
        for decl in style.split(separator: ";") {
            let parts = decl.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "fill" {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                if v == "none" { return nil }
                if let c = colorFromHex(v) { return .color(c) }
            }
        }
    }
    return nil
}

/// Resolve the stroke color for an element. Checks `stroke` attribute, then
/// `style="stroke:#hex"`.
private func resolvedStroke(attrs: [String: String]) -> Color? {
    if let stroke = attrs["stroke"], !stroke.isEmpty {
        if stroke == "none" { return nil }
        if let c = colorFromHex(stroke) { return c }
    }
    if let style = attrs["style"] {
        for decl in style.split(separator: ";") {
            let parts = decl.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "stroke" {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                if v == "none" { return nil }
                if let c = colorFromHex(v) { return c }
            }
        }
    }
    return nil
}

private func colorFromHex(_ hex: String) -> Color? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    guard Scanner(string: s).scanHexInt64(&v) else { return nil }
    let r = Double((v >> 16) & 0xff) / 255
    let g = Double((v >> 8)  & 0xff) / 255
    let b = Double(v & 0xff) / 255
    return Color(red: r, green: g, blue: b)
}

/// Build a SwiftUI Path from an SVG path-d string. Supports the subset of
/// commands used by the gen1/gen2 art: M, L, H, V, C, Q, A, Z (absolute only).
private func pathFromD(_ d: String) -> Path? {
    var path = Path()
    var cx: CGFloat = 0, cy: CGFloat = 0
    var startX: CGFloat = 0, startY: CGFloat = 0
    var prevCmd: Character = " "
    var idx = d.startIndex
    while idx < d.endIndex {
        while idx < d.endIndex, " \t\n,".contains(d[idx]) {
            idx = d.index(after: idx)
        }
        guard idx < d.endIndex else { break }
        let cmd: Character
        if d[idx].isLetter {
            cmd = d[idx]
            idx = d.index(after: idx)
        } else {
            cmd = (prevCmd == "M") ? "L" : prevCmd
        }
        prevCmd = cmd
        switch cmd {
        case "M":
            guard let (x, y, next) = readPair(d, idx) else { return path }
            path.move(to: CGPoint(x: x, y: y))
            cx = x; cy = y; startX = x; startY = y
            idx = next
        case "L":
            guard let (x, y, next) = readPair(d, idx) else { return path }
            path.addLine(to: CGPoint(x: x, y: y))
            cx = x; cy = y
            idx = next
        case "H":
            guard let (x, next) = readNum(d, idx) else { return path }
            path.addLine(to: CGPoint(x: x, y: cy))
            cx = x
            idx = next
        case "V":
            guard let (y, next) = readNum(d, idx) else { return path }
            path.addLine(to: CGPoint(x: cx, y: y))
            cy = y
            idx = next
        case "C":
            guard let (x1, y1, n1) = readPair(d, idx) else { return path }
            guard let (x2, y2, n2) = readPair(d, n1) else { return path }
            guard let (x, y, n3) = readPair(d, n2) else { return path }
            path.addCurve(to: CGPoint(x: x, y: y),
                          control1: CGPoint(x: x1, y: y1),
                          control2: CGPoint(x: x2, y: y2))
            cx = x; cy = y
            idx = n3
        case "Q":
            guard let (x1, y1, n1) = readPair(d, idx) else { return path }
            guard let (x, y, n2) = readPair(d, n1) else { return path }
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
            cx = x; cy = y
            idx = n2
        case "A":
            guard let (rx, ry, n1) = readPair(d, idx) else { return path }
            guard let (xrot, n2) = readNum(d, n1) else { return path }
            guard let (large, n3) = readFlag(d, n2) else { return path }
            guard let (sweep, n4) = readFlag(d, n3) else { return path }
            guard let (x, y, n5) = readPair(d, n4) else { return path }
            _ = xrot
            path.addArc(center: CGPoint(x: (cx + x) / 2, y: (cy + y) / 2),
                        radius: max(rx, ry),
                        startAngle: .degrees(0),
                        endAngle: .degrees(360),
                        clockwise: sweep == 1)
            path.addLine(to: CGPoint(x: x, y: y))
            cx = x; cy = y
            idx = n5
            _ = large
        case "Z", "z":
            path.closeSubpath()
            cx = startX; cy = startY
        default:
            return path
        }
    }
    return path
}

private func readNum(_ s: String, _ start: String.Index) -> (CGFloat, String.Index)? {
    var idx = start
    while idx < s.endIndex, " \t\n,".contains(s[idx]) { idx = s.index(after: idx) }
    var end = idx
    var sawDigit = false
    var sawDot = false
    if end < s.endIndex, s[end] == "-" { end = s.index(after: end) }
    while end < s.endIndex {
        let c = s[end]
        if c.isNumber { sawDigit = true; end = s.index(after: end) }
        else if c == "." && !sawDot { sawDot = true; end = s.index(after: end) }
        else if c == "e" || c == "E" { end = s.index(after: end) }
        else if (c == "-" || c == "+"), sawDigit, end != start {
            end = s.index(after: end)
        }
        else { break }
    }
    guard sawDigit, let val = Double(s[idx..<end]) else { return nil }
    return (CGFloat(val), end)
}

private func readPair(_ s: String, _ start: String.Index) -> (CGFloat, CGFloat, String.Index)? {
    guard let (x, n1) = readNum(s, start) else { return nil }
    guard let (y, n2) = readNum(s, n1) else { return nil }
    return (x, y, n2)
}

private func readFlag(_ s: String, _ start: String.Index) -> (Int, String.Index)? {
    var idx = start
    while idx < s.endIndex, " \t\n,".contains(s[idx]) { idx = s.index(after: idx) }
    guard idx < s.endIndex else { return nil }
    let c = s[idx]
    if c == "0" || c == "1" {
        return (c == "1" ? 1 : 0, s.index(after: idx))
    }
    return nil
}

// MARK: - Body gradient colors

/// gen2 body gradient stops. Hardcoded from the SVG <linearGradient> def:
/// #e8e8ed (top) -> #86868b (bottom). Same in light and dark mode.
private let bodyGradientTop = Color(red: 0.91, green: 0.91, blue: 0.93)
private let bodyGradientBottom = Color(red: 0.525, green: 0.525, blue: 0.545)

/// SwiftUI view that renders a RemoteArt scaled to fit its frame.
struct RemoteArtView: View {
    let art: RemoteArt
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / art.width
            let scaleY = size.height / art.height
            let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            for shape in art.shapes {
                switch shape {
                case .path(let p, let fill, let evenOdd):
                    let scaledPath = p.applying(transform)
                    context.fill(
                        scaledPath,
                        with: shading(fill, transform: transform),
                        style: FillStyle(eoFill: evenOdd)
                    )
                case .ellipse(let r, let fill):
                    let scaled = r.applying(transform)
                    context.fill(Path(ellipseIn: scaled), with: shading(fill, transform: transform))
                case .ellipseStroked(let r, let stroke, let lineWidth):
                    let scaled = r.applying(transform)
                    context.stroke(Path(ellipseIn: scaled),
                                   with: .color(stroke),
                                   lineWidth: lineWidth * min(scaleX, scaleY))
                case .rect(let r, let cornerRadius, let fill):
                    let scaled = r.applying(transform)
                    let path = Path(roundedRect: scaled, cornerRadius: cornerRadius * min(scaleX, scaleY))
                    context.fill(path, with: shading(fill, transform: transform))
                }
            }
        }
        .aspectRatio(art.width / art.height, contentMode: .fit)
    }

    /// Convert a ShapeFill to a GraphicsContext.Shading. For the body gradient,
    /// the start/end points are in the art's coordinate space (before scaling)
    /// then transformed to the display space.
    private func shading(_ fill: ShapeFill, transform: CGAffineTransform) -> GraphicsContext.Shading {
        switch fill {
        case .color(let c):
            return .color(c)
        case .bodyGradient:
            let start = CGPoint(x: 0, y: 0).applying(transform)
            let end = CGPoint(x: 0, y: art.height).applying(transform)
            return .linearGradient(
                Gradient(colors: [bodyGradientTop, bodyGradientBottom]),
                startPoint: start,
                endPoint: end
            )
        }
    }
}
