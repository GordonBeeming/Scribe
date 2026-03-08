import Foundation
import SwiftData
import SwiftUI

@Observable
final class BudgetItemListViewModel {
    var searchText: String = ""
    var filterType: ItemType? = nil

    func filteredItems(_ items: [BudgetItem]) -> [ItemCategory: [BudgetItem]] {
        let filtered = items.filter { item in
            let matchesSearch = searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
            let matchesType = filterType == nil || item.type == filterType
            return matchesSearch && matchesType
        }

        var grouped: [ItemCategory: [BudgetItem]] = [:]
        for item in filtered {
            grouped[item.category, default: []].append(item)
        }

        // Sort items within each category by sortOrder
        for (key, value) in grouped {
            grouped[key] = value.sorted { $0.sortOrder < $1.sortOrder }
        }

        return grouped
    }

    var sortedCategories: [ItemCategory] {
        ItemCategory.allCases
    }
}
