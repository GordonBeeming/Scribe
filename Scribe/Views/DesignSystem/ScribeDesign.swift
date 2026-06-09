import SwiftUI

/// Central design tokens for the Liquid Glass redesign.
///
/// Glass surfaces only read when they have something to refract and when nested
/// shapes stay concentric. These tokens keep spacing and corner radii consistent
/// so a card's inner rows nest cleanly inside its outer glass shape.
enum ScribeDesign {
    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: - Corner radii
    /// Concentric scale: an outer card uses `card`/`hero`; rows nested inside use
    /// `row` so the inner corners visually sit inside the outer ones.
    enum Radius {
        static let row: CGFloat = 14
        static let card: CGFloat = 22
        static let hero: CGFloat = 26
        static let chip: CGFloat = 999 // capsule
    }

    // MARK: - Typography roles
    enum Font {
        static let screenTitle = SwiftUI.Font.largeTitle.bold()
        static let sectionHeader = SwiftUI.Font.title3.weight(.semibold)
        static let cardTitle = SwiftUI.Font.headline
        static let metric = SwiftUI.Font.title2.weight(.bold).monospacedDigit()
        static let metricLarge = SwiftUI.Font.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit()
        static let money = SwiftUI.Font.body.weight(.semibold).monospacedDigit()
        static let label = SwiftUI.Font.caption.weight(.medium)
    }
}
