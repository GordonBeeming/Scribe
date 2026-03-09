import Foundation

struct DateCalculator {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal
    }()

    /// Generate all occurrence dates for a BudgetItem within the given date range (inclusive).
    /// Handles schedule overrides (dayOfMonth/referenceDate changes) that split the range.
    static func occurrenceDates(
        for item: BudgetItem,
        in range: ClosedRange<Date>
    ) -> [Date] {
        let startDay = calendar.startOfDay(for: range.lowerBound)
        let endDay = calendar.startOfDay(for: range.upperBound)

        let scheduleOverrides = item.scheduleOverrides

        if scheduleOverrides.isEmpty {
            return occurrenceDatesWithParams(
                frequency: item.frequency,
                dayOfMonth: item.dayOfMonth ?? 1,
                referenceDate: item.referenceDate ?? startDay,
                start: startDay,
                end: endDay
            )
        }

        // Split range at override boundaries
        var results: [Date] = []
        var currentStart = startDay
        var currentDayOfMonth = item.dayOfMonth ?? 1
        var currentReferenceDate = item.referenceDate ?? startDay

        // Apply overrides that took effect before the range start
        for override_ in scheduleOverrides {
            let overrideDay = calendar.startOfDay(for: override_.effectiveDate)
            if overrideDay <= currentStart {
                if let dom = override_.overrideDayOfMonth { currentDayOfMonth = dom }
                if let ref = override_.overrideReferenceDate { currentReferenceDate = ref }
            }
        }

        for override_ in scheduleOverrides {
            let overrideDay = calendar.startOfDay(for: override_.effectiveDate)
            guard overrideDay > currentStart && overrideDay <= endDay else { continue }

            // Generate dates for the sub-range before this override
            if let subEnd = calendar.date(byAdding: .day, value: -1, to: overrideDay),
               subEnd >= currentStart {
                results += occurrenceDatesWithParams(
                    frequency: item.frequency,
                    dayOfMonth: currentDayOfMonth,
                    referenceDate: currentReferenceDate,
                    start: currentStart,
                    end: subEnd
                )
            }

            // Apply this override
            if let dom = override_.overrideDayOfMonth { currentDayOfMonth = dom }
            if let ref = override_.overrideReferenceDate { currentReferenceDate = ref }
            currentStart = overrideDay
        }

        // Generate dates for the remaining range
        if currentStart <= endDay {
            results += occurrenceDatesWithParams(
                frequency: item.frequency,
                dayOfMonth: currentDayOfMonth,
                referenceDate: currentReferenceDate,
                start: currentStart,
                end: endDay
            )
        }

        return results
    }

    // MARK: - Parameter-based generation

    private static func occurrenceDatesWithParams(
        frequency: Frequency,
        dayOfMonth: Int,
        referenceDate: Date,
        start: Date,
        end: Date
    ) -> [Date] {
        switch frequency {
        case .monthly:
            return monthlyDates(dayOfMonth: dayOfMonth, start: start, end: end)
        case .weekly:
            return intervalDates(reference: referenceDate, intervalDays: 7, start: start, end: end)
        case .fortnightly:
            return intervalDates(reference: referenceDate, intervalDays: 14, start: start, end: end)
        case .quarterly:
            return quarterlyDates(reference: referenceDate, start: start, end: end)
        case .yearly:
            return yearlyDates(reference: referenceDate, start: start, end: end)
        case .biYearly:
            return biYearlyDates(reference: referenceDate, start: start, end: end)
        case .irregular:
            return irregularDates(reference: referenceDate, start: start, end: end)
        }
    }

    // MARK: - Irregular (shows once on reference date)

    private static func irregularDates(reference: Date, start: Date, end: Date) -> [Date] {
        let refDay = calendar.startOfDay(for: reference)
        if refDay >= start && refDay <= end {
            return [refDay]
        }
        return []
    }

    // MARK: - Monthly

    private static func monthlyDates(dayOfMonth: Int, start: Date, end: Date) -> [Date] {
        var results: [Date] = []
        let clampedDay = max(1, min(dayOfMonth, 31))

        var components = calendar.dateComponents([.year, .month], from: start)

        // Go back one month to catch edge cases
        if let month = components.month {
            if month == 1 {
                components.month = 12
                components.year = (components.year ?? 0) - 1
            } else {
                components.month = month - 1
            }
        }

        for _ in 0..<120 { // Up to 10 years of monthly dates
            // Compute days in month using only year/month (no day) to avoid overflow
            let monthOnlyComponents = DateComponents(year: components.year, month: components.month, day: 1)
            let daysInMonth = calendar.range(of: .day, in: .month, for: calendar.date(from: monthOnlyComponents) ?? start)?.count ?? 28
            var dateComponents = components
            dateComponents.day = min(clampedDay, daysInMonth)

            if let date = calendar.date(from: dateComponents) {
                let day = calendar.startOfDay(for: date)
                if day > end { break }
                if day >= start {
                    results.append(day)
                }
            }

            // Advance to next month
            if let month = components.month {
                if month == 12 {
                    components.month = 1
                    components.year = (components.year ?? 0) + 1
                } else {
                    components.month = month + 1
                }
            }
        }

        return results
    }

    // MARK: - Interval-based (weekly, fortnightly)

    private static func intervalDates(reference: Date, intervalDays: Int, start: Date, end: Date) -> [Date] {
        var results: [Date] = []
        let refDay = calendar.startOfDay(for: reference)
        let interval = TimeInterval(intervalDays * 86400)

        // Calculate how many intervals from reference to start
        let timeDiff = start.timeIntervalSince(refDay)
        let periodsToStart: Int
        if timeDiff >= 0 {
            periodsToStart = Int(timeDiff / interval)
        } else {
            periodsToStart = Int(timeDiff / interval) - 1
        }

        // Start generating from just before the start date
        var current = refDay.addingTimeInterval(interval * Double(periodsToStart))
        current = calendar.startOfDay(for: current)

        for _ in 0..<1000 {
            if current > end { break }
            if current >= start {
                results.append(current)
            }
            current = calendar.startOfDay(for: current.addingTimeInterval(interval))
        }

        return results
    }

    // MARK: - Quarterly

    private static func quarterlyDates(reference: Date, start: Date, end: Date) -> [Date] {
        var results: [Date] = []
        let refComponents = calendar.dateComponents([.year, .month, .day], from: reference)
        let refDayOfMonth = refComponents.day ?? 1

        var components = calendar.dateComponents([.year, .month], from: start)
        // Go back 3 months to catch edge cases
        if let month = components.month {
            let adjusted = month - 3
            if adjusted <= 0 {
                components.month = adjusted + 12
                components.year = (components.year ?? 0) - 1
            } else {
                components.month = adjusted
            }
        }

        for _ in 0..<80 { // Up to 20 years of quarterly dates
            let monthDiff = monthsDifference(from: refComponents, to: components)
            if monthDiff % 3 == 0 {
                let daysInMonth = calendar.range(of: .day, in: .month, for: calendar.date(from: components) ?? start)?.count ?? 28
                var dateComponents = components
                dateComponents.day = min(refDayOfMonth, daysInMonth)

                if let date = calendar.date(from: dateComponents) {
                    let day = calendar.startOfDay(for: date)
                    if day > end { break }
                    if day >= start {
                        results.append(day)
                    }
                }
            }

            // Advance to next month
            if let month = components.month {
                if month == 12 {
                    components.month = 1
                    components.year = (components.year ?? 0) + 1
                } else {
                    components.month = month + 1
                }
            }
        }

        return results
    }

    // MARK: - Yearly

    private static func yearlyDates(reference: Date, start: Date, end: Date) -> [Date] {
        var results: [Date] = []
        let refComponents = calendar.dateComponents([.month, .day], from: reference)

        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)

        for year in (startYear - 1)...(endYear + 1) {
            var components = refComponents
            components.year = year

            // Handle Feb 29 in non-leap years
            if let month = components.month, let day = components.day,
               month == 2 && day == 29 {
                let isLeap = calendar.range(of: .day, in: .month,
                    for: calendar.date(from: DateComponents(year: year, month: 2, day: 1))!)?.count == 29
                if !isLeap {
                    components.day = 28
                }
            }

            if let date = calendar.date(from: components) {
                let day = calendar.startOfDay(for: date)
                if day > end { break }
                if day >= start {
                    results.append(day)
                }
            }
        }

        return results
    }

    // MARK: - Bi-Yearly

    private static func biYearlyDates(reference: Date, start: Date, end: Date) -> [Date] {
        var results: [Date] = []
        let refComponents = calendar.dateComponents([.year, .month, .day], from: reference)
        let refMonth = refComponents.month ?? 1
        let refDay = refComponents.day ?? 1

        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)

        for year in (startYear - 1)...(endYear + 1) {
            // Two occurrences per year: at the reference month and 6 months later
            for monthOffset in [0, 6] {
                var month = refMonth + monthOffset
                var adjustedYear = year
                if month > 12 {
                    month -= 12
                    adjustedYear += 1
                }

                var components = DateComponents(year: adjustedYear, month: month)
                let daysInMonth = calendar.range(of: .day, in: .month,
                    for: calendar.date(from: components) ?? start)?.count ?? 28
                components.day = min(refDay, daysInMonth)

                if let date = calendar.date(from: components) {
                    let day = calendar.startOfDay(for: date)
                    if day > end { continue }
                    if day >= start {
                        results.append(day)
                    }
                }
            }
        }

        return results.sorted()
    }

    // MARK: - Helpers

    private static func monthsDifference(from refComponents: DateComponents, to targetComponents: DateComponents) -> Int {
        let refYear = refComponents.year ?? 0
        let refMonth = refComponents.month ?? 1
        let targetYear = targetComponents.year ?? 0
        let targetMonth = targetComponents.month ?? 1

        return (targetYear - refYear) * 12 + (targetMonth - refMonth)
    }
}
