#!/usr/bin/env python3
"""Give embedded flat Catalyst frameworks Apple's versioned Mac layout, before app signing/validation.

Moves files only; never removes a bundle/build product or modifies the downloaded source artifacts.
https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
"""
import os
from pathlib import Path
import plistlib
import subprocess

if os.environ.get("EFFECTIVE_PLATFORM_NAME") != "-maccatalyst":
    raise SystemExit(0)

folder = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FRAMEWORKS_FOLDER_PATH"]
for framework in sorted(folder.glob("*.framework")):
    info = framework / "Info.plist"
    if not info.is_file() or (framework / "Versions").exists():
        continue
    executable = plistlib.loads(info.read_bytes())["CFBundleExecutable"]
    contents = list(framework.iterdir())
    version = framework / "Versions" / "A"
    resources = version / "Resources"
    resources.mkdir(parents=True)
    for item in contents:
        destination = version if item.name in {executable, "Headers", "Modules", "_CodeSignature"} else resources
        item.rename(destination / item.name)
    (framework / "Versions" / "Current").symlink_to("A")
    for name in [executable, "Resources", "Headers", "Modules"]:
        if (version / name).exists():
            (framework / name).symlink_to("Versions/Current/" + name)
    if os.environ.get("CODE_SIGNING_ALLOWED") == "YES":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(framework)], check=True)
