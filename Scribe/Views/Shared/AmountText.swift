import SwiftUI

struct AmountText: View {
    let amount: Decimal
    let currencyCode: String
    let type: ItemType?
    let showSign: Bool

    init(amount: Decimal, currencyCode: String, type: ItemType? = nil, showSign: Bool = true) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.type = type
        self.showSign = showSign
    }

    var body: some View {
        Text(formattedAmount)
            .foregroundStyle(amountColor)
    }

    private var formattedAmount: String {
        if showSign {
            let signStyle: CurrencyFormatter.SignStyle = switch type {
            case .income: .alwaysPositive
            case .expense: .alwaysNegative
            case nil: .automatic
            }
            return CurrencyFormatter.format(amount, currencyCode: currencyCode, signStyle: signStyle)
        } else {
            return CurrencyFormatter.format(amount, currencyCode: currencyCode)
        }
    }

    private var amountColor: Color {
        if let type {
            return ScribeTheme.amountColor(for: type)
        }
        return ScribeTheme.amountColor(isPositive: amount >= 0)
    }
}
