"""Validate committed artwork/configuration and exercise Apple's PNG renderer on macOS."""
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]
SOURCE = IOS / "Branding/nice-logo.webp"
ASSETS = IOS / "NiceVideos/Assets.xcassets"
RENDERER = IOS / "tools/render_app_icon.swift"


def render(source, destination):
    return subprocess.run(
        ["xcrun", "swift", str(RENDERER), str(source), str(destination)],
        text=True, capture_output=True, timeout=120,
    )


class AppIconSourceTests(unittest.TestCase):
    def test_committed_artwork_is_the_approved_logo(self):
        data = SOURCE.read_bytes()
        self.assertEqual(data[:4], b"RIFF")
        self.assertEqual(data[8:12], b"WEBP")
        self.assertEqual(len(data), struct.unpack("<I", data[4:8])[0] + 8)
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         "545bbf9fb3a7ab640332909212726f1729930df7b4fc04113160795304e49b85")

    def test_single_size_app_icon_manifest(self):
        catalog = json.loads((ASSETS / "Contents.json").read_text())
        self.assertEqual(catalog["info"]["version"], 1)
        icon = json.loads((ASSETS / "AppIcon.appiconset/Contents.json").read_text())
        self.assertEqual(icon["images"], [{"filename": "AppIcon-1024.png", "idiom": "universal",
                                          "platform": "ios", "size": "1024x1024"}])

    def test_setup_generates_before_xcodegen(self):
        setup = (IOS / "setup.sh").read_text()
        self.assertLess(setup.index("xcrun swift tools/render_app_icon.swift"),
                        setup.index("xcodegen generate"))
        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon", (IOS / "project.yml").read_text())


@unittest.skipUnless(sys.platform == "darwin", "Native ImageIO rendering requires macOS.")
class AppIconRendererTests(unittest.TestCase):
    def test_native_output_is_opaque_1024_png_and_reproducible(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "nested/AppIcon-1024.png"
            result = render(SOURCE, output)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            data = output.read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", data[16:24]), (1024, 1024))
            self.assertEqual(data[24:26], bytes([8, 2]))
            offset = 8
            while offset < len(data):
                size = struct.unpack(">I", data[offset:offset + 4])[0]
                self.assertNotEqual(data[offset + 4:offset + 8], b"tRNS")
                offset += size + 12
            mtime = output.stat().st_mtime_ns
            again = render(SOURCE, output)
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertEqual(output.read_bytes(), data)
            self.assertEqual(output.stat().st_mtime_ns, mtime)

    def test_invalid_source_keeps_existing_icon(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "broken.webp"
            source.write_bytes(b"not an image")
            output = Path(directory) / "AppIcon.png"
            output.write_bytes(b"existing-icon")
            result = render(source, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), b"existing-icon")

    def test_refuses_to_overwrite_the_source_artwork(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "logo.webp"
            original = SOURCE.read_bytes()
            source.write_bytes(original)
            result = render(source, source)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
