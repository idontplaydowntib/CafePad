# CafePad build and device setup

Experimental Cemu-based iPad fork, based on [EspressU v1.2](https://github.com/EspressU/EspressU-Emu/tree/eb6779ce2ed9022d563b167517e508a7b25c6ac9), [MuffinEMU by Void](https://github.com/MuffinEMU/Muffin-EMU), and [Cemu](https://github.com/cemu-project/Cemu).

The first target is an iPad 10th generation (A14) running iPadOS 27.0 and New Super Mario Bros. U (USA). Compatibility and sustained performance on that device are unverified. A successful build alone does not establish playable emulation.

The existing SwiftUI game library, WUX importer, Metal renderer, ARM64 recompiler, touch controls, controllers, and built-in StikJIT integration come from the upstream projects. This fork adds a GitHub Actions IPA build, a separate app identifier, sideload entitlement configuration, source provenance, and an automatically installed title-screen crash workaround for NSMBU. Original credits and licence notices remain in place.

## Build an IPA

In this repository's **Actions** tab, enable workflows if GitHub asks, select **Build CafePad iPad IPA**, and choose **Run workflow** on the `ipad-local-jit` branch. The workflow uses a macOS Xcode runner, compiles the emulator and interface, and uploads `CafePad-unsigned.ipa` with its checksum and build details. It does not publish a release or sign the app.

The initial bootstrap build on `main` may contain a `cafepad.patch` file. The workflow checks and applies it, commits the resulting source to `ipad-local-jit`, and builds that commit. Later builds use the committed source directly. No game or pairing data is uploaded.

For an app-only test build, select **Build CafePad iPad IPA with released core** instead. It compiles the app and StikJIT framework, and reuses the unchanged Cemu runtime from EspressU v1.2. Both the original IPA and the runtime binary must match pinned SHA-256 checksums. `runtime-core-provenance.json` states which route produced the IPA. Use the full source build when changing core or bridge implementation files.

To build on a Mac with full Xcode:

```sh
git clone --recursive --branch ipad-local-jit https://github.com/idontplaydowntib/CafePad.git
cd CafePad
brew install cmake ninja xcodegen pkg-config autoconf automake libtool
xcodebuild -downloadComponent MetalToolchain
bash ci/build-ipad.sh
python3 ci/verify-ipa.py build-ios/package/CafePad-unsigned.ipa
```

Windows can prepare and upload the source, but cannot run Apple's iOS compiler. XcodeGen retains the `EspressU` project/target/binary names internally; the installed app is displayed as CafePad and uses `org.cafepad.emulator`.

## Sideload and start

1. Sign and sideload the unsigned IPA with a compatible installer using your Apple account. Preserve the StikJIT helper extension and nested frameworks. Enable Developer Mode on the iPad.
2. The host must retain `get-task-allow` for built-in JIT. The supplied `src/ios/Sideload.entitlements` also requests increased memory and extended virtual addressing. Your provisioning profile and installer determine which entitlements can actually be granted; a plist declaration alone cannot grant them.
3. Connect LocalDevVPN. In **Settings > JIT**, import a pairing file for that exact iPad or use the upstream on-device pairing flow where available. Pairing files stay on your device; do not commit them.
4. Leave the recompiler enabled. JIT is attached when starting a game. Confirm that the app reports usable JIT; a VPN connection alone is insufficient. If JIT fails, the interpreter can be much slower. Built-in JIT is unavailable inside LiveContainer.
5. Import your matching `keys.txt` and WUX through the app. WUX can be read directly; decompression does not decrypt it. Nothing in this repository supplies keys, firmware, or games.
6. For NSMBU, confirm **Graphic packs > New Super Mario Bros. U > Workarounds > Title Screen Crash Fix** is enabled. This fork installs the CC0 community pack on its first launch. It preserves an existing installed copy and any user edits.

The crash workaround is pinned to community pack commit `975f3759d7837da5a374150347d3202360b13ca3`. Its original description says it was tested against the latest game update. It is not proof that every dump/version works. On A14, begin with the existing Balanced rendering default and measure performance before raising resolution or changing CPU accuracy settings.

## Verification and reports

`ci/verify-ipa.py` checks the archive, iPad declaration, physical-device arm64 binaries, Cemu bridge symbols, graphics libraries, JIT helper and required resources. It does not execute the app, verify a provisioning signature, or test JIT/gameplay.

After a device test, record the iPad model, OS build, app source commit, JIT status, game title/version, selected renderer, enabled workaround and the launch log from **Settings > Device report and logs**. Report title-screen behaviour and several minutes of actual play separately.

The full build compiles the core and app from public source with pinned submodules; the app-only route reuses the released core as described above. The pinned StikJIT dependency includes a public prebuilt idevice static library; MoltenVK is also vendored. Build details record their hashes and tool versions. The procedure is rebuildable, with no claim of byte-identical output.

## Credits and licences

- Cemu and the applicable fork source: [MPL-2.0](../LICENSE.txt). Preserve all source notices and component-specific licences.
- EspressU by Amar, based on MuffinEMU by Void. [Original README](UPSTREAM-README.md).
- StikJIT by the StikDebug project, pinned to `32287268fa5824f9edce4cb359f5833ce0cf7b00`.
- NSMBU workaround by Xalphenos and the Cemu community graphic-pack contributors: [CC0 licence and provenance](../bin/graphicPacks/CafePad_NSMBU_CrashFix/PROVENANCE.md).

CafePad is an independent experimental fork, with no affiliation with Nintendo or an official Cemu iOS release.
