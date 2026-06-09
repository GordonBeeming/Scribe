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

    /// How the +/- prefix is shown. `.auto` derives it from the item type
    /// (income → +, expense → −, untyped → automatic by value).
    enum SignMode {
        case auto
        case signed     // always show +/- based on value
        case unsigned   // no sign prefix
    }

    let amount: Decimal
    let currencyCode: String
    var type: ItemType?
    var sign: SignMode
    var emphasis: Emphasis
    /// When false, the figure uses `primaryText` instead of the income/expense colour.
    var colored: Bool

    init(
        amount: Decimal,
        currencyCode: String,
        type: ItemType? = nil,
        sign: SignMode = .auto,
        emphasis: Emphasis = .money,
        colored: Bool = true
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.type = type
        self.sign = sign
        self.emphasis = emphasis
        self.colored = colored
    }

    var body: some View {
        Text(CurrencyFormatter.format(amount, currencyCode: currencyCode, signStyle: signStyle))
            .font(emphasis.font)
            .foregroundStyle(colored ? color : ScribeTheme.primaryText)
    }

    private var signStyle: CurrencyFormatter.SignStyle {
        switch sign {
        case .signed: return .automatic
        case .unsigned: return .none
        case .auto:
            switch type {
            case .income: return .alwaysPositive
            case .expense: return .alwaysNegative
            case nil: return .automatic
            }
        }
    }

    private var color: Color {
        if let type {
            return ScribeTheme.amountColor(for: type)
        }
        return ScribeTheme.amountColor(isPositive: amount >= 0)
    }
}
