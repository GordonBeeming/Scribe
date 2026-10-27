#!/usr/bin/env python3
"""Drive native UI tests and capture full simulator framebuffers for App Store."""

import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from export_store_screenshots import export_screenshots


STAGES = {"01-dashboard", "02-items", "03-detail"}


def capture(args):
    subprocess.run([
        "xcrun", "simctl", "status_bar", args.simulator_id, "override",
        "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
        "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100",
    ], check=True)
    try:
        capture_frames(args)
    finally:
        subprocess.run([
            "xcrun", "simctl", "status_bar", args.simulator_id, "clear",
        ], check=True)


def capture_frames(args):
    repo = Path(__file__).resolve().parents[4]
    if args.derived_data is None:
        key = hashlib.sha256(str(repo).encode()).hexdigest()[:10]
        args.derived_data = Path(tempfile.gettempdir()) / f"scribe-simulator-{key}"
    args.derived_data = args.derived_data.expanduser().resolve()
    run = Path(tempfile.mkdtemp(prefix="scribe-store-"))
    frames = run / "frames"
    frames.mkdir()
    session = str(uuid.uuid4())
    env = os.environ.copy()
    env["TEST_RUNNER_SCRIBE_CAPTURE_STORE_SCREENSHOTS"] = "1"
    env["TEST_RUNNER_SCRIBE_CAPTURE_SESSION"] = session
    subprocess.run(["xcodegen", "generate"], cwd=repo, check=True)
    command = [
        "xcodebuild", "test", "-project", "Scribe.xcodeproj", "-scheme", "Scribe",
        "-destination", f"platform=iOS Simulator,id={args.simulator_id}",
        "-derivedDataPath", str(args.derived_data), "-resultBundlePath", str(run / "result.xcresult"),
        "-only-testing:ScribeUITests/ScribeNavigationTests/testCaptureAppStoreScreenshots",
        "-parallel-testing-enabled", "NO", "CODE_SIGN_IDENTITY=-",
    ]
    runner_info = args.derived_data / "Build/Products/Debug-iphonesimulator/ScribeUITests-Runner.app/Info.plist"
    records = []
    completed = set()
    print(f"Native capture log: {run / 'xcodebuild.log'}", flush=True)
    with (run / "xcodebuild.log").open("w") as log:
        process = subprocess.Popen(command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                if runner_info.exists():
                    with runner_info.open("rb") as file:
                        bundle_id = plistlib.load(file)["CFBundleIdentifier"]
                    container = subprocess.run(
                        ["xcrun", "simctl", "get_app_container", args.simulator_id, bundle_id, "data"],
                        capture_output=True, text=True,
                    )
                    if container.returncode == 0:
                        folder = Path(container.stdout.strip()) / "Documents/AppStoreCapture"
                        request = folder / f"{session}.request"
                        if request.exists():
                            stage = request.read_text().strip()
                            if stage not in STAGES:
                                raise ValueError(f"Unexpected screenshot stage: {stage}")
                            if stage not in completed:
                                filename = f"{stage}.png"
                                # Existence checks can finish before the navigation animation.
                                time.sleep(1)
                                subprocess.run([
                                    "xcrun", "simctl", "io", args.simulator_id, "screenshot",
                                    "--display", str(args.display_id), str(frames / filename),
                                ], check=True, capture_output=True, text=True)
                                records.append({
                                    "exportedFileName": filename,
                                    "suggestedHumanReadableName": f"app-store-{stage}-screen-{args.display_id}",
                                })
                                completed.add(stage)
                                (folder / f"{session}.{stage}.ack").write_text("captured\n")
                                print(f"Captured {stage} from display {args.display_id}", flush=True)
                time.sleep(0.2)
            if process.returncode != 0:
                raise RuntimeError(f"Native screenshot UI test failed; inspect {run / 'xcodebuild.log'}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    if completed != STAGES:
        raise RuntimeError(f"Screenshot run did not finish all stages: {completed}; log: {run}")
    (frames / "manifest.json").write_text(json.dumps([{"attachments": records}], indent=2))
    result = export_screenshots(frames, args.output, args.display)
    result["resultBundle"] = str(run / "result.xcresult")
    result["captureMethod"] = "native XCUITest navigation with simctl full-frame capture"
    (args.output / f"manifest-{args.display}.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--display-id", type=int, required=True)
    parser.add_argument("--display", choices=["outer", "inner"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, default=None)
    capture(parser.parse_args())


if __name__ == "__main__":
    main()
