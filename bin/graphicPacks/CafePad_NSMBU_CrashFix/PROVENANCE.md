# Official NSMBU Title Screen Crash Fix

This package contains the unmodified official Cemu graphic pack by Xalphenos.

Repository: https://github.com/cemu-project/cemu_graphic_packs
Pinned commit: 975f3759d7837da5a374150347d3202360b13ca3
Source directory: src/NewSuperMarioBrosU/Workarounds/CrashFix
Pinned source: https://github.com/cemu-project/cemu_graphic_packs/tree/975f3759d7837da5a374150347d3202360b13ca3/src/NewSuperMarioBrosU/Workarounds/CrashFix
Retrieved: 2026-10-24
License: CC0-1.0. See LICENSE.md copied unmodified from the pinned repository root.

## Included source hashes (SHA-256)

26085c0e78448871ae001306913d65668066b25dfe9661b53e56201bd8556db1  NewSuperMarioBrosU_CrashFix/rules.txt
cfa282531a5e827401adfff5361dc8473d5758c7f6db72b9897b6daecb85e58e  NewSuperMarioBrosU_CrashFix/patch_CrashFix.asm
5537d4d10b76b81b6e8dfd8b644480a4b1efa332fbb0cdb61126c5be781ef7b4  LICENSE.md

## Purpose and installation

The patch bypasses the game's Mii-resource check so New Super Mario Bros. U and supported New Super Luigi U editions can pass the title screen without the original console's FFLRes system files. It contains patch source and configuration only; it contains no game, keys, firmware, save or copyrighted system resource files.

In EspressU, import this ZIP from the graphic packs page (or import the enclosed folder), then confirm that New Super Mario Bros. U > Workarounds > Title Screen Crash Fix is enabled. The official pack defaults enabled. Its source lists known module checksums for USA NSMBU v0 and v64, EUR v0/v80, and selected combo/Luigi versions. An unmatched game build will not receive the patch. The official rules describe the latest game update as tested. No gameplay test on the target iPad has been performed by this task.

## WUX and keys

EspressU v1.2's existing importer and core accept .wux directly. WUX compression does not remove disc encryption; matching keys.txt is still required for an encrypted disc dump. Decompressing to WUD/ISO does not remove that requirement. Import your own keys in the app's settings. No keys are included here.

Core baseline: https://github.com/EspressU/EspressU-Emu/tree/eb6779ce2ed9022d563b167517e508a7b25c6ac9
Game issue reference: https://wiki.cemu.info/wiki/ARPP01

## Bundling in the fork

CC0 permits copying, adapting and redistributing this pack, including in the app's resources. Copy the pack directory together with LICENSE.md and this provenance into the app resource tree, then copy/expose that resource pack to the core's graphic-pack search directory before game launch. Do not change the patch addresses or supported module checksums without validation. File presence is not proof that the core loaded the pack; verify activation via the core's loaded graphic-pack list or launch log.
