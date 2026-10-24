#!/usr/bin/env python3
"""Check app-owned source and compiled products, including their build provenance."""
import argparse
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OBSOLETE = re.compile(rb"\bodin\b|jellyfin|odinremote|odinplayer", re.IGNORECASE)


def source_files(root):
    for directory in (root / "App", root / "Packages"):
        for path in directory.rglob("*"):
            if not path.is_file() or any(part in (".build", ".swiftpm", "Tests") for part in path.parts):
                continue
            if path.suffix in (".swift", ".xcstrings", ".plist"):
                yield path
    yield root / "project.yml"
    for project in root.glob("*.xcodeproj/project.pbxproj"):
        yield project


def obsolete_in(path):
    data = path.read_bytes()
    return OBSOLETE.search(data) is not None or OBSOLETE.search(data.replace(b"\0", b"")) is not None


def verify(root, app=None, revision=None, tag=None):
    errors = []
    sources = list(source_files(root))
    for path in sources:
        if obsolete_in(path):
            errors.append(f"obsolete player integration in source/project: {path.relative_to(root)}")
    if app:
        info_path = app / "Info.plist"
        if not info_path.exists():
            info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        if revision and info.get("BlusionSourceRevision") != revision:
            errors.append("compiled app source revision does not match the intended commit")
        if tag and info.get("BlusionBuildTag") != tag:
            errors.append("compiled app build tag does not match the intended build")
        executable = info.get("CFBundleExecutable")
        binary = app / executable if executable else None
        if binary and not binary.exists():
            binary = app / "Contents/MacOS" / executable
        if not binary or not binary.is_file():
            errors.append("compiled app executable is missing")
        # Include the debug companion library: recent Xcode debug executables are
        # only a launcher and put the app's actual Swift code in this dylib.
        products = [p for p in app.rglob("*") if p.is_file() and "Frameworks" not in p.parts
                    and (p == binary or p.suffix in (".dylib", ".strings", ".stringsdict", ".plist", ".xcstrings"))]
        for path in products:
            if obsolete_in(path):
                errors.append(f"obsolete player interface/code in compiled app: {path.relative_to(app)}")
        print(f"player-build: inspected {len(products)} compiled executable/resource files")
        print(f"player-build: revision={info.get('BlusionSourceRevision', 'missing')} tag={info.get('BlusionBuildTag', 'missing')}")
    print(f"player-build: inspected {len(sources)} app-owned source/project files")
    if errors:
        raise ValueError("\n".join(errors))
    print("player-build: PASS" + (" (compiled bundle and source)" if app else " (source only; no compiled-app claim)"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--expected-revision")
    parser.add_argument("--expected-tag")
    args = parser.parse_args()
    try:
        verify(args.source_root, args.app, args.expected_revision, args.expected_tag)
    except (ValueError, OSError, plistlib.InvalidFileException) as exc:
        parser.exit(1, f"player-build: FAIL: {exc}\n")


if __name__ == "__main__":
    main()
