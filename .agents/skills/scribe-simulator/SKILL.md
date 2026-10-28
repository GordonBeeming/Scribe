---
name: scribe-simulator
description: Verify Scribe on iPhone, iPad, and iPhone Duo using native XCUITest and the direct MobileBuildMCP CLI. Use for simulator navigation, forms, payment checks, display/layout verification, and before/after screenshots without desktop Computer Use.
---

# Scribe simulator verification

Use native `ScribeUITests` for interaction checks and `scripts/simulator.sh` for
the pinned MobileBuildMCP CLI. Both work without an MCP connection or the
desktop Computer Use service.
Use native UI tests and framebuffer commands for headless verification. Follow
GUI authorization rules before opening or operating Device Hub itself.

Read [the simulator guide](../../../docs/SIMULATOR_VERIFICATION.md) for the
verified commands, Duo display selection, and the remaining manual pose step.
For submission assets, read its App Store section and use
`scripts/capture_store_screenshots.py` to coordinate native UI navigation with
full-frame screenshots, then validate the three images and their manifest.

- Discover the target simulator; scope every command to its UDID.
- Capture a fresh `snapshot-ui` immediately before choosing an `elementRef`.
  References expire and become stale after navigation or layout changes.
- Use native runtime screenshots as layout evidence. A passing unit test is
  runtime compatibility evidence, not a visual or fold/unfold check.
- Prefer `ScribeUITests` on the Duo inner display. The CLI can report a
  successful tap without changing the active UI there. Assert the resulting
  screen or value; the command exit code alone does not verify interaction.
- Record the actual display and pose tested. An inactive Duo framebuffer can
  be black while the active display is working normally.
- Preserve the user's simulator data. Scribe's **Generate Demo Data** action
  clears existing records, so use a disposable simulator or obtain permission.

Finish with before/after images and the verified interaction results. Name any
unverified display, pose, keyboard, or accessibility case explicitly.
