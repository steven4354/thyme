# Thyme Native

An Apple Silicon compatibility fork of [Thyme](https://github.com/joaomoreno/thyme), the macOS menu-bar timer by João Moreno.

This fork starts from upstream **0.5.1** (`f37dafad93c490ff70c45f91273253a6845f8fd0`). It keeps that release's timer, AppleScript commands, preferences, JSON export, and Core Data model. It does not include upstream's later task-tagging changes.

The compatibility changes build the app and shortcut frameworks for arm64, replace Growl with macOS notifications, update the status-bar API, and give the fork its own bundle identifier and data directory. The deployment target is macOS 11; testing has been limited to a newer macOS release, as described below.

## Build from source with Xcode

Use an Apple Silicon Mac with **full Xcode and its macOS SDK**. Command Line Tools alone do not provide the interface and model compilers needed for this path.

After cloning this repository:

```sh
git submodule update --init --recursive
./scripts/build-source.sh
```

The script uses the shared `ThymeNative` scheme to compile the app, both frameworks, Interface Builder files, and Core Data model from the checkout. It does not require an installed copy of Thyme. Compiler, arm64, deployment-target, and local-signing overrides also apply to the pinned legacy dependency project, which remains unmodified.

The output is:

```text
build/source/Build/Products/Release/Thyme Native.app
```

The script checks required resources, arm64 architectures, and nested code signatures. It does not install or launch the app. An optional first argument selects a different Xcode derived-data directory.

If the active developer directory points to Command Line Tools, select an installed Xcode for this command without changing the system-wide setting:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-source.sh
```

**The full Xcode source build has not yet been validated.** The local development environment has only Command Line Tools, so this build path has not been executed there.

## Command Line Tools recovery build

A separate local recovery path remains available for a clean, committed checkout:

```sh
./scripts/build-native.sh --resource-app /path/to/Thyme.app
```

The resource app must be upstream Thyme 0.5.1. If omitted, `--resource-app` defaults to `/Applications/Thyme.app`. This path compiles all executable code from source but borrows the original app's compiled interface/model files and other resources. It is not a standalone source build.

It writes `build/Thyme Native.app` and `build/native-build-info.json`. Rebuilding moves the previous output and report to timestamped backup names; quit that output app before rebuilding. The original resource app and its data are not modified.

The recovery report records the clean source commit/tree, dependency commit, toolchain, resource hashes, and final bundle file hashes. The input record is embedded before signing; output hashes remain in the external report to avoid a self-referential hash. Its `output.tree_sha256` is the SHA-256 of UTF-8 `json.dumps(output.entries, sort_keys=True, separators=(",", ":"))`. Entries cover file contents, file modes, and symlink targets, excluding timestamps, extended attributes, and empty directories. This records a particular local build; it does not promise byte-identical rebuilds or establish distribution trust.

Generated files under `build/` are ignored. Recovery provenance and debug output can contain local paths and toolchain details; they are not part of the published source.

## Run and data

Open the built `Thyme Native.app` to use its menu-bar controls. Its bundle identifier is `com.joaomoreno.Thyme.Native`, and its normal data folder is `~/Library/Application Support/Thyme Native`. Upstream Thyme uses `~/Library/Application Support/Thyme`; existing history is not imported automatically.

For isolated session-history tests, launch the executable with an absolute directory:

```sh
THYME_DATA_DIRECTORY="$PWD/build/test-data" \
  "$PWD/build/source/Build/Products/Release/Thyme Native.app/Contents/MacOS/Thyme"
```

This override isolates session history only. Instances still share the Native preference domain and notification settings. Notification delivery requires normal macOS permission; timer controls do not require it.

## Validation status

Local recovery builds have been checked on Apple Silicon running macOS 27.0.1:

- All three runtime binaries are arm64, and nested code signatures verify.
- The app enters its event loop; AppleScript start, pause, toggle, and stop commands work.
- Paused time is excluded from saved sessions, and saved history survives quit/relaunch.
- The original installation and data remain separate.

These results cover recovery artifacts only; the full Xcode source build remains unvalidated. Visual menus, mouse interaction, global hotkeys, notification delivery, sleep/wake, and JSON export have not all been verified end to end. Intel builds and other macOS versions are untested. Legacy ShortcutRecorder compiler warnings remain.

## Credits and distribution

Thyme is copyright João Moreno and is distributed under the [MIT license](LICENSE). Dependency credits and terms are in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and [ShortcutRecorder's license](https://github.com/joaomoreno/ShortcutRecorder/blob/e16bb69bff0732c00e912c360d221b622ec92df8/Resources/LICENSE.txt).

Local builds use ad-hoc signatures. They are not Developer ID signed or notarized, so successful integrity checks do not establish Gatekeeper acceptance for downloaded binaries. This repository distributes source; a public binary release would require separate signing, notarization, and release validation.
