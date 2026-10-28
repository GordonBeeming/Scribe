#!/usr/bin/env python3
"""Export opaque, native-sized Duo PNGs from explicit UI-test captures."""

import argparse
import hashlib
import json
import re
from pathlib import Path

from PIL import Image


SIZES = {
    (1398, 2034): "outer",
    (2034, 1398): "outer",
    (2007, 2853): "inner",
    (2853, 2007): "inner",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--display", choices=["outer", "inner"], required=True)
    args = parser.parse_args()
    print(json.dumps(export_screenshots(args.attachments, args.output, args.display), indent=2))


def export_screenshots(attachments, output, target_display):
    manifest = json.loads((attachments / "manifest.json").read_text())
    output.mkdir(parents=True, exist_ok=True)
    exported = []
    rejected = []
    pending = []
    fingerprints = set()

    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            stage = re.match(r"app-store-(\d+-[a-z-]+)-screen-\d+", name)
            if not stage:
                continue
            filename = attachment["exportedFileName"]
            if Path(filename).name != filename:
                raise ValueError("Attachment filename must be local to its export directory")
            source = attachments / filename
            if source.resolve().parent != attachments.resolve():
                raise ValueError("Attachment escapes its export directory")
            with Image.open(source) as image:
                if image.mode not in {"RGB", "RGBA"} or "transparency" in image.info:
                    raise ValueError(f"Capture must be RGB/RGBA without transparency metadata: {source}")
                display = SIZES.get(image.size)
                if display != target_display:
                    rejected.append({"source": filename, "size": image.size})
                    continue
                if "A" in image.getbands() and image.getchannel("A").getextrema() != (255, 255):
                    raise ValueError(f"Capture has transparent pixels: {source}")
                rgb = image.convert("RGB")
                if all(low == high for low, high in rgb.getextrema()):
                    rejected.append({"source": filename, "reason": "uniform inactive framebuffer"})
                    continue
                fingerprint = hashlib.sha256(rgb.tobytes()).hexdigest()
                if fingerprint in fingerprints:
                    raise ValueError("Identical frames across different screens; check the active display")
                fingerprints.add(fingerprint)
                width, height = rgb.size
                destination = output / f"duo-{display}-{stage.group(1)}-{width}x{height}.png"
                if any(entry[1] == destination for entry in pending):
                    raise ValueError(f"Ambiguous duplicate screenshot: {destination.name}")
                pending.append((rgb.copy(), destination, image.info.get("icc_profile")))
                exported.append({
                    "file": destination.name, "display": display,
                    "width": width, "height": height, "mode": "RGB",
                    "source": filename, "pixelSHA256": fingerprint,
                })

    expected = {"01-dashboard", "02-items", "03-detail"}
    present = {stage for image in exported for stage in expected if stage in image["file"]}
    if present != expected:
        raise ValueError(f"Incomplete native-sized {target_display} set; missing {expected - present}; rejected: {rejected}")
    for rgb, destination, profile in pending:
        temporary = destination.with_name("." + destination.name + ".tmp")
        rgb.save(temporary, format="PNG", icc_profile=profile, dpi=(72, 72))
        temporary.replace(destination)
    result = {
        "capture": "native simulator screenshots; opaque RGB encoding; no resizing",
        "specification": "https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/",
        "images": exported,
        "rejected": rejected,
    }
    (output / f"manifest-{target_display}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


if __name__ == "__main__":
    main()
