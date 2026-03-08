import SwiftUI

enum ScribeTheme {
    // MARK: - Background
    static let background = Color("Background")

    // MARK: - Text
    static let primaryText = Color("PrimaryText")
    static let secondaryText = Color("SecondaryText")

    // MARK: - Brand
    static let primary = Color("ScribePrimary")
    static let textOnPrimary = Color("TextOnPrimary")
    static let accent = Color("ScribeAccent")

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
