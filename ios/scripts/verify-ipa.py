"""Verify a real, unencrypted arm64 iPhone app before personal re-signing."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import struct
import zipfile


def version(raw):
    return f"{raw >> 16}.{(raw >> 8) & 255}.{raw & 255}"


def macho(data):
    assert len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe", "Expected a 64-bit little-endian Mach-O"
    _, cpu, subtype, kind, count, size, flags, _ = struct.unpack_from("<IiiIIIII", data)
    assert cpu == 0x0100000C, f"Expected arm64, got CPU {cpu:#x}"
    assert 32 + size <= len(data), "Truncated Mach-O load commands"
    result = {"architecture": "arm64", "file_type": kind, "libraries": [], "encrypted": False, "signature_bytes": 0}
    offset = 32
    for _ in range(count):
        cmd, length = struct.unpack_from("<II", data, offset)
        assert length >= 8 and offset + length <= 32 + size, "Invalid load command"
        if cmd == 0x32:
            platform, minimum, sdk, _ = struct.unpack_from("<IIII", data, offset + 8)
            result.update(platform=platform, minimum_ios=version(minimum), sdk=version(sdk))
        if cmd in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            assert name_offset < length
            result["libraries"].append(data[offset + name_offset:offset + length].split(b"\0", 1)[0].decode())
        if cmd == 0x1D:
            result["signature_bytes"] = struct.unpack_from("<II", data, offset + 8)[1]
        if cmd in (0x21, 0x2C):
            result["encrypted"] = struct.unpack_from("<I", data, offset + 16)[0] != 0
        offset += length
    assert offset == 32 + size
    assert result.get("platform") == 2, "Must be an iPhoneOS device binary, not a simulator"
    assert not result["encrypted"], "Encrypted App Store binaries cannot be re-signed this way"
    assert result["signature_bytes"] == 0, "Expected unsigned executable"
    return result


def verify(path, bundle_id):
    prefix = "Payload/MusicDL.app/"
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, "IPA ZIP integrity failure"
        names = set(archive.namelist())
        assert all(not name.startswith("/") and ".." not in pathlib.PurePosixPath(name).parts for name in names)
        apps = {name.split("/")[1] for name in names if name.startswith("Payload/") and len(name.split("/")) > 2}
        assert apps == {"MusicDL.app"}, f"Unexpected Payload contents: {apps}"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        assert info["CFBundleIdentifier"] == bundle_id
        assert info["CFBundleDisplayName"] == info["CFBundleName"] == "MusicDL"
        assert info["CFBundlePackageType"] == "APPL" and info["LSRequiresIPhoneOS"]
        assert "audio" in info["UIBackgroundModes"]
        assert info.get("NSAppleMusicUsageDescription")
        assert int(info["MinimumOSVersion"].split(".")[0]) >= 18
        assert "com.guohuiyuan.musicdl.spotify-login" in [scheme for entry in info.get("CFBundleURLTypes", []) for scheme in entry.get("CFBundleURLSchemes", [])]
        assert not any("/_CodeSignature/" in name or name.endswith("embedded.mobileprovision") for name in names), "Unexpected signature or provisioning profile"
        binary = archive.read(prefix + info["CFBundleExecutable"])
        executable = macho(binary)
        assert executable["file_type"] == 2, "Mach-O is not an executable"
        assert executable["minimum_ios"].split(".")[0] == info["MinimumOSVersion"].split(".")[0]
        resources = ["Assets.car", "LICENSE", "NOTICE.md", "ThirdPartyNotices.txt"]
        for resource in resources:
            assert len(archive.read(prefix + resource)) > 0, f"Missing resource: {resource}"
        for library in executable["libraries"]:
            if library.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if library.startswith("@rpath/libswift"):
                continue  # Swift runtime is provided by supported iOS versions.
            if library.startswith("@rpath/"):
                assert prefix + "Frameworks/" + library[len("@rpath/"):] in names, f"Missing embedded framework: {library}"
            else:
                raise AssertionError(f"Unexpected non-system library: {library}")
        frameworks = sorted(name for name in names if "/Frameworks/" in name and not name.endswith("/"))
        return {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size_bytes": path.stat().st_size,
            "bundle_id": info["CFBundleIdentifier"],
            "build": info["CFBundleVersion"],
            "version": info["CFBundleShortVersionString"],
            "minimum_ios": info["MinimumOSVersion"],
            "background_modes": info["UIBackgroundModes"],
            "signed": False,
            "executable": executable,
            "framework_files": frameworks,
            "resources_verified": resources,
            "device_installation_tested": False,
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=pathlib.Path)
    parser.add_argument("--bundle-id", default="com.guohuiyuan.musicdl.nativedesign")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    result = verify(args.ipa, args.bundle_id)
    output = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(output + "\n", encoding="utf-8")
    print(output)
