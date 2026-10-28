# Verify Scribe in the simulator

Use the repo-local `scribe-simulator` skill for native simulator interaction.
Its wrapper pins MobileBuildMCP 2.7.1, the renamed XcodeBuildMCP package, and
keeps calls in this worktree so runtime snapshot references share one workspace.
It requires Node/npm and Xcode 27.1. No desktop Computer Use connection or
global npm installation is needed.

## Choose a simulator

```bash
xcrun simctl list devices available
.agents/skills/scribe-simulator/scripts/simulator.sh simulator list
```

Use the selected device's UDID as `SIMULATOR_ID` in the commands below. Keep
build output outside the repo and use a disposable simulator for demo data.
The iOS 27.1 runtime supports iPhone Duo; ordinary iPhone and iPad verification
uses an available iOS 27.0 or iOS 26 runtime.

## Build and launch

```bash
xcodegen generate
.agents/skills/scribe-simulator/scripts/simulator.sh simulator build-and-run \
  --project-path "$PWD/Scribe.xcodeproj" \
  --scheme Scribe \
  --simulator-id "$SIMULATOR_ID" \
  --derived-data-path /tmp/scribe-simulator-build \
  --json '{"extraArgs":["CODE_SIGN_IDENTITY=-"]}'
```

Simulator builds use ad-hoc signing so CloudKit can read the app's entitlements.
Completely unsigned builds can crash in `CKContainer` before the UI appears.
This is simulator signing, not distribution signing or a Git signing override.

For an already installed build:

```bash
.agents/skills/scribe-simulator/scripts/simulator.sh simulator launch-app \
  --simulator-id "$SIMULATOR_ID" --bundle-id com.gordonbeeming.scribe
```

## Inspect and interact

### Repeatable UI checks

Run Apple's native UI-test runner for reliable interaction checks, especially
on the Duo inner display:

```bash
xcodegen generate
xcodebuild test \
  -project Scribe.xcodeproj -scheme Scribe \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/scribe-simulator-build \
  -only-testing:ScribeUITests -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=-
```

`ScribeUITests` launches the DEBUG-only `--ui-testing` fixture in an in-memory
store and a separate settings suite, with CloudKit sync and dashboard network
loading disabled. The test settings reset on each fixture launch. The tests
assert the fixture marker before interacting, so a release build fails safely.
They cover tab navigation, typing and cancelling an item form, and a payment's
effect on remaining expenses and reconciliation progress, followed by undo.
They also check that an expanded previous week remains expanded when rotation
requests change the layout. Orientation is restored in test teardown.
The payment/insight test fails if the check-in is missing on a wide display.
It selects a pending expense and tracks the same occurrence through undo;
skipped expenses cannot satisfy that selector. Run it on the open Duo or iPad
for wide-layout coverage.
Screenshots are attached to the `.xcresult` bundle.
Run UI-test invocations serially on the Mac. The screenshot-capture case is
excluded from CI and skips before app launch by default. It is enabled only
by the explicit capture helper below. CI runs each destination in a separate `xcodebuild` invocation and shuts down
unused simulators on its dedicated runner before each suite. A single invocation
with multiple runtimes can stall between destinations even when concurrency is one.
On a shared development Mac, shut down only the disposable simulator you own.

### Direct inspection and targeted actions

```bash
.agents/skills/scribe-simulator/scripts/simulator.sh ui-automation snapshot-ui \
  --simulator-id "$SIMULATOR_ID" --output json
```

Read `data.capture.targets`, `scroll`, and `text`. Only targets listing a `tap`
action are valid tap references. Capture immediately before an action: a
reference can expire while code is being edited or a build runs.

```bash
.agents/skills/scribe-simulator/scripts/simulator.sh ui-automation tap \
  --simulator-id "$SIMULATOR_ID" --element-ref "$TAP_REF"

.agents/skills/scribe-simulator/scripts/simulator.sh ui-automation swipe \
  --simulator-id "$SIMULATOR_ID" --within-element-ref "$SCROLL_REF" \
  --direction up --distance 0.5

.agents/skills/scribe-simulator/scripts/simulator.sh ui-automation type-text \
  --json '{"simulatorId":"YOUR_UDID","elementRef":"CURRENT_FIELD_REF","text":"Example","replaceExisting":true}'
```

After navigation, scrolling, sheets, or resizing, observe again before acting.
An expired-reference error calls for a fresh snapshot, not a new simulator or
a restart of the desktop app. Inspect a command's `--help` for supported flags.

On the verified Duo inner display, both a runtime `tap` and AXe's direct
label-targeted tap reported success without changing the active UI. Use the
native UI tests for those interactions. A live snapshot or screenshot proves
inspection works; it does not prove a tap reached the intended display.

## Duo displays and poses

```bash
xcrun simctl io "$SIMULATOR_ID" enumerate
xcrun simctl io "$SIMULATOR_ID" screenshot --display "$DISPLAY_ID" /tmp/scribe-display.png
```

Read the **Connected Screens** section to identify each integrated display.
In the verified Duo setup, screen 1 is the outer display and screen 3 is the
inner display; discover them again rather than assuming those IDs on another
runtime. The default screenshot selects the outer display even when the app
is on the inner display. A black inactive screen is not layout evidence.

MobileBuildMCP 2.7.1 exposes simulator UI actions but no fold/hinge command in
its CLI. Select Open, Closed, rotation, or a partial fold in Device Hub, then
use the CLI to inspect and exercise the app on the active display. Record this
as manual pose selection with direct simulator verification, not an automated
fold test. Do not substitute an iPad-sized screenshot for a Duo display.

## Verification checklist

- On the outer display, reach Dashboard, Items, and Settings through the native
  tabs, which Duo places in an icon rail when appropriate. Check a payment row,
  detail view, and form with the keyboard open.
- On the inner display, check that overview/insights and weekly payments use
  the available width without an oversized navigation menu.
- Switch displays while viewing Items or a detail, and verify the selected
  section and navigation remain in place. Repeat with an open form.
- Check portrait/landscape, a narrow split, dark mode, and accessibility text.
  Wide content should stack when it cannot remain readable in two columns.
- Confirm and undo a demo payment. Remaining expenses and reviewed counts
  should change with the same occurrence; skipped items count as reviewed.
- Save before/after screenshots of the actual active displays under
  `~/Developer/artifacts/scribe/duo/`. Attach media to a PR with `gh --attach`.

Run `ScribeTests` for logic changes. CI runs the unit suite on iPhone, iPad, and
Duo, and the native UI suite on iPad and Duo. A skipped wide-display test is not
evidence that the inner layout was exercised. Fold/pose checks still require
the actual display to be selected and observed.

## App Store screenshots

Apple accepts these native Duo dimensions:

| Display | Portrait | Landscape |
| --- | --- | --- |
| Outer | 1398×2034 | 2034×1398 |
| Inner | 2007×2853 | 2853×2007 |

Select the physical pose in Device Hub and read its integrated display ID from
`simctl io enumerate`. The following helper needs Python 3 with Pillow, Node/npm,
and XcodeGen. It drives the DEBUG fixture through Dashboard, Items, and an item
detail using native XCUITest. At each screen, the test waits while the host
captures the selected framebuffer with `simctl`, then acknowledges that capture.
The helper sets a clean 9:41 status bar and waits for navigation to settle before
capturing each frame. It clears the status-bar override when the run finishes
or fails. No desktop Computer Use service is involved.

```bash
python3 .agents/skills/scribe-simulator/scripts/capture_store_screenshots.py \
  --simulator-id "$SIMULATOR_ID" \
  --display-id 1 --display outer \
  --output "$HOME/Developer/artifacts/scribe/app-store/duo"
```

Repeat on the open inner display, using its discovered numeric display ID and
`--display inner`. Use landscape for the wide overview/payment layout. A
`--derived-data` path can reuse an existing build; otherwise it is scoped to
the current worktree under the system temporary directory.

The output contains three opaque RGB PNGs per display and a manifest listing
their exact dimensions and source captures. RGB encoding removes an unused
opaque alpha channel; pixels are neither resized nor composited. Inspect each
image before submission. The helper fails for transparent pixels, unsupported
dimensions, inactive uniform frames, or an incomplete three-screen set.

`app.screenshot()` and even a secondary `XCUIScreen` screenshot produced
2006×2852 images in the verified runtime. Those images are useful test evidence
but fail Apple's Duo dimensions. Use the full-frame helper rather than padding
or resizing them. The exporter can also validate native-sized explicit
capture attachments exported with `xcresulttool`:

```bash
python3 .agents/skills/scribe-simulator/scripts/export_store_screenshots.py \
  /tmp/exported-attachments \
  "$HOME/Developer/artifacts/scribe/app-store/duo" --display outer
```

App Store images are staged locally. Upload and submission are separate actions.

## References

- [MobileBuildMCP CLI](https://github.com/getsentry/mobilebuildmcp.com/blob/main/app/docs/_content/cli.mdx)
- [MobileBuildMCP source and releases](https://github.com/getsentry/MobileBuildMCP)
- [Apple's Duo preparation guide](https://developer.apple.com/iphone-duo/prepare/)
- [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
