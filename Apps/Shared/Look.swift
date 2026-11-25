import MatineKit
import SwiftUI

// Drawn the same on the Apple TV and the phone: one copy, in both apps (Apps/Shared).

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

/// A profile's circle: its robot or animal on its color.
struct AvatarView: View {
    let avatar: Avatar
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(avatar.color.rgb))
            switch avatar.figure {
            case .robot(let seed):
                RobotFace(robot: Robot(seed: seed, background: avatar.color))
            case .animal(let animal):
                Image(systemName: animal.rawValue)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.015)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// A `Robot`'s shapes, drawn at any size (they're laid out on 100 × 100).
struct RobotFace: View {
    let robot: Robot

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / Robot.canvas, y: size.height / Robot.canvas)
            for shape in robot.shapes {
                switch shape {
                case let .rect(x, y, width, height, radius, fill):
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius), with: .color(Color(fill)))
                case let .ellipse(cx, cy, rx, ry, fill):
                    context.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(Color(fill)))
                case let .line(points, width, color):
                    var path = Path()
                    path.addLines(points.map { CGPoint(x: $0.x, y: $0.y) })
                    context.stroke(path, with: .color(Color(color)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                case let .arc(cx, cy, radius, from, to, width, color):
                    var path = Path()
                    // SwiftUI's y grows downward, so `clockwise: false` is clockwise on screen.
                    path.addArc(center: CGPoint(x: cx, y: cy), radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                    context.stroke(path, with: .color(Color(color)), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }
        }
    }
}

/// Decoded BlurHashes, small (32 × 32) and kept for the session: a row
/// redrawing decodes nothing twice.
@MainActor enum BlurImage {
    private static var cache: [String: Image] = [:]

    static func image(_ hash: String) -> Image? {
        if let cached = cache[hash] { return cached }
        let side = 32
        guard let pixels = BlurHash.decode(hash, width: side, height: side),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        if cache.count > 500 { cache.removeAll() }
        let image = Image(decorative: cgImage, scale: 1)
        cache[hash] = image
        return image
    }
}
