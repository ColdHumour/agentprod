#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("xray_vps", Path(__file__).resolve().parents[1] / "xray_vps.py")
release_asset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_asset)


def metadata():
    return {
        "tag_name": "v99.1.2",
        "draft": False,
        "prerelease": False,
        "assets": [
            {
                "name": "Xray-linux-64.zip",
                "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v99.1.2/Xray-linux-64.zip",
                "digest": "sha256:" + "a" * 64,
            },
            {
                "name": "Xray-linux-arm64-v8a.zip",
                "browser_download_url": "https://github.com/XTLS/Xray-core/releases/download/v99.1.2/Xray-linux-arm64-v8a.zip",
                "digest": "sha256:" + "b" * 64,
            },
        ],
    }


class ReleaseAssetTests(unittest.TestCase):
    def test_selects_architecture_and_digest(self):
        selected = release_asset.select_asset(metadata(), "amd64")
        self.assertEqual(selected[0], "v99.1.2")
        self.assertEqual(selected[1], "Xray-linux-64.zip")
        self.assertEqual(selected[3], "sha256:" + "a" * 64)

    def test_rejects_prerelease(self):
        value = metadata()
        value["prerelease"] = True
        with self.assertRaises(ValueError):
            release_asset.select_asset(value, "amd64")

    def test_rejects_missing_digest(self):
        value = metadata()
        value["assets"][0]["digest"] = None
        with self.assertRaises(ValueError):
            release_asset.select_asset(value, "amd64")

    def test_rejects_unofficial_url(self):
        value = metadata()
        value["assets"][0]["browser_download_url"] = "https://example.com/Xray-linux-64.zip"
        with self.assertRaises(ValueError):
            release_asset.select_asset(value, "amd64")

    def test_rejects_unsupported_architecture(self):
        with self.assertRaises(ValueError):
            release_asset.select_asset(metadata(), "riscv64")


if __name__ == "__main__":
    unittest.main(verbosity=2)
