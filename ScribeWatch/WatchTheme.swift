import SwiftUI

/// Watch-local mirror of the iOS design tokens. The watch target can't see
/// `Scribe/Views` (so no `ScribeTheme`/`MoneyText`), and watchOS has no Liquid
/// Glass — so this keeps the same brand palette and money semantics with the
/// brighter dark-mode values, which read well on the always-dark OLED screen.
///
/// Keep in sync with `ScribeTheme` / the asset-catalog colours on the iOS side.
enum WatchTheme {
    /// Income / positive — emerald (matches Success dark value).
    static let income = Color(red: 0.263, green: 0.820, blue: 0.498)
    /// Expense / negative — soft rose (matches Error dark value).
    static let expense = Color(red: 0.949, green: 0.420, blue: 0.369)
    /// Brand accent / primary on dark — periwinkle.
    static let accent = Color(red: 0.690, green: 0.722, blue: 1.000)
    /// Secondary text.
    static let secondary = Color(white: 0.64)
    /// Subtle card fill on the black background.
    static let surface = Color.white.opacity(0.08)

    static func amountColor(for type: ItemType) -> Color {
        type == .income ? income : expense
    }

    static func amountColor(isPositive: Bool) -> Color {
        isPositive ? income : expense
    }

    /// Income reads green; expenses take the brand periwinkle so the avatars
    /// aren't all red. Mirrors the iOS row treatment.
    static func categoryTint(for type: ItemType) -> Color {
        type == .income ? income : accent
    }
}

/// Tabular money text for the watch — monospaced digits, refined sign + colour.
struct WatchMoney: View {
    let amount: Decimal
    let currencyCode: String
    var type: ItemType?
    var sign: CurrencyFormatter.SignStyle
    var font: Font
    var colored: Bool

    init(
        _ amount: Decimal,
        currencyCode: String,
        type: ItemType? = nil,
        sign: CurrencyFormatter.SignStyle = .none,
        font: Font = .caption2.monospacedDigit(),
        colored: Bool = true
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.type = type
        self.sign = sign
        self.font = font
        self.colored = colored
    }

    var body: some View {
        Text(CurrencyFormatter.format(amount, currencyCode: currencyCode, signStyle: sign))
            .font(font)
            .foregroundStyle(colored ? color : .primary)
    }

    private var color: Color {
        if let type { return WatchTheme.amountColor(for: type) }
        return WatchTheme.amountColor(isPositive: amount >= 0)
    }
}

/// Small category avatar — tinted circle + SF Symbol, matching the iOS rows.
struct WatchAvatar: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}
