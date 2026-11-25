import Foundation

/// Decodes a BlurHash (https://blurha.sh): a short string the server sends
/// with each image, standing for a tiny blurred version of it. Tiles show it
/// while the real image loads, so a row fills with color at once instead of
/// gray boxes. Written from the published algorithm (no code imported).
public enum BlurHash {
    /// RGBA pixels, `width × height × 4` bytes, or nil if the hash is malformed.
    public static func decode(_ hash: String, width: Int, height: Int) -> [UInt8]? {
        let chars = Array(hash.utf8)
        guard chars.count >= 6, width > 0, height > 0, let sizeFlag = base83(chars[0..<1]) else { return nil }
        let componentsX = sizeFlag % 9 + 1
        let componentsY = sizeFlag / 9 + 1
        guard chars.count == 4 + 2 * componentsX * componentsY,
              let quantizedMax = base83(chars[1..<2]), let dc = base83(chars[2..<6]) else { return nil }
        let maxValue = Double(quantizedMax + 1) / 166

        var colors: [(Double, Double, Double)] = [(
            linear(dc >> 16 & 255), linear(dc >> 8 & 255), linear(dc & 255)
        )]
        for index in 1..<(componentsX * componentsY) {
            let start = 4 + index * 2
            guard let value = base83(chars[start..<start + 2]) else { return nil }
            colors.append((
                signedPow(Double(value / (19 * 19)) - 9, maxValue),
                signedPow(Double(value / 19 % 19) - 9, maxValue),
                signedPow(Double(value % 19) - 9, maxValue)
            ))
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        // The cosine factors per column and per row, computed once.
        let cosX = (0..<componentsX).map { i in (0..<width).map { x in cos(Double.pi * Double(x * i) / Double(width)) } }
        let cosY = (0..<componentsY).map { j in (0..<height).map { y in cos(Double.pi * Double(y * j) / Double(height)) } }
        for y in 0..<height {
            for x in 0..<width {
                var (r, g, b) = (0.0, 0.0, 0.0)
                for j in 0..<componentsY {
                    for i in 0..<componentsX {
                        let basis = cosX[i][x] * cosY[j][y]
                        let color = colors[i + j * componentsX]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let offset = (y * width + x) * 4
                pixels[offset] = sRGB(r)
                pixels[offset + 1] = sRGB(g)
                pixels[offset + 2] = sRGB(b)
            }
        }
        return pixels
    }

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".utf8)
    private static let digits: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    static func base83(_ chars: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for char in chars {
            guard let digit = digits[char] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    static func linear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func sRGB(_ value: Double) -> UInt8 {
        let v = max(0, min(1, value))
        let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8((encoded * 255 + 0.5).rounded(.down))
    }

    private static func signedPow(_ quantized: Double, _ maxValue: Double) -> Double {
        let value = quantized / 9
        return (value < 0 ? -1 : 1) * value * value * maxValue
    }
}

extension Item {
    /// The BlurHash of the image `ref` points at, when the server sent one.
    public func blurHash(for ref: ImageRef) -> String? {
        imageBlurHashes?[ref.kind.rawValue]?[ref.tag]
    }
}
