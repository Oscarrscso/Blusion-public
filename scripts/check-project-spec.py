#!/usr/bin/env python3
"""Static checks on project.yml (and its opt-in fallback overlay) that need no Xcode.

XcodeGen itself only runs on macOS in this project, so this catches the mistakes that can be caught anywhere: invalid YAML,
missing targets, dangling local package paths, and the App Transport Security rules from PLAN §1. Needs PyYAML; skips (exit 0) without it.
"""
import os
import sys

try:
    import yaml
except ImportError:
    print("check-project-spec: PyYAML not installed, skipped")
    sys.exit(0)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors = []


def load(text, label):
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as exc:
        errors.append(f"{label}: invalid YAML: {exc}")
        return None


def check(spec, label, fallback):
    if spec is None:
        return
    targets = spec.get("targets", {})
    for name in ("Blusion", "BlusionTests", "BlusionUITests"):
        if name not in targets:
            errors.append(f"{label}: missing target {name}")
    packages = spec.get("packages", {})
    for name, pkg in packages.items():
        path = pkg.get("path")
        if path and not os.path.isfile(os.path.join(root, path, "Package.swift")):
            errors.append(f"{label}: package {name} points at {path}, which has no Package.swift")
    app = targets.get("Blusion", {})
    deps = [d.get("package") for d in app.get("dependencies", []) if isinstance(d, dict)]
    for dep in deps:
        if dep not in packages:
            errors.append(f"{label}: Blusion depends on package {dep}, which is not declared")
    for required in ("StremioKit", "PlayerKit", "Persistence", "Features"):
        if required not in deps:
            errors.append(f"{label}: Blusion does not depend on {required}")
    if fallback != ("FallbackPlayer" in deps):
        errors.append(f"{label}: FallbackPlayer dependency {'missing' if fallback else 'present'} (expected fallback={fallback})")
    base = spec.get("settings", {}).get("base", {})
    if str(base.get("SWIFT_VERSION")) != "6.0":
        errors.append(f"{label}: SWIFT_VERSION must be 6.0 (PLAN §1)")
    if base.get("SWIFT_STRICT_CONCURRENCY") != "complete":
        errors.append(f"{label}: SWIFT_STRICT_CONCURRENCY must be complete")
    flags = app.get("settings", {}).get("base", {}).get("OTHER_SWIFT_FLAGS", "")
    if fallback != ("BLUSION_FALLBACK_ENGINE" in str(flags)):
        errors.append(f"{label}: BLUSION_FALLBACK_ENGINE flag mismatch (expected fallback={fallback})")
    props = app.get("info", {}).get("properties", {})
    ats = props.get("NSAppTransportSecurity", {})
    if "NSAllowsArbitraryLoads" in ats:
        errors.append(f"{label}: NSAllowsArbitraryLoads must never be set (PLAN §1)")
    if ats.get("NSAllowsLocalNetworking") is not True:
        errors.append(f"{label}: NSAllowsLocalNetworking must be true (M2)")
    if ats.get("NSAllowsArbitraryLoadsForMedia") is not True:
        errors.append(f"{label}: NSAllowsArbitraryLoadsForMedia must be true (M5, ADR-005)")
    if "audio" not in props.get("UIBackgroundModes", []):
        errors.append(f"{label}: UIBackgroundModes must include audio (M5)")
    if not props.get("NSLocalNetworkUsageDescription"):
        errors.append(f"{label}: NSLocalNetworkUsageDescription is required (M2)")
    for needle in ("stremio",):
        for key in ("PRODUCT_BUNDLE_IDENTIFIER",):
            value = str(app.get("settings", {}).get("base", {}).get(key, "")).lower()
            if needle in value:
                errors.append(f"{label}: bundle id must not contain '{needle}' (PLAN §1 trademark rule)")
        if needle in str(spec.get("name", "")).lower() or needle in str(props.get("CFBundleDisplayName", "")).lower():
            errors.append(f"{label}: app name must not contain '{needle}' (PLAN §1 trademark rule)")


# The fallback engine must use the LGPL build of MPVKit, never the GPL one (docs/licenses.md).
fallback_manifest = os.path.join(root, "Packages", "FallbackPlayer", "Package.swift")
if os.path.isfile(fallback_manifest):
    manifest_text = open(fallback_manifest, encoding="utf-8").read()
    if "MPVKit-GPL" in manifest_text or "-GPL" in manifest_text:
        errors.append("Packages/FallbackPlayer/Package.swift references a GPL product; only the LGPL build may be linked (docs/licenses.md)")

# AetherEngine lives in its own dynamic framework so its FFmpeg calls bind to its own (dynamic) FFmpeg, not to MPVKit's static one, and it
# must not carry a second copy of Blusion's packages (docs/licenses.md, "AetherEngine").
aether_manifest = os.path.join(root, "Packages", "AetherPlayer", "Package.swift")
if os.path.isfile(aether_manifest):
    aether_text = open(aether_manifest, encoding="utf-8").read()
    if "type: .dynamic" not in aether_text:
        errors.append("Packages/AetherPlayer/Package.swift: the AetherPlayer library must be type: .dynamic")
    for forbidden in ("MPVKit", "PlayerKit", "StremioKit", "TrueHDReferenceRender"):
        if f'"{forbidden}' in aether_text or f"../{forbidden}" in aether_text:
            errors.append(f"Packages/AetherPlayer/Package.swift must not reference {forbidden}")

def check_release_assets(info_properties):
    """M8: privacy manifest, string catalogs and the app icon exist and say what the plan requires."""
    import json
    import plistlib
    import struct

    privacy_path = os.path.join(root, "App", "PrivacyInfo.xcprivacy")
    try:
        privacy = plistlib.load(open(privacy_path, "rb"))
    except Exception as exc:  # noqa: BLE001 - any failure to read or parse is the finding
        errors.append(f"App/PrivacyInfo.xcprivacy unreadable: {exc}")
        privacy = {}
    if privacy:
        if privacy.get("NSPrivacyTracking") is not False:
            errors.append("PrivacyInfo.xcprivacy: NSPrivacyTracking must be false")
        if privacy.get("NSPrivacyTrackingDomains"):
            errors.append("PrivacyInfo.xcprivacy: no tracking domains may be declared")
        if privacy.get("NSPrivacyCollectedDataTypes"):
            errors.append("PrivacyInfo.xcprivacy: the app collects no data; declare none")
        declared = {item.get("NSPrivacyAccessedAPIType"): item.get("NSPrivacyAccessedAPITypeReasons", []) for item in privacy.get("NSPrivacyAccessedAPITypes", [])}
        if not declared.get("NSPrivacyAccessedAPICategoryUserDefaults"):
            errors.append("PrivacyInfo.xcprivacy: UserDefaults is used (settings) and needs a declared reason")

    for name in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
        path = os.path.join(root, "App", name)
        try:
            catalog = json.load(open(path, encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            errors.append(f"App/{name} unreadable: {exc}")
            continue
        if catalog.get("sourceLanguage") != "en" or "strings" not in catalog:
            errors.append(f"App/{name}: must be a string catalog with sourceLanguage en")
        if name == "InfoPlist.xcstrings":
            for key in ("CFBundleDisplayName", "NSLocalNetworkUsageDescription"):
                value = catalog.get("strings", {}).get(key, {}).get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
                if value != info_properties.get(key):
                    errors.append(f"App/InfoPlist.xcstrings: {key} differs from project.yml ({value!r} vs {info_properties.get(key)!r})")

    icon = os.path.join(root, "App", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")
    try:
        header = open(icon, "rb").read(33)
        width, height, depth, color_type = struct.unpack(">IIBB", header[16:26])
        if header[:8] != b"\x89PNG\r\n\x1a\n" or (width, height) != (1024, 1024):
            errors.append("AppIcon-1024.png must be a 1024x1024 PNG")
        if color_type in (4, 6):
            errors.append("AppIcon-1024.png must not have an alpha channel (App Store rejects it)")
    except OSError as exc:
        errors.append(f"app icon missing: {exc}")


text = open(os.path.join(root, "project.yml"), encoding="utf-8").read()
_spec = load(text, "project.yml") or {}
check_release_assets(_spec.get("targets", {}).get("Blusion", {}).get("info", {}).get("properties", {}))
check(load(text, "project.yml"), "project.yml", fallback=False)
check(load(text.replace("#fallback# ", ""), "fallback overlay"), "fallback overlay", fallback=True)

if errors:
    print("check-project-spec: FAILED")
    for error in errors:
        print("  -", error)
    sys.exit(1)
print("check-project-spec: project.yml and the fallback overlay are consistent")
