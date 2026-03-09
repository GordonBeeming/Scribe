import Foundation
import SwiftData
import CloudKit

@MainActor
enum DemoDataGenerator {
    static func generate(in context: ModelContext) {
        let calendar = Calendar.current
        let now = Date()

        // MARK: - Family Members

        let alex = FamilyMember(name: "Alex", sortOrder: 0)
        let sam = FamilyMember(name: "Sam", sortOrder: 1)
        context.insert(alex)
        context.insert(sam)

        // Helper to create a reference date for interval-based frequencies
        func refDate(weekday: Int = 2) -> Date {
            // A recent Monday as reference
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            components.weekday = weekday
            return calendar.date(from: components) ?? now
        }

        // MARK: - Income

        let alexSalary = BudgetItem(
            name: "Alex's Salary", type: .income, amount: 5200,
            frequency: .monthly, dayOfMonth: 14,
            category: .income, sortOrder: 0
        )
        alexSalary.familyMembers = [alex]

        let samSalary = BudgetItem(
            name: "Sam's Salary", type: .income, amount: 4800,
            frequency: .monthly, dayOfMonth: 28,
            category: .income, sortOrder: 1
        )
        samSalary.familyMembers = [sam]

        // MARK: - Expenses

        let rent = BudgetItem(
            name: "Rent", type: .expense, amount: 2400,
            frequency: .monthly, dayOfMonth: 1,
            category: .housing, sortOrder: 2
        )
        rent.familyMembers = [alex, sam]

        let electricity = BudgetItem(
            name: "Electricity", type: .expense, amount: 380,
            frequency: .quarterly, referenceDate: calendar.date(byAdding: .month, value: -1, to: now),
            category: .utilities, sortOrder: 3
        )

        let internet = BudgetItem(
            name: "Internet", type: .expense, amount: 89,
            frequency: .monthly, dayOfMonth: 5,
            category: .utilities, sortOrder: 4
        )

        let water = BudgetItem(
            name: "Water", type: .expense, amount: 280,
            frequency: .quarterly, referenceDate: calendar.date(byAdding: .month, value: -2, to: now),
            category: .utilities, sortOrder: 5
        )

        let healthInsurance = BudgetItem(
            name: "Health Insurance", type: .expense, amount: 320,
            frequency: .monthly, dayOfMonth: 20,
            category: .health, sortOrder: 6
        )
        healthInsurance.familyMembers = [alex, sam]

        let gym = BudgetItem(
            name: "Gym Membership", type: .expense, amount: 65,
            frequency: .fortnightly, referenceDate: refDate(),
            category: .health, sortOrder: 7
        )
        gym.familyMembers = [alex]

        let carInsurance = BudgetItem(
            name: "Car Insurance", type: .expense, amount: 1400,
            frequency: .yearly, referenceDate: calendar.date(byAdding: .month, value: -4, to: now),
            category: .insurance, sortOrder: 8
        )

        let homeInsurance = BudgetItem(
            name: "Home & Contents Insurance", type: .expense, amount: 180,
            frequency: .monthly, dayOfMonth: 10,
            category: .insurance, sortOrder: 9
        )

        let fuel = BudgetItem(
            name: "Fuel", type: .expense, amount: 80,
            frequency: .fortnightly, referenceDate: refDate(weekday: 6),
            category: .transport, sortOrder: 10
        )
        fuel.familyMembers = [alex]

        let carRego = BudgetItem(
            name: "Car Registration", type: .expense, amount: 750,
            frequency: .yearly, referenceDate: calendar.date(byAdding: .month, value: -7, to: now),
            category: .transport, sortOrder: 11
        )

        let schoolFees = BudgetItem(
            name: "School Fees", type: .expense, amount: 1200,
            frequency: .quarterly, referenceDate: calendar.date(byAdding: .month, value: 1, to: now),
            category: .kids, sortOrder: 12
        )

        let afterSchoolCare = BudgetItem(
            name: "After School Care", type: .expense, amount: 95,
            frequency: .weekly, referenceDate: refDate(weekday: 6),
            category: .kids, sortOrder: 13
        )

        let netflix = BudgetItem(
            name: "Netflix", type: .expense, amount: Decimal(string: "22.99") ?? 23,
            frequency: .monthly, dayOfMonth: 15,
            category: .subscriptions, sortOrder: 14
        )

        let spotify = BudgetItem(
            name: "Spotify", type: .expense, amount: Decimal(string: "12.99") ?? 13,
            frequency: .monthly, dayOfMonth: 8,
            category: .subscriptions, sortOrder: 15
        )

        let icloud = BudgetItem(
            name: "iCloud+", type: .expense, amount: Decimal(string: "4.49") ?? 4.49,
            frequency: .monthly, dayOfMonth: 22,
            category: .subscriptions, sortOrder: 16
        )

        let groceries = BudgetItem(
            name: "Groceries", type: .expense, amount: 250,
            frequency: .weekly, referenceDate: refDate(weekday: 7),
            category: .other, sortOrder: 17
        )
        groceries.familyMembers = [alex, sam]

        let charity = BudgetItem(
            name: "Charity Donation", type: .expense, amount: 200,
            frequency: .monthly, dayOfMonth: 25,
            category: .donations, sortOrder: 18
        )

        let savings = BudgetItem(
            name: "Savings Transfer", type: .expense, amount: 500,
            frequency: .monthly, dayOfMonth: 15,
            category: .savings, sortOrder: 19
        )

        let allItems = [
            alexSalary, samSalary, rent, electricity, internet, water,
            healthInsurance, gym, carInsurance, homeInsurance, fuel, carRego,
            schoolFees, afterSchoolCare, netflix, spotify, icloud, groceries,
            charity, savings
        ]

        for item in allItems {
            context.insert(item)
        }

        // MARK: - Amount Overrides

        let rentOverride = AmountOverride(
            effectiveDate: calendar.date(byAdding: .month, value: -6, to: now) ?? now,
            amount: 2200,
            notes: "Previous rent amount",
            budgetItem: rent
        )
        // The current rent (2400) is the item's base amount; the override records the old amount
        // Actually, overrides record the NEW amount at an effective date. So rent was originally something
        // and became 2400 six months ago. Let's make the override represent the increase:
        // Override at -6 months sets amount to 2400, base amount should be 2200.
        // But the item's `amount` is 2400 currently. The way effectiveAmount works:
        // it finds the latest override before the date. If no override, uses base `amount`.
        // So to show rent increased from 2200 to 2400 six months ago:
        // base amount = 2200, override at -6mo = 2400? No, that means it's been 2400 since then.
        // Actually let's just set base = 2400 (current) and create an override showing the old value
        // doesn't make sense with the model. The model: base amount is the ORIGINAL, overrides change it.
        // So: base = 2200, override at -6mo with amount 2400 means current effective = 2400.
        rentOverride.amount = 2400
        context.insert(rentOverride)
        rent.amount = 2200

        let elecOverride = AmountOverride(
            effectiveDate: calendar.date(byAdding: .month, value: -3, to: now) ?? now,
            amount: 380,
            notes: "Rate increase",
            budgetItem: electricity
        )
        context.insert(elecOverride)
        electricity.amount = 340

        // MARK: - Occurrences

        // Past confirmed occurrences
        let rentOcc1 = Occurrence(
            dueDate: calendar.date(byAdding: .month, value: -1, to: calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: calendar.component(.month, from: now), day: 1))!) ?? now,
            expectedAmount: 2400,
            actualAmount: 2400,
            status: .confirmed,
            confirmedAt: calendar.date(byAdding: .month, value: -1, to: now),
            budgetItem: rent
        )
        context.insert(rentOcc1)

        let salaryOcc = Occurrence(
            dueDate: calendar.date(from: DateComponents(
                year: calendar.component(.year, from: now),
                month: calendar.component(.month, from: now) - 1,
                day: 14
            )) ?? now,
            expectedAmount: 5200,
            actualAmount: 5200,
            status: .confirmed,
            confirmedAt: calendar.date(byAdding: .month, value: -1, to: now),
            budgetItem: alexSalary
        )
        context.insert(salaryOcc)

        let netflixOcc = Occurrence(
            dueDate: calendar.date(from: DateComponents(
                year: calendar.component(.year, from: now),
                month: calendar.component(.month, from: now) - 1,
                day: 15
            )) ?? now,
            expectedAmount: Decimal(string: "22.99") ?? 23,
            actualAmount: Decimal(string: "22.99") ?? 23,
            status: .confirmed,
            confirmedAt: calendar.date(byAdding: .day, value: -20, to: now),
            budgetItem: netflix
        )
        context.insert(netflixOcc)

        // Upcoming pending occurrences
        let rentOccUpcoming = Occurrence(
            dueDate: calendar.date(from: DateComponents(
                year: calendar.component(.year, from: now),
                month: calendar.component(.month, from: now),
                day: 1
            )) ?? now,
            expectedAmount: 2400,
            status: .pending,
            budgetItem: rent
        )
        context.insert(rentOccUpcoming)

        let savingsOcc = Occurrence(
            dueDate: calendar.date(from: DateComponents(
                year: calendar.component(.year, from: now),
                month: calendar.component(.month, from: now),
                day: 15
            )) ?? now,
            expectedAmount: 500,
            status: .pending,
            budgetItem: savings
        )
        context.insert(savingsOcc)

        let groceriesOcc = Occurrence(
            dueDate: calendar.date(byAdding: .day, value: 2, to: now) ?? now,
            expectedAmount: 250,
            status: .pending,
            budgetItem: groceries
        )
        context.insert(groceriesOcc)

        // One skipped occurrence
        let gymSkipped = Occurrence(
            dueDate: calendar.date(byAdding: .day, value: -5, to: now) ?? now,
            expectedAmount: 65,
            status: .skipped,
            notes: "On holiday",
            budgetItem: gym
        )
        context.insert(gymSkipped)

        // One overdue
        let healthOcc = Occurrence(
            dueDate: calendar.date(from: DateComponents(
                year: calendar.component(.year, from: now),
                month: calendar.component(.month, from: now),
                day: max(1, calendar.component(.day, from: now) - 3)
            )) ?? now,
            expectedAmount: 320,
            status: .overdue,
            budgetItem: healthInsurance
        )
        context.insert(healthOcc)

        try? context.save()

        // MARK: - Push to CloudKit

        let zoneID = CloudKitManager.shared.zoneID
        var recordIDs: [CKRecord.ID] = []

        recordIDs.append(contentsOf: [alex, sam].map {
            CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
        })
        recordIDs.append(contentsOf: allItems.map {
            CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
        })
        recordIDs.append(contentsOf: [rentOverride, elecOverride].map {
            CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
        })
        recordIDs.append(contentsOf: [rentOcc1, salaryOcc, netflixOcc, rentOccUpcoming, savingsOcc, groceriesOcc, gymSkipped, healthOcc].map {
            CKRecord.ID(recordName: $0.id.uuidString, zoneID: zoneID)
        })

        SyncCoordinator.shared.pushChanges(for: recordIDs)
    }
}
