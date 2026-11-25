import Foundation

/// A robot face built from a seed: head, eyes, mouth, antenna and ears drawn
/// from a small set of parts, so every profile gets its own and a kid can
/// press "Otro robot" until one feels right. The same seed always gives the
/// same robot. The robot is a list of plain shapes on a 100 × 100 canvas,
/// which the app draws with SwiftUI and the CLI writes out as SVG.
public struct Robot: Sendable, Hashable {
    public struct Point: Sendable, Hashable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { (self.x, self.y) = (x, y) }
    }

    public enum Shape: Sendable, Hashable {
        case rect(x: Double, y: Double, width: Double, height: Double, radius: Double, fill: RGB)
        case ellipse(cx: Double, cy: Double, rx: Double, ry: Double, fill: RGB)
        /// A stroked polyline, round caps and joins.
        case line([Point], width: Double, color: RGB)
        /// A stroked arc. Angles in degrees, 0 pointing right, growing
        /// clockwise on screen (y grows downward); drawn from `from` to `to`.
        case arc(cx: Double, cy: Double, radius: Double, from: Double, to: Double, width: Double, color: RGB)
    }

    public static let canvas: Double = 100

    public let seed: UInt64
    /// Back to front.
    public let shapes: [Shape]

    /// `background` is the profile color behind the robot: the accent parts
    /// pick a different color so they never vanish into it.
    public init(seed: UInt64, background: ProfileColor) {
        self.seed = seed
        var random = SplitMix64(seed: seed)
        shapes = Self.build(&random, background: background)
    }

    // MARK: Parts

    static let metals: [RGB] = [
        RGB(hex: 0xECEFF1), RGB(hex: 0xF5E9CF), RGB(hex: 0xD3DEE6), RGB(hex: 0xF3DCD0), RGB(hex: 0xDCEFE0), RGB(hex: 0xE6E0F5),
    ]
    static let ink = RGB(hex: 0x22252C)
    static let white = RGB(hex: 0xFFFFFF)

    enum HeadShape: CaseIterable { case boxy, rounded, pill, round }
    enum Eyes: CaseIterable { case round, dots, square, visor, cyclops, happy }
    enum Mouth: CaseIterable { case grille, smile, flat, teeth, oh }
    enum Antenna: CaseIterable { case none, ball, double, bolt }
    enum Ears: CaseIterable { case none, bolts, discs }

    private static func build(_ random: inout SplitMix64, background: ProfileColor) -> [Shape] {
        let metal = random.pick(metals)
        let shade = metal.scaled(0.78)
        let accent = random.pick(ProfileColor.allCases.filter { $0 != background }).rgb
        let glow = accent.mixed(with: white, 0.55)

        let headWidth = random.range(46, 60)
        let headHeight = random.range(38, 46)
        let headBottom = 74.0
        let headTop = headBottom - headHeight
        let left = 50 - headWidth / 2
        let right = 50 + headWidth / 2
        let headKind = random.pick(HeadShape.allCases)
        let screen = random.chance(0.4)

        var shapes: [Shape] = []

        // Shoulders and neck, cut off by the circle below.
        shapes.append(.rect(x: 16, y: 82, width: 68, height: 40, radius: 18, fill: shade))
        shapes.append(.ellipse(cx: 50, cy: 93, rx: 5, ry: 5, fill: accent))
        shapes.append(.rect(x: 43, y: headBottom - 2, width: 14, height: 12, radius: 2, fill: shade.scaled(0.85)))

        // Antenna, behind the head.
        switch random.pick(Antenna.allCases) {
        case .none:
            break
        case .ball:
            let height = random.range(9, 14)
            shapes.append(.line([Point(50, headTop + 2), Point(50, headTop - height)], width: 2.5, color: shade))
            shapes.append(.ellipse(cx: 50, cy: headTop - height, rx: 4.5, ry: 4.5, fill: accent))
        case .double:
            let spread = headWidth * 0.28
            for x in [50 - spread, 50 + spread] {
                shapes.append(.line([Point(x, headTop + 2), Point(x, headTop - 9)], width: 2.2, color: shade))
                shapes.append(.ellipse(cx: x, cy: headTop - 9, rx: 3.2, ry: 3.2, fill: accent))
            }
        case .bolt:
            shapes.append(.line(
                [Point(50, headTop + 2), Point(50, headTop - 4), Point(46, headTop - 8), Point(54, headTop - 12), Point(50, headTop - 16)],
                width: 2.5, color: accent
            ))
        }

        // Ears, behind the head's sides.
        let middle = headTop + headHeight / 2
        switch random.pick(Ears.allCases) {
        case .none:
            break
        case .bolts:
            for x in [left - 5, right - 1] {
                shapes.append(.rect(x: x, y: middle - 7, width: 6, height: 14, radius: 2, fill: accent))
            }
        case .discs:
            for x in [left, right] {
                shapes.append(.ellipse(cx: x, cy: middle, rx: 5.5, ry: 5.5, fill: accent))
            }
        }

        // The head.
        switch headKind {
        case .boxy: shapes.append(.rect(x: left, y: headTop, width: headWidth, height: headHeight, radius: 5, fill: metal))
        case .rounded: shapes.append(.rect(x: left, y: headTop, width: headWidth, height: headHeight, radius: 13, fill: metal))
        case .pill: shapes.append(.rect(x: left, y: headTop, width: headWidth, height: headHeight, radius: headHeight / 2, fill: metal))
        case .round: shapes.append(.ellipse(cx: 50, cy: middle, rx: headWidth / 2, ry: headHeight / 2, fill: metal))
        }

        // A dark screen for a face: the eyes then glow on it.
        let eyeColor: RGB
        let faceInk: RGB
        if screen {
            let inset = headKind == .round ? headWidth * 0.17 : 6
            let plateWidth = headWidth - 2 * inset
            let plateHeight = headHeight * 0.62
            shapes.append(.rect(
                x: 50 - plateWidth / 2, y: headTop + headHeight * 0.18, width: plateWidth, height: plateHeight,
                radius: min(10, plateHeight / 2), fill: ink
            ))
            eyeColor = glow
            faceInk = glow
        } else {
            eyeColor = white
            faceInk = ink
        }

        // Eyes.
        let eyeY = headTop + headHeight * (screen ? 0.4 : 0.42)
        let spread = random.range(9, min(14, headWidth * 0.24))
        let look = random.range(-1.2, 1.2)
        let eyes = random.pick(Eyes.allCases)
        switch eyes {
        case .round:
            for x in [50 - spread, 50 + spread] {
                shapes.append(.ellipse(cx: x, cy: eyeY, rx: 6.5, ry: 6.5, fill: eyeColor))
                if !screen { shapes.append(.ellipse(cx: x + look, cy: eyeY, rx: 3.2, ry: 3.2, fill: ink)) }
            }
        case .dots:
            for x in [50 - spread, 50 + spread] {
                shapes.append(.ellipse(cx: x, cy: eyeY, rx: 3.8, ry: 4.4, fill: faceInk))
            }
        case .square:
            for x in [50 - spread, 50 + spread] {
                shapes.append(.rect(x: x - 5, y: eyeY - 5, width: 10, height: 10, radius: 2.5, fill: screen ? glow : accent))
            }
        case .visor:
            let width = spread * 2 + 14
            shapes.append(.rect(x: 50 - width / 2, y: eyeY - 4.5, width: width, height: 9, radius: 4.5, fill: screen ? glow : accent))
            shapes.append(.rect(x: 50 - width / 2 + 4, y: eyeY - 2.5, width: 7, height: 2.5, radius: 1.25, fill: white))
        case .cyclops:
            shapes.append(.ellipse(cx: 50, cy: eyeY, rx: 9, ry: 9, fill: eyeColor))
            shapes.append(.ellipse(cx: 50 + look, cy: eyeY, rx: 4.2, ry: 4.2, fill: screen ? ink : accent.scaled(0.6)))
        case .happy:
            for x in [50 - spread, 50 + spread] {
                shapes.append(.arc(cx: x, cy: eyeY + 2, radius: 4.5, from: 200, to: 340, width: 2.8, color: faceInk))
            }
        }

        // Mouth.
        let mouthY = headTop + headHeight * (screen ? 0.66 : 0.74)
        var mouth = random.pick(Mouth.allCases)
        // One round eye over a round mouth reads as a ♀ sign.
        if eyes == .cyclops, mouth == .oh { mouth = .smile }
        switch mouth {
        case .grille:
            shapes.append(.rect(x: 40, y: mouthY - 3.5, width: 20, height: 7, radius: 2, fill: screen ? glow : ink))
            for x in [45.0, 50, 55] {
                shapes.append(.line([Point(x, mouthY - 3.5), Point(x, mouthY + 3.5)], width: 1.2, color: screen ? ink : metal))
            }
        case .smile:
            shapes.append(.arc(cx: 50, cy: mouthY - 5, radius: 7, from: 25, to: 155, width: 2.8, color: faceInk))
        case .flat:
            shapes.append(.line([Point(44, mouthY), Point(56, mouthY)], width: 2.8, color: faceInk))
        case .teeth:
            shapes.append(.rect(x: 41, y: mouthY - 3.5, width: 18, height: 7, radius: 1.5, fill: white))
            for x in [47.0, 53] {
                shapes.append(.line([Point(x, mouthY - 3.5), Point(x, mouthY + 3.5)], width: 1, color: ink))
            }
        case .oh:
            shapes.append(.ellipse(cx: 50, cy: mouthY, rx: 3.6, ry: 3.2, fill: faceInk))
        }

        // Cheeks, on a plain face only.
        if !screen, random.chance(0.35) {
            let blush = accent.mixed(with: white, 0.35)
            for x in [50 - spread - 4, 50 + spread + 4] {
                shapes.append(.ellipse(cx: x, cy: mouthY - 2, rx: 3.4, ry: 2.4, fill: blush))
            }
        }
        return shapes
    }

    // MARK: SVG

    /// The robot on its profile color, clipped to a circle, as an SVG document.
    public func svg(background: ProfileColor, size: Int = 200) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\" width=\"\(size)\" height=\"\(size)\">\n"
            + svgGroup(background: background) + "\n</svg>\n"
    }

    /// The robot as a `<g>` (with its own clip path), for placing several on one sheet.
    public func svgGroup(background: ProfileColor, transform: String? = nil) -> String {
        let clip = "c\(String(seed, radix: 36))"
        var lines = [
            "<g\(transform.map { " transform=\"\($0)\"" } ?? "")>",
            "<clipPath id=\"\(clip)\"><circle cx=\"50\" cy=\"50\" r=\"50\"/></clipPath>",
            "<g clip-path=\"url(#\(clip))\">",
            "<rect width=\"100\" height=\"100\" fill=\"\(background.rgb.hex)\"/>",
        ]
        lines += shapes.map(Self.svgElement)
        lines += ["</g>", "</g>"]
        return lines.joined(separator: "\n")
    }

    static func svgElement(_ shape: Shape) -> String {
        func n(_ value: Double) -> String { String(format: "%.2f", value) }
        switch shape {
        case let .rect(x, y, width, height, radius, fill):
            return "<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(width))\" height=\"\(n(height))\" rx=\"\(n(radius))\" fill=\"\(fill.hex)\"/>"
        case let .ellipse(cx, cy, rx, ry, fill):
            return "<ellipse cx=\"\(n(cx))\" cy=\"\(n(cy))\" rx=\"\(n(rx))\" ry=\"\(n(ry))\" fill=\"\(fill.hex)\"/>"
        case let .line(points, width, color):
            let list = points.map { "\(n($0.x)),\(n($0.y))" }.joined(separator: " ")
            return "<polyline points=\"\(list)\" fill=\"none\" stroke=\"\(color.hex)\" stroke-width=\"\(n(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        case let .arc(cx, cy, radius, from, to, width, color):
            let start = Point(cx + radius * cos(from * .pi / 180), cy + radius * sin(from * .pi / 180))
            let end = Point(cx + radius * cos(to * .pi / 180), cy + radius * sin(to * .pi / 180))
            let large = (to - from).truncatingRemainder(dividingBy: 360) > 180 ? 1 : 0
            return "<path d=\"M\(n(start.x)) \(n(start.y)) A\(n(radius)) \(n(radius)) 0 \(large) 1 \(n(end.x)) \(n(end.y))\" fill=\"none\" stroke=\"\(color.hex)\" stroke-width=\"\(n(width))\" stroke-linecap=\"round\"/>"
        }
    }
}

extension RGB {
    func scaled(_ factor: Double) -> RGB {
        RGB(UInt8(Double(r) * factor), UInt8(Double(g) * factor), UInt8(Double(b) * factor))
    }

    func mixed(with other: RGB, _ amount: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - amount) + Double(b) * amount).rounded()) }
        return RGB(mix(r, other.r), mix(g, other.g), mix(b, other.b))
    }
}

/// A small, fast, seedable generator (Vigna's SplitMix64): the same numbers
/// for the same seed on every platform, which `SystemRandomNumberGenerator` isn't.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1), from the top 53 bits.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
    mutating func pick<T>(_ options: [T]) -> T { options[Int(next() % UInt64(options.count))] }
}
