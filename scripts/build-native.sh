#!/bin/bash
# Build the 0.5.1-based native app with Apple Command Line Tools.
set -euo pipefail
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$script_root" "$@" <<'PY'
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1]).resolve()
parser = argparse.ArgumentParser(description="Build Thyme Native for Apple Silicon without full Xcode.")
parser.add_argument("--resource-app", type=Path, default=Path("/Applications/Thyme.app"),
                    help="An unmodified Thyme 0.5.1 app supplying compiled nib/model resources")
args = parser.parse_args(sys.argv[2:])

def capture(arguments, cwd=root):
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()

def file_entry(path):
    if path.is_symlink():
        return {"symlink": os.readlink(path)}
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "mode": format(path.stat().st_mode & 0o7777, "04o")}

def tree_manifest(directory):
    return {path.relative_to(directory).as_posix(): file_entry(path)
            for path in sorted(directory.rglob("*")) if path.is_file() or path.is_symlink()}

def source_state():
    return {
        "source_commit": capture(["git", "rev-parse", "HEAD"]),
        "source_tree": capture(["git", "rev-parse", "HEAD^{tree}"]),
        "source_dirty": bool(capture(["git", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"])),
        "shortcut_recorder_commit": capture(["git", "rev-parse", "HEAD"], root / "ShortcutRecorder"),
        "shortcut_recorder_dirty": bool(capture(["git", "status", "--porcelain", "--untracked-files=all"], root / "ShortcutRecorder")),
    }

initial_source = source_state()
if initial_source["source_dirty"] or initial_source["shortcut_recorder_dirty"]:
    parser.error("Commit or remove pending source changes before building; both checkouts must be clean.")

resource_app = args.resource_app.resolve()
resource_contents = resource_app / "Contents"
with (resource_contents / "Info.plist").open("rb") as stream:
    release_info = plistlib.load(stream)
if release_info.get("CFBundleShortVersionString") != "0.5.1" or release_info.get("CFBundleIdentifier") != "com.joaomoreno.Thyme":
    parser.error("The resource app must be the original Thyme 0.5.1 release.")
for filename in ("MainMenu.nib", "PreferencesWindowController.nib", "DataModel.mom"):
    if not (resource_contents / "Resources" / filename).is_file():
        parser.error(f"Missing compiled release resource: {filename}")
if not (root / "ShortcutRecorder" / "SRRecorderControl.m").is_file():
    parser.error("Initialize the release's ShortcutRecorder submodule first.")
if initial_source["shortcut_recorder_commit"] != "e16bb69bff0732c00e912c360d221b622ec92df8":
    parser.error("Use the ShortcutRecorder revision pinned by Thyme 0.5.1 (run git submodule update --init).")

def resource_inputs():
    result = {"Contents/Info.plist": file_entry(resource_contents / "Info.plist")}
    for relative in ("Resources", "Frameworks/ShortcutRecorder.framework/Resources",
                     "Frameworks/PTHotKey.framework/Resources"):
        # Framework Resources is a top-level symlink in the historical release.
        directory = (resource_contents / relative).resolve()
        for path, item in tree_manifest(directory).items():
            result[f"Contents/{relative}/{path}"] = item
    return result

initial_resources = resource_inputs()
build = root / "build"
build.mkdir(exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix="native-", dir=build))
app = staging / "Thyme Native.app"
contents = app / "Contents"
frameworks = contents / "Frameworks"
(contents / "MacOS").mkdir(parents=True)
frameworks.mkdir()
shutil.copytree(resource_contents / "Resources", contents / "Resources")
shutil.copy2(root / "LICENSE", contents / "Resources" / "LICENSE")
shutil.copy2(root / "THIRD_PARTY_NOTICES.txt", contents / "Resources" / "THIRD_PARTY_NOTICES.txt")
if (root / "LICENSES").is_dir():
    shutil.copytree(root / "LICENSES", contents / "Resources" / "LICENSES", dirs_exist_ok=True)
for obsolete in ("Growl Registration Ticket.growlRegDict",):
    (contents / "Resources" / obsolete).unlink(missing_ok=True)

with (root / "Thyme-Info.plist").open("rb") as stream:
    app_info = plistlib.load(stream)
app_info.update({
    "CFBundleDisplayName": "Thyme Native",
    "CFBundleName": "Thyme Native",
    "CFBundleExecutable": "Thyme",
    "CFBundleIdentifier": "com.joaomoreno.Thyme.Native",
    "CFBundleShortVersionString": "0.5.2",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "11.0",
    "ThymeDataDirectoryName": "Thyme Native",
    "NSHighResolutionCapable": True,
})
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump(app_info, stream)

commands = []
def run(arguments):
    command = [str(argument) for argument in arguments]
    subprocess.run(command, cwd=root, check=True)
    commands.append(command)

sdk = capture(["xcrun", "--show-sdk-path"])
clang = capture(["xcrun", "--find", "clang"])
toolchain = {
    "developer_directory": capture(["xcode-select", "-p"]),
    "sdk_path": sdk,
    "sdk_version": capture(["xcrun", "--show-sdk-version"]),
    "sdk_build_version": capture(["xcrun", "--show-sdk-build-version"]),
    "clang_path": clang,
    "clang_version": capture([clang, "--version"]),
    "linker": json.loads(capture(["xcrun", "ld", "-version_details"])),
    "dsymutil_version": capture(["xcrun", "dsymutil", "--version"]),
    "python_executable": sys.executable,
    "python_version": sys.version,
    "macos": capture(["sw_vers"]),
    "machine": capture(["uname", "-m"]),
}
common = [clang, "-arch", "arm64", "-isysroot", sdk, "-mmacosx-version-min=11.0",
          "-O2", "-g", "-fno-modules", "-Wno-deprecated-declarations",
          "-I", root, "-I", root / "ShortcutRecorder", "-F", frameworks]

def prepare_framework(name, headers):
    bundle = frameworks / f"{name}.framework"
    version = bundle / "Versions" / "A"
    (version / "Headers").mkdir(parents=True)
    shutil.copytree(resource_contents / "Frameworks" / f"{name}.framework" / "Resources", version / "Resources")
    for header in headers:
        shutil.copy2(header, version / "Headers" / header.name)
    (bundle / "Versions" / "Current").symlink_to("A")
    for item in (name, "Headers", "Resources"):
        (bundle / item).symlink_to(f"Versions/Current/{item}")
    info_path = version / "Resources" / "Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    for key in list(info):
        if key.startswith("DT") or key in ("BuildMachineOSBuild", "CFBundleSupportedPlatforms"):
            del info[key]
    info["LSMinimumSystemVersion"] = "11.0"
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream)
    return bundle, version / name

recorder, recorder_binary = prepare_framework("ShortcutRecorder", (root / "ShortcutRecorder").glob("*.h"))
run(common + ["-fobjc-arc", "-include", root / "ShortcutRecorder" / "ShortcutRecorder_Prefix.pch",
              "-dynamiclib", "-install_name", "@rpath/ShortcutRecorder.framework/Versions/A/ShortcutRecorder",
              "-compatibility_version", "2.0", "-current_version", "2.5.1",
              *sorted((root / "ShortcutRecorder").glob("*.m")),
              "-framework", "Cocoa", "-framework", "Carbon", "-o", recorder_binary])

hotkey, hotkey_binary = prepare_framework("PTHotKey", (root / "ShortcutRecorder" / "PTHotKey").glob("*.h"))
run(common + ["-fno-objc-arc", "-include", root / "Thyme_Prefix.pch",
              "-dynamiclib", "-install_name", "@rpath/PTHotKey.framework/Versions/A/PTHotKey",
              "-compatibility_version", "1.0", "-current_version", "1.1.1",
              *sorted((root / "ShortcutRecorder" / "PTHotKey").glob("*.m")),
              "-framework", "Cocoa", "-framework", "Carbon", "-framework", "ShortcutRecorder",
              "-o", hotkey_binary])

run(common + ["-fno-objc-arc", "-include", root / "Thyme_Prefix.pch", *sorted(root.glob("*.m")),
              "-framework", "Cocoa", "-framework", "Carbon", "-framework", "CoreData",
              "-framework", "UserNotifications", "-framework", "ShortcutRecorder", "-framework", "PTHotKey",
              "-Wl,-rpath,@executable_path/../Frameworks", "-o", contents / "MacOS" / "Thyme"])

inputs = {
    **initial_source,
    "base_release": "0.5.1",
    "built_at_utc": datetime.now(timezone.utc).isoformat(),
    "architecture": "arm64",
    "deployment_target": "11.0",
    "bundle_identifier": app_info["CFBundleIdentifier"],
    "data_directory_name": app_info["ThymeDataDirectoryName"],
    "toolchain": toolchain,
    "compile_commands": list(commands),
    "resource_source": str(resource_app),
    "resource_entries": initial_resources,
    "signing": "ad-hoc; timestamp=none",
}
(contents / "Resources/native-build-inputs.json").write_text(json.dumps(inputs, indent=2, sort_keys=True) + "\n")

for bundle in (recorder, hotkey, app):
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", bundle])
run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
for binary in (recorder_binary, hotkey_binary, contents / "MacOS" / "Thyme"):
    architecture = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if architecture != "arm64":
        raise RuntimeError(f"Expected arm64 binary: {binary}, got {architecture}")

if source_state() != initial_source or resource_inputs() != initial_resources:
    raise RuntimeError("Source or resource inputs changed during the build; existing output was not replaced.")

entries = tree_manifest(app)
provenance = {
    "format_version": 2,
    "inputs": inputs,
    "output": {
        "app_name": app.name,
        "entries": entries,
        "tree_sha256": hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest(),
        "binary_sha256": {binary.relative_to(app).as_posix(): file_entry(binary)["sha256"]
                          for binary in (recorder_binary, hotkey_binary, contents / "MacOS/Thyme")},
    },
    "verification": {"codesign_deep_strict": "passed", "all_runtime_binaries_arm64": True,
                     "source_and_resource_inputs_unchanged": True},
}
report = staging / "native-build-info.json"
report.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
output = build / "Thyme Native.app"
if output.exists():
    suffix = time.time_ns()
    previous = build / f"Thyme Native.previous-{suffix}.app"
    output.rename(previous)
    if (build / "native-build-info.json").exists():
        (build / "native-build-info.json").rename(build / f"native-build-info.previous-{suffix}.json")
app.rename(output)
report.replace(build / "native-build-info.json")
staging.rmdir()
print(f"Built: {output}")
print(f"Clean source commit: {initial_source['source_commit']}")
print(f"Bundle tree SHA-256: {provenance['output']['tree_sha256']}")
print("The original app and its data were not modified. This script does not launch the app.")
PY
