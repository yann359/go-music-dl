"""Reject download/ZIP defects before delivering an IPA to a signing app."""
import importlib.util
import pathlib
import plistlib
import struct
import tempfile
import unittest
import warnings
import zipfile

SPEC = importlib.util.spec_from_file_location("verify_ipa", pathlib.Path(__file__).parents[1] / "scripts" / "verify-ipa.py")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)
BUNDLE = "com.guohuiyuan.musicdl.nativedesign"


class IPAVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = pathlib.Path(self.temporary.name) / "test.ipa"

    def fixture(self, compression=zipfile.ZIP_DEFLATED, duplicate=False, root="Payload/MusicDL.app/"):
        info = dict(CFBundleIdentifier=BUNDLE, CFBundleDisplayName="MusicDL", CFBundleName="MusicDL",
                    CFBundleExecutable="MusicDL", CFBundlePackageType="APPL", LSRequiresIPhoneOS=True,
                    UIBackgroundModes=["audio"], NSAppleMusicUsageDescription="Test", MinimumOSVersion="18.0",
                    CFBundleVersion="1", CFBundleShortVersionString="1.0.0",
                    CFBundleURLTypes=[dict(CFBundleURLSchemes=["com.guohuiyuan.musicdl.spotify-login"])])
        # A minimal structural device Mach-O fixture, never delivered as an app.
        binary = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        binary += struct.pack("<6I", 0x32, 24, 2, 18 << 16, (26 << 16) | (5 << 8), 0)
        with zipfile.ZipFile(self.path, "w", compression=compression) as archive:
            archive.writestr(root + "Info.plist", plistlib.dumps(info))
            archive.writestr(root + "MusicDL", binary)
            for resource in ["Assets.car", "LICENSE", "NOTICE.md", "ThirdPartyNotices.txt"]:
                archive.writestr(root + resource, b"fixture-resource")
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(root + "Info.plist", plistlib.dumps(info))

    def test_complete_standard_payload_passes(self):
        self.fixture()
        result = VERIFIER.verify(self.path, BUNDLE)
        self.assertTrue(result["archive"]["zip_crc_verified"])
        self.assertEqual(result["archive"]["payload_app"], "Payload/MusicDL.app")

    def test_truncated_download_is_rejected(self):
        self.fixture()
        self.path.write_bytes(self.path.read_bytes()[:-12])
        with self.assertRaises((AssertionError, zipfile.BadZipFile)):
            VERIFIER.verify(self.path, BUNDLE)

    def test_html_saved_with_ipa_suffix_is_rejected(self):
        self.path.write_bytes(b"<!doctype html><title>Sign in to download</title>")
        with self.assertRaisesRegex(AssertionError, "HTML"):
            VERIFIER.verify(self.path, BUNDLE)

    def test_duplicate_paths_are_rejected(self):
        self.fixture(duplicate=True)
        with self.assertRaisesRegex(AssertionError, "Duplicate"):
            VERIFIER.verify(self.path, BUNDLE)

    def test_wrong_payload_root_is_rejected(self):
        self.fixture(root="MusicDL.app/")
        with self.assertRaisesRegex(AssertionError, "Payload"):
            VERIFIER.verify(self.path, BUNDLE)

    def test_incompatible_zip_compression_is_rejected(self):
        self.fixture(compression=zipfile.ZIP_BZIP2)
        with self.assertRaisesRegex(AssertionError, "compression"):
            VERIFIER.verify(self.path, BUNDLE)

    def test_trailing_download_data_is_rejected(self):
        self.fixture()
        self.path.write_bytes(self.path.read_bytes() + b"download failure")
        with self.assertRaisesRegex(AssertionError, "trailing"):
            VERIFIER.verify(self.path, BUNDLE)


if __name__ == "__main__":
    unittest.main()
