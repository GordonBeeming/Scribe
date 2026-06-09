import AppIntents
import SwiftData
import Foundation

/// A budget item exposed to the system (Siri, Shortcuts, Spotlight). Intentionally
/// narrower than the SwiftData `BudgetItem` model — just what the system needs to
/// display and route. Backed by the shared model container.
struct BudgetItemEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Budget Item")
    }

    static let defaultQuery = BudgetItemQuery()

    let id: UUID
    let name: String
    let amount: Double
    let typeName: String
    let currencyCode: String

    init(id: UUID, name: String, amount: Double, typeName: String, currencyCode: String) {
        self.id = id
        self.name = name
        self.amount = amount
        self.typeName = typeName
        self.currencyCode = currencyCode
    }

    init(_ item: BudgetItem) {
        self.init(
            id: item.id,
            name: item.name,
            amount: NSDecimalNumber(decimal: item.amount).doubleValue,
            typeName: item.type.displayName,
            currencyCode: item.currencyCode
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(typeName) · \(CurrencyFormatter.format(Decimal(amount), currencyCode: currencyCode))"
        )
    }
}

/// Resolves budget items for intent parameters and Spotlight, by id or name.
struct BudgetItemQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [BudgetItemEntity] {
        let context = SharedModelContainer.shared.mainContext
        let items = try context.fetch(FetchDescriptor<BudgetItem>())
        let wanted = Set(identifiers)
        return items.filter { wanted.contains($0.id) }.map(BudgetItemEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [BudgetItemEntity] {
        let query = string.lowercased()
        let context = SharedModelContainer.shared.mainContext
        let items = try context.fetch(FetchDescriptor<BudgetItem>())
        return items
            .filter { $0.name.lowercased().contains(query) }
            .map(BudgetItemEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [BudgetItemEntity] {
        let context = SharedModelContainer.shared.mainContext
        let items = try context.fetch(
            FetchDescriptor<BudgetItem>(
                predicate: #Predicate { $0.isActive },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
        )
        return items.map(BudgetItemEntity.init)
    }
}
