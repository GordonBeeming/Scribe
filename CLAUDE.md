# Scribe

Family budget app for iPhone, iPad, and Apple Watch. SwiftUI + SwiftData, with CKSyncEngine for iCloud sync across family members. Budget items are recurring income/expenses; occurrences are the individual dated instances you confirm or skip.

## Targets — all the moving parts

XcodeGen generates `Scribe.xcodeproj` (gitignored) from `project.yml`. Run `xcodegen generate` after adding or removing files. There are four targets, and they share code by pulling the same source folders into each target:

| Target | Platform | Bundle id | What it is |
| --- | --- | --- | --- |
| `Scribe` | iOS/iPadOS | `com.gordonbeeming.scribe` | The main app (iPhone + iPad). |
| `ScribeWidget` | iOS | `com.gordonbeeming.scribe.widget` | Home-screen / lock-screen widgets. |
| `ScribeWatch` | watchOS | `com.gordonbeeming.scribe.watch` | The Watch app. |
| `ScribeWatchWidget` | watchOS | `com.gordonbeeming.scribe.watch.widget` | Watch complications. |

**Shared code:** `Scribe/Models`, `Scribe/Utilities`, `Scribe/Services`, `Scribe/CloudKit`, and `Scribe/ViewModels` are compiled into the watch and widget targets too (see the `sources:` lists in `project.yml`). **`Scribe/Views` is iOS-only** — the watch and widgets do NOT see it, so they can't use `ScribeTheme`, `MoneyText`, or anything in `Scribe/Views/DesignSystem`. That's why the watch has its own `ScribeWatch/WatchTheme.swift` and the watch widget defines its colours inline.

All targets read the same SwiftData store from the app group `group.com.gordonbeeming.scribe` (see `SharedModelContainer`).

## A UI/design change touches more than one surface

This is the easy thing to miss. When you change anything visual — palette, money colours, card style, a screen layout — check whether it should also land on:

- **iPhone** (compact) and **iPad** (regular size class — `ContentView` uses `.tabViewStyle(.sidebarAdaptable)` and the dashboard uses an adaptive grid).
- **Apple Watch** — `ScribeWatch/BudgetSummaryView.swift`, styled via `ScribeWatch/WatchTheme.swift`. Keep `WatchTheme` in sync with `ScribeTheme` / the asset-catalog colours by hand, since the watch can't import the iOS design system.
- **Both widgets** — `ScribeWidget/` (iOS) and `ScribeWatchWidget/`.

The 1.3 redesign shipped before the watch and widgets were brought along; don't repeat that.

## Design system

Lives in `Scribe/Views/DesignSystem/` — `ScribeBackground` (the brand-tinted gradient that makes Liquid Glass actually read), `ScribeCard` (`.scribeCard()` / `.scribeHeroCard()` / `.scribeSection()`), `ScribeDesign` (spacing, radii, type tokens), and `MoneyText`. Colours come from the asset catalog via `Scribe/Views/Shared/ScribeTheme.swift`. Glass (`.glassEffect`) belongs on large card surfaces, not small chips. Minimum deployment is iOS 26, so the glass APIs are available unconditionally.

## App Intents

`Scribe/AppIntents/` exposes Add Item, Mark Paid, Budget Summary, and Upcoming Expenses to Siri / Shortcuts / Spotlight via `ScribeShortcuts`. Intents reuse `OccurrenceMatching`, `DashboardViewModel`, and `CurrencyFormatter` against `SharedModelContainer.shared` — don't duplicate business logic there.

## CloudKit sync

`Scribe/CloudKit/SyncCoordinator.swift` runs two `CKSyncEngine`s (private zone + shared zone) with state tokens in app-group `UserDefaults`. Conflicts resolve by `modifiedAt` and merge the server's fields (don't reintroduce the old "only cache the change tag" behaviour). Settings has an "Unstuck Sync" action (`forceFullResync()`) that drops the state tokens and re-queues local records while preserving `ckRecordData` (it carries zone identity — clearing it duplicates shared records into the private zone).

## Testing UI changes

Test every UI change in the simulator before calling it done. A green build and passing unit tests aren't enough on their own. Build, launch, and screenshot the affected screen to confirm it renders and behaves. Skip only when I say so, or the change has no visual surface (pure model/sync/test-only edits).

XcodeBuildMCP drives the simulators, and **tap/snapshot UI automation works** (`snapshot_ui`, `tap`, `gesture`, `set_sim_appearance`). One gotcha: if several simulators share a name (e.g. "Apple Watch Series 11 (46mm)" across watchOS versions), the MCP can target the wrong one. Rename the one you want (`xcrun simctl rename <udid> <unique-name>`) so it resolves cleanly, then rename it back. The iPad `sidebarAdaptable` sidebar rows aren't exposed to automation, so switching tabs in landscape needs a manual tap.

Per-surface flow:

- **iPhone / iPad:** `iPhone 17 Pro` (or `iPad Pro 13-inch (M5)`). `build_run_sim` → `screenshot` → read it back. Check light and dark (`set_sim_appearance`). For state behind a setting, flip the app-group pref and relaunch: `xcrun simctl spawn <udid> defaults write group.com.gordonbeeming.scribe <key> -bool YES`.
- **Watch:** build the `ScribeWatch` scheme for a watchOS 26 sim (`xcodebuild build -scheme ScribeWatch -destination 'platform=watchOS Simulator,id=<udid>'`), install + launch via `simctl`, and tap the DEBUG **Load Demo Data** button to populate the empty store.

Demo data: `DemoDataGenerator.generate(in:)`, reachable from Settings → Data Management on iOS and the Load Demo Data button on the watch.

Run `ScribeTests` (`xcodebuild test …`) for any logic change.

## App Store screenshot sizes

Captured with `xcrun simctl io <udid> screenshot` (native resolution, not the downscaled MCP preview), with a clean status bar via `xcrun simctl status_bar <udid> override --time "9:41" …`:

- **iPhone 6.5"/6.7":** 1284×2778 — iPhone 13 Pro Max profile (App Store Connect rejected 6.9" / 1320×2868 for this listing).
- **iPad 13" landscape:** 2752×2064 — iPad Pro 13-inch (M5).
- **Watch:** 416×496 — Apple Watch Series 11 (46mm).
