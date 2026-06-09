import SwiftUI

/// Money display for the redesign — tabular `monospacedDigit` figures, refined
/// sign styling, and semantic colour. Supersedes `AmountText`; call sites migrate
/// as each screen is rebuilt.
struct MoneyText: View {
    enum Emphasis {
        case metricLarge   // hero net figure
        case metric        // card-level totals
        case money         // row amounts
        case caption       // secondary / sub figures

        var font: Font {
            switch self {
            case .metricLarge: ScribeDesign.Font.metricLarge
            case .metric: ScribeDesign.Font.metric
            case .money: ScribeDesign.Font.money
            case .caption: ScribeDesign.Font.label.monospacedDigit()
            }
        }
    }

    let amount: Decimal
    let currencyCode: String
    var type: ItemType?
    var signStyle: CurrencyFormatter.SignStyle
    var emphasis: Emphasis
    /// When false, the figure uses `primaryText` instead of the income/expense colour.
    var colored: Bool

    init(
        amount: Decimal,
        currencyCode: String,
        type: ItemType? = nil,
        signStyle: CurrencyFormatter.SignStyle? = nil,
        emphasis: Emphasis = .money,
        colored: Bool = true
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.type = type
        self.emphasis = emphasis
        self.colored = colored
        // Derive a sensible default sign style from the item type when not given.
        if let signStyle {
            self.signStyle = signStyle
        } else {
            switch type {
            case .income: self.signStyle = .alwaysPositive
            case .expense: self.signStyle = .alwaysNegative
            case nil: self.signStyle = .automatic
            }
        }
    }

    var body: some View {
        Text(CurrencyFormatter.format(amount, currencyCode: currencyCode, signStyle: signStyle))
            .font(emphasis.font)
            .foregroundStyle(colored ? color : ScribeTheme.primaryText)
    }

    private var color: Color {
        if let type {
            return ScribeTheme.amountColor(for: type)
        }
        return ScribeTheme.amountColor(isPositive: amount >= 0)
    }
}
