#!/usr/bin/env python3
import plistlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RUNNER_DIR = ROOT / "client" / "macos" / "Runner"


def load_plist(path: Path):
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except FileNotFoundError:
        raise SystemExit(f"Missing plist: {path}")
    except plistlib.InvalidFileException as error:
        raise SystemExit(f"Invalid plist {path}: {error}")


def require_bool(plist, path: Path, key: str, expected: bool):
    actual = plist.get(key)
    if actual is not expected:
        raise SystemExit(f"{path} requires {key}={expected!s}, got {actual!r}")


def check_info_plist():
    path = RUNNER_DIR / "Info.plist"
    plist = load_plist(path)
    usage = plist.get("NSMicrophoneUsageDescription")
    if not isinstance(usage, str) or not usage.strip():
        raise SystemExit(f"{path} requires non-empty NSMicrophoneUsageDescription")


def check_entitlements(name: str):
    path = RUNNER_DIR / name
    plist = load_plist(path)
    require_bool(plist, path, "com.apple.security.app-sandbox", False)
    require_bool(plist, path, "com.apple.security.network.client", True)
    require_bool(plist, path, "com.apple.security.device.audio-input", True)


def main():
    check_info_plist()
    check_entitlements("DebugProfile.entitlements")
    check_entitlements("Release.entitlements")
    print("macOS client metadata verified")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        print(f"macOS client metadata check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
