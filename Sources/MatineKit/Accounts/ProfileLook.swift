import Foundation

/// Who a profile is for. A kid profile gets a home screen without the
/// grown-up controls; switching a profile between the two needs an adult's PIN.
public enum ProfileRole: String, Codable, Sendable, Hashable, CaseIterable {
    case adult, kid
}

/// An sRGB color, 0–255 per channel: one list for the app, the CLI's SVG and the tests.
public struct RGB: Codable, Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }
    public init(hex: UInt32) { self.init(UInt8(hex >> 16 & 0xFF), UInt8(hex >> 8 & 0xFF), UInt8(hex & 0xFF)) }
    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// The profile colors: saturated enough to tell apart across a room, dark
/// enough that white text and a light robot read on top of each.
public enum ProfileColor: String, Codable, Sendable, Hashable, CaseIterable {
    case tangerine, cherry, berry, grape, ocean, teal, forest, cocoa

    public var rgb: RGB {
        switch self {
        case .tangerine: RGB(hex: 0xE8682C)
        case .cherry: RGB(hex: 0xD63A4A)
        case .berry: RGB(hex: 0xC2337F)
        case .grape: RGB(hex: 0x7A4FD0)
        case .ocean: RGB(hex: 0x2F6FD8)
        case .teal: RGB(hex: 0x14968C)
        case .forest: RGB(hex: 0x3D9140)
        case .cocoa: RGB(hex: 0x8A5A3C)
        }
    }
}

/// The animals a profile can wear, by SF Symbol name (all in tvOS 27).
public enum ProfileAnimal: String, Codable, Sendable, Hashable, CaseIterable {
    case cat = "cat.fill"
    case dog = "dog.fill"
    case hare = "hare.fill"
    case tortoise = "tortoise.fill"
    case bird = "bird.fill"
    case fish = "fish.fill"
    case lizard = "lizard.fill"
    case ladybug = "ladybug.fill"
    case teddy = "teddybear.fill"
}

/// What sits in a profile's circle: a generated robot (by seed) or an animal,
/// on the profile's color.
public struct Avatar: Codable, Sendable, Hashable {
    public enum Figure: Codable, Sendable, Hashable {
        case robot(seed: UInt64)
        case animal(ProfileAnimal)
    }

    public var figure: Figure
    public var color: ProfileColor

    public init(figure: Figure, color: ProfileColor) {
        self.figure = figure
        self.color = color
    }

    /// Every profile starts with its own robot: picked from its user id, so
    /// the same profile gets the same robot on every device and in the CLI.
    public static func initial(for userId: String) -> Avatar {
        let hash = StableHash.fnv1a(userId)
        let colors = ProfileColor.allCases
        return Avatar(figure: .robot(seed: hash), color: colors[Int(hash % UInt64(colors.count))])
    }
}

/// FNV-1a: a hash that, unlike `Hasher`, is the same in every process.
enum StableHash {
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

extension Account {
    /// The name the picker shows: the one a grown-up gave the profile, else
    /// the server's user name.
    public var shownName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name : trimmed
    }

    public var isKid: Bool { role == .kid }
}

extension Profiles {
    /// A display name as saved: trimmed, composed, at most 20 characters; nil
    /// when empty (the server name shows instead).
    public static func cleanDisplayName(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return trimmed.isEmpty ? nil : String(trimmed.prefix(20))
    }
}
