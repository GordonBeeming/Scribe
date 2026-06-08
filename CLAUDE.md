# Scribe

Family budget app for iOS/iPadOS + watchOS. SwiftUI, SwiftData, CKSyncEngine for sync. XcodeGen generates `Scribe.xcodeproj` (gitignored) from `project.yml` — run `xcodegen generate` after adding/removing files.

## Testing UI changes

Test every UI change in the simulator before calling it done. A green build and passing unit tests aren't enough on their own. Build, launch, and screenshot the affected screen to confirm it actually renders and behaves as intended. Skip only when I explicitly say not to, or the change has no visual/interactive surface (pure model/sync/test-only edits).

Default flow (XcodeBuildMCP, simulator `iPhone 17 Pro`):

1. `xcodebuild build -project Scribe.xcodeproj -scheme Scribe -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData`
2. `boot_sim` → `build_run_sim` (or `launch_app_sim`)
3. `screenshot` and read it back — verify the change, check for clipping/overflow/layout breaks
4. For state behind a setting, flip the app-group pref and relaunch: `xcrun simctl spawn <udid> defaults write group.com.gordonbeeming.scribe <key> -bool YES` (tap automation is not enabled in this MCP config)

Run `ScribeTests` (`xcodebuild test …`) for any logic change.
