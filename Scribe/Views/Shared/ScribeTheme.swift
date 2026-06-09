import SwiftUI

enum ScribeTheme {
    // MARK: - Background
    static let background = Color("Background")
    static let gradientTop = Color("BackgroundGradientTop")
    static let gradientBottom = Color("BackgroundGradientBottom")

    // MARK: - Surfaces
    /// Opaque fill for rows nested inside a glass container, where a second glass
    /// layer would muddy the refraction. Use sparingly — most content sits directly on glass.
    static let surface = Color("Surface")
    static let surfaceElevated = Color("SurfaceElevated")

    // MARK: - Text
    static let primaryText = Color("PrimaryText")
    static let secondaryText = Color("SecondaryText")

    // MARK: - Brand
    static let primary = Color("ScribePrimary")
    static let textOnPrimary = Color("TextOnPrimary")
    static let accent = Color("ScribeAccent")
    /// Secondary brand accent (teal) — complements the periwinkle accent for
    /// iconography and the background colour wash so glass has hue to refract.
    static let secondary = Color("ScribeSecondary")

    // MARK: - Semantic
    static let success = Color("Success")
    static let error = Color("Error")

    // MARK: - Convenience

    static func amountColor(for type: ItemType) -> Color {
        type == .income ? success : error
    }

    static func amountColor(isPositive: Bool) -> Color {
        isPositive ? success : error
    }
}
