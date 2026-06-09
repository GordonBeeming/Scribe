import AppIntents

/// App Intents-facing mirror of `ItemType`. The model enum stays free of the
/// AppIntents dependency; this maps to it.
enum BudgetItemTypeAppEnum: String, AppEnum {
    case income
    case expense

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Item Type")
    }

    static var caseDisplayRepresentations: [BudgetItemTypeAppEnum: DisplayRepresentation] {
        [.income: "Income", .expense: "Expense"]
    }

    var model: ItemType {
        self == .income ? .income : .expense
    }
}

/// App Intents-facing mirror of `Frequency`. Raw values match the model enum so
/// it maps straight through.
enum BudgetFrequencyAppEnum: String, AppEnum {
    case weekly
    case fortnightly
    case monthly
    case quarterly
    case yearly
    case biYearly
    case irregular

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Frequency")
    }

    static var caseDisplayRepresentations: [BudgetFrequencyAppEnum: DisplayRepresentation] {
        [
            .weekly: "Weekly",
            .fortnightly: "Fortnightly",
            .monthly: "Monthly",
            .quarterly: "Quarterly",
            .yearly: "Yearly",
            .biYearly: "Bi-Yearly",
            .irregular: "Irregular",
        ]
    }

    var model: Frequency {
        Frequency(rawValue: rawValue) ?? .monthly
    }
}
