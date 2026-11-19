import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "release-manifest.py"


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


class ReleaseManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.stage3 = self.root / "zignos-stage3-test-r12-x86_64.tar.xz"
        self.stage3.write_bytes(b"stage3-data")
        self.db = self.root / "db"
        self._pkg("app", "1.0", 0, "core")
        self._pkg("tool", "2.0", 3, "main")
        self._pkg("zpkg", "0.2.0", 0, "core")
        self.recipes = self.root / "recipes"
        self._recipe("stable", "core", "linux", "7.1.8", 4)
        self._recipe("stable", "core", "grub", "2.14", 2)
        self._recipe("stable", "core", "app", "1.0", 0)
        self._recipe("stable", "main", "tool", "2.0", 0)
        for ch in ("testing", "unstable"):
            self._recipe(ch, "core", "app", "1.0", 0)
            self._recipe(ch, "main", "tool", "2.0", 0)
        self.base_list = self.root / "base.list"
        self.base_list.write_text("# comment\nlinux\ngrub\napp\n", encoding="utf-8")
        self.recipes_artifact = self.root / "zignos-recipes-test.tar.xz"
        self.recipes_artifact.write_bytes(b"recipes-data")
        self.boot = self.root / "boot-tests.json"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _pkg(self, name: str, version: str, revision: int, category: str) -> None:
        d = self.db / name
        d.mkdir(parents=True, exist_ok=True)
        meta = {
            "schema": 2, "name": name, "version": version,
            "revision": revision, "slot": "0",
            "repo": f"/recipes/stable/{category}",
        }
        (d / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
        (d / "version").write_text(version, encoding="utf-8")

    def _recipe(self, channel: str, category: str, name: str, version: str, revision: int) -> None:
        d = self.recipes / channel / category / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "version").write_text(version + "\n", encoding="utf-8")
        (d / "revision").write_text(str(revision) + "\n", encoding="utf-8")

    def generate(self) -> Path:
        out = self.root / "release.json"
        res = run(
            "generate",
            "--release", "2026.11.19-alpha",
            "--revision", "r12",
            "--channel", "stable",
            "--stage3", str(self.stage3),
            "--db-root", str(self.db),
            "--recipes", str(self.recipes),
            "--base-list", str(self.base_list),
            "--base-closure", "60",
            "--boot-tests", str(self.boot),
            "--artifact", f"recipes={self.recipes_artifact}",
            "--commit", "zignos=abc",
            "--commit", "zpkg=def",
            "--commit", "recipes=ghi",
            "--commit", "build=jkl",
            "--out", str(out),
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        return out

    def test_generate_and_validate(self) -> None:
        out = self.generate()
        data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(data["schema"], 1)
        self.assertEqual(data["release"], "2026.11.19-alpha")
        self.assertEqual(data["channel"], "stable")
        self.assertEqual(data["stage3"]["revision"], "r12")
        self.assertEqual(data["stage3"]["package_count"], 3)
        self.assertEqual(len(data["stage3"]["packages"]), 3)
        self.assertEqual(data["stage3"]["packages"][0]["name"], "app")
        self.assertEqual(data["stage3"]["packages"][2]["name"], "zpkg")
        self.assertEqual(data["kernel"]["version"], "7.1.8")
        self.assertEqual(data["kernel"]["revision"], 4)
        self.assertFalse(data["kernel"]["in_stage3"])
        self.assertEqual(data["bootloader"]["version"], "2.14")
        self.assertEqual(data["base"], {"top_level": 3, "closure": 60})
        self.assertEqual(data["recipes"]["channels"]["stable"]["core"], 3)
        self.assertEqual(data["recipes"]["total"], 8)
        self.assertEqual(data["recipes"]["per_channel"], 4)
        self.assertEqual(data["boot"]["bios"], "not-tested")
        self.assertEqual(data["source"]["zignos"]["commit"], "abc")
        self.assertFalse(data["source"]["zignos"]["dirty"])
        self.assertEqual(data["artifacts"][0]["name"], "stage3")
        self.assertEqual({a["name"] for a in data["artifacts"]}, {"stage3", "recipes"})
        res = run("validate", str(out))
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_record_boot(self) -> None:
        res = run("record-boot", "--file", str(self.boot), "--mode", "bios",
                  "--result", "passed", "--kernel", "7.1.8", "--image", "test.img")
        self.assertEqual(res.returncode, 0, res.stderr)
        res = run("record-boot", "--file", str(self.boot), "--mode", "uefi",
                  "--result", "failed", "--kernel", "7.1.8", "--image", "test.img")
        self.assertEqual(res.returncode, 0, res.stderr)
        out = self.generate()
        data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(data["boot"]["bios"], "passed")
        self.assertEqual(data["boot"]["uefi"], "failed")
        self.assertEqual(data["boot"]["hardware"], "not-tested")
        self.assertIsNotNone(data["boot"]["checked"])

    def test_legacy_database_entry(self) -> None:
        # Databases written before schema 2 only have version (and maybe
        # revision/slot) files; category comes from the recipe tree.
        d = self.db / "legacy"
        d.mkdir()
        (d / "version").write_text("3.1\n", encoding="utf-8")
        (d / "revision").write_text("2\n", encoding="utf-8")
        self._recipe("stable", "main", "legacy", "3.1", 2)
        out = self.generate()
        data = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(data["stage3"]["package_count"], 4)
        pkg = next(p for p in data["stage3"]["packages"] if p["name"] == "legacy")
        self.assertEqual(pkg, {"name": "legacy", "version": "3.1",
                               "revision": 2, "slot": "0", "category": "main"})

    def test_validate_rejects_count_mismatch(self) -> None:
        out = self.generate()
        data = json.loads(out.read_text(encoding="utf-8"))
        data["stage3"]["package_count"] = 99
        out.write_text(json.dumps(data), encoding="utf-8")
        res = run("validate", str(out))
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("package_count", res.stderr)


if __name__ == "__main__":
    unittest.main()
