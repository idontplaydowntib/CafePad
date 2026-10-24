#!/usr/bin/env python3
"""Check IPA structure and native iOS binaries without running the app.

This does not verify signing, JIT operation, or game compatibility.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def macho(data):
    require(len(data) >= 32, "Truncated native binary")
    magic = struct.unpack_from(">I", data)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]
        stride = 32 if magic == 0xCAFEBABF else 20
        require(0 < count <= 64 and 8 + count * stride <= len(data), "Invalid fat header")
        for index in range(count):
            start = 8 + index * stride
            cpu = struct.unpack_from(">I", data, start)[0]
            if cpu != 0x0100000C:
                continue
            fmt = ">QQ" if stride == 32 else ">II"
            offset, size = struct.unpack_from(fmt, data, start + 8)
            require(offset + size <= len(data), "Truncated arm64 slice")
            return macho(data[offset:offset + size])
        raise ValueError("No arm64 slice")

    header = struct.unpack_from("<8I", data)
    require(header[0] == 0xFEEDFACF, "Not a 64-bit little-endian Mach-O")
    require(header[1] == 0x0100000C, "Binary is not arm64")
    require(header[3] in (2, 6), "Binary is not an executable or dynamic library")
    count, command_bytes = header[4:6]
    require(32 + command_bytes <= len(data) and count <= command_bytes // 8,
            "Truncated load commands")
    result = {"architecture": "arm64", "file_type": header[3], "platform": None,
              "minimum_os": None, "encrypted": False, "libraries": []}
    symbol_table = None
    offset = 32
    for _ in range(count):
        require(offset + 8 <= 32 + command_bytes, "Truncated load command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= 32 + command_bytes, "Invalid load command")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated build-version command")
            platform, minimum = struct.unpack_from("<II", data, offset + 8)
            result.update(platform=platform, minimum_os=version(minimum))
        elif command == 0x25 and result["platform"] is None:  # LC_VERSION_MIN_IPHONEOS
            require(size >= 16, "Truncated minimum-version command")
            result.update(platform=2, minimum_os=version(struct.unpack_from("<I", data, offset + 8)[0]))
        elif command == 0x2C:  # LC_ENCRYPTION_INFO_64
            require(size >= 24, "Truncated encryption command")
            result["encrypted"] = bool(struct.unpack_from("<I", data, offset + 16)[0])
        elif command == 2:  # LC_SYMTAB
            require(size >= 24, "Truncated symbol table command")
            symbol_table = struct.unpack_from("<4I", data, offset + 8)
        elif command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            require(size >= 24, "Truncated library command")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            require(24 <= name_offset < size, "Invalid library name offset")
            result["libraries"].append(data[offset + name_offset:offset + size].split(b"\0", 1)[0].decode("utf-8"))
        offset += size
    require(result["platform"] == 2, "Binary does not target a physical iOS device")
    require(not result["encrypted"], "Encrypted App Store binary cannot be re-signed normally")

    exported = set()
    if symbol_table:
        start, count, strings, string_size = symbol_table
        require(start + count * 16 <= len(data) and strings + string_size <= len(data),
                "Truncated symbol table")
        for index in range(count):
            string_index, symbol_type = struct.unpack_from("<IB", data, start + index * 16)
            if symbol_type & 0xE0 or not symbol_type & 1 or not symbol_type & 0x0E:
                continue
            require(string_index < string_size, "Invalid symbol string")
            name_start = strings + string_index
            if data.startswith(b"_cemu_bridge_", name_start):
                name_end = data.find(b"\0", name_start, strings + string_size)
                require(name_end >= 0, "Unterminated symbol name")
                exported.add(data[name_start:name_end].decode("utf-8"))
    result["cemu_bridge_exports"] = sorted(exported)
    return result


def verify(path):
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP paths")
        require(all(not PurePosixPath(n).is_absolute() and ".." not in PurePosixPath(n).parts
                    for n in names), "Unsafe ZIP path")
        require(archive.testzip() is None, "ZIP CRC failure")
        apps = [n for n in names if n.startswith("Payload/") and n.count("/") == 2
                and n.endswith(".app/Info.plist")]
        require(len(apps) == 1, "Expected exactly one Payload app")
        root = apps[0].removesuffix("Info.plist")
        info = plistlib.loads(archive.read(apps[0]))
        require(2 in info.get("UIDeviceFamily", []), "App does not declare iPad support")
        helper = root + "PlugIns/StikJITHelper.appex/"
        helper_info = plistlib.loads(archive.read(helper + "Info.plist"))
        require(helper_info["CFBundleIdentifier"].startswith(info["CFBundleIdentifier"] + "."),
                "Helper bundle identifier is not nested under the host")
        binaries = {
            "app": root + info["CFBundleExecutable"],
            "core": root + "Frameworks/Cemu.framework/Cemu",
            "jit": root + "Frameworks/StikJIT.framework/StikJIT",
            "helper": helper + helper_info["CFBundleExecutable"],
            "vulkan": root + "Frameworks/MoltenVK.framework/MoltenVK",
            "vulkan_legacy": root + "Frameworks/MoltenVK128.framework/MoltenVK128",
        }
        native = {label: {"path": name, "bytes": archive.getinfo(name).file_size,
                          **macho(archive.read(name))} for label, name in binaries.items()}
        exports = native["core"]["cemu_bridge_exports"]
        for name in ("_cemu_bridge_core_available", "_cemu_bridge_initialize", "_cemu_bridge_boot_title"):
            require(name in exports, f"Missing defined Cemu bridge symbol: {name}")
        for relative in ("CemuData/resources/sharedFonts/", "CemuData/gameProfiles/"):
            require(any(n.startswith(root + relative) and not n.endswith("/") for n in names),
                    f"Missing core data: {relative}")
        game_fix_checked = info["CFBundleIdentifier"] == "org.cafepad.emulator"
        if game_fix_checked:
            for filename in ("rules.txt", "patch_CrashFix.asm"):
                name = root + "CemuData/graphicPacks/CafePad_NSMBU_CrashFix/" + filename
                require(name in names and archive.getinfo(name).file_size > 0,
                        f"Missing bundled NSMBU workaround: {filename}")
        return {"file": path.name, "sha256": digest, "size": path.stat().st_size,
                "bundle_id": info["CFBundleIdentifier"],
                "display_name": info.get("CFBundleDisplayName"),
                "version": info.get("CFBundleShortVersionString"),
                "minimum_os": info.get("MinimumOSVersion"), "ipad_supported": True,
                "source_commit": info.get("CafePadSourceCommit"),
                "nsmbu_workaround_checked": game_fix_checked,
                "binaries": native, "static_checks": "passed",
                "signing_verified": False, "jit_tested": False, "gameplay_tested": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.ipa)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, struct.error) as error:
        parser.exit(1, f"IPA verification failed: {error}\n")
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")


if __name__ == "__main__":
    main()
