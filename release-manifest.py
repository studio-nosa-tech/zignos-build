#!/usr/bin/env python3
"""Generate and update ZIGNOS release manifests.

The manifest is the single machine-readable source for release data consumed
by the website, download page, release notes and install guide.

Usage:
  release-manifest.py generate --release NAME --revision rN --channel stable \
      --stage3 FILE --db-root DIR --recipes DIR --base-list FILE \
      --base-closure N --source-root DIR --artifact recipes=FILE \
      --out FILE
  release-manifest.py record-boot --file FILE --mode bios|uefi|hardware \
      --result passed|failed|not-tested [--kernel V] [--image FILE]
  release-manifest.py validate FILE

Only the Python 3 standard library is used.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA = 1
CHANNELS = ("stable", "testing", "unstable")
CATEGORIES = ("core", "main", "desktop")
BOOT_MODES = ("bios", "uefi", "hardware")
BOOT_RESULTS = ("passed", "failed", "not-tested")


def utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def file_info(path: Path) -> dict:
    stat = path.stat()
    return {
        "filename": path.name,
        "size": stat.st_size,
        "sha256": sha256_file(path),
    }


def size_mib(size: int) -> int:
    return (size + 1024 * 1024 - 1) // (1024 * 1024)


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def read_kv_file(path: Path) -> dict:
    """Read one-key-per-line files used by recipes (version, revision)."""
    if not path.is_file():
        return {}
    lines = [ln.strip() for ln in path.read_text(encoding="utf-8").splitlines()]
    lines = [ln for ln in lines if ln and not ln.startswith("#")]
    return {"value": lines[0]} if lines else {}


def recipe_version(recipes: Path, channel: str, category: str, name: str) -> dict | None:
    d = recipes / channel / category / name
    if not d.is_dir():
        return None
    version = read_kv_file(d / "version").get("value")
    if not version:
        return None
    rev_raw = read_kv_file(d / "revision").get("value", "0")
    try:
        revision = int(rev_raw)
    except ValueError:
        revision = 0
    return {"package": name, "version": version, "revision": revision}


def package_category(meta: dict, recipes: Path, channel: str, name: str) -> str:
    repo = (meta.get("repo") or "").rstrip("/")
    base = os.path.basename(repo)
    if base in CATEGORIES:
        return base
    # Databases written before schema 2 have no meta.json. Look the package
    # up in the channel tree instead.
    for cat in CATEGORIES:
        if (recipes / channel / cat / name).is_dir():
            return cat
    return ""


def read_packages(db_root: Path, recipes: Path, channel: str) -> list[dict]:
    packages = []
    if not db_root.is_dir():
        return packages
    for entry in sorted(db_root.iterdir()):
        if not entry.is_dir() or entry.name.startswith("."):
            continue
        meta = {}
        meta_path = entry / "meta.json"
        if meta_path.is_file():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                meta = {}
        name = meta.get("name") or entry.name
        version = str(meta.get("version", "") or "")
        if not version:
            version = read_kv_file(entry / "version").get("value", "")
        # A directory without a version is not an installed package.
        if not version:
            continue
        revision = meta.get("revision")
        if revision is None:
            raw = read_kv_file(entry / "revision").get("value", "0")
            try:
                revision = int(raw)
            except ValueError:
                revision = 0
        slot = str(meta.get("slot", "") or "")
        if not slot:
            slot = read_kv_file(entry / "slot").get("value", "0")
        pkg = {
            "name": name,
            "version": version,
            "revision": int(revision or 0),
            "slot": slot,
        }
        cat = package_category(meta, recipes, channel, name)
        if cat:
            pkg["category"] = cat
        packages.append(pkg)
    packages.sort(key=lambda p: (p["name"], p["slot"]))
    return packages


def count_recipes(recipes: Path) -> tuple[dict, int, int]:
    channels = {}
    per_channel = None
    total = 0
    for ch in CHANNELS:
        counts = {}
        ch_total = 0
        for cat in CATEGORIES:
            d = recipes / ch / cat
            n = 0
            if d.is_dir():
                for pkg in d.iterdir():
                    if pkg.is_dir() and (pkg / "version").is_file():
                        n += 1
            counts[cat] = n
            ch_total += n
        if ch_total:
            channels[ch] = counts
            total += ch_total
            if per_channel is None:
                per_channel = ch_total
    return channels, per_channel or 0, total


def base_top_level(path: Path | None) -> int | None:
    if path is None or not path.is_file():
        return None
    n = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            n += 1
    return n


def git_info(path: Path) -> dict:
    if not path.is_dir():
        return {"commit": "", "dirty": False}
    def run(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-c", "safe.directory=*", "-C", str(path), *args],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
    commit = ""
    res = run("rev-parse", "HEAD")
    if res.returncode == 0:
        commit = res.stdout.strip()
    dirty = False
    res = run("status", "--porcelain")
    if res.returncode == 0:
        dirty = bool(res.stdout.strip())
    return {"commit": commit, "dirty": dirty}


def parse_pairs(values: list[str], what: str) -> dict:
    out = {}
    for v in values or []:
        if "=" not in v:
            raise SystemExit(f"{what} must be name=value: {v}")
        k, val = v.split("=", 1)
        out[k] = val
    return out


def load_boot_tests(path: Path | None) -> dict:
    result = {mode: "not-tested" for mode in BOOT_MODES}
    checked = None
    if path is None or not path.is_file():
        return {**result, "checked": checked}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {**result, "checked": checked}
    for mode in BOOT_MODES:
        entry = data.get(mode)
        if isinstance(entry, str):
            result[mode] = entry
        elif isinstance(entry, dict):
            value = entry.get("result", "not-tested")
            if value in BOOT_RESULTS:
                result[mode] = value
            if entry.get("checked"):
                checked = entry["checked"] if checked is None else max(checked, entry["checked"])
    return {**result, "checked": checked}


def generate(args: argparse.Namespace) -> dict:
    stage3 = Path(args.stage3)
    if not stage3.is_file():
        raise SystemExit(f"stage3 not found: {stage3}")
    db_root = Path(args.db_root)
    recipes = Path(args.recipes)
    if not recipes.is_dir():
        raise SystemExit(f"recipes not found: {recipes}")

    stage_info = file_info(stage3)
    packages = read_packages(db_root, recipes, args.channel)
    channels, per_channel, total = count_recipes(recipes)

    zpkg_ver = ""
    zpkg_meta = db_root / "zpkg" / "meta.json"
    if zpkg_meta.is_file():
        try:
            zpkg_ver = str(json.loads(zpkg_meta.read_text(encoding="utf-8")).get("version", ""))
        except (OSError, json.JSONDecodeError):
            pass
    if not zpkg_ver:
        zpkg_ver = read_kv_file(db_root / "zpkg" / "version").get("value", "")

    kernel = recipe_version(recipes, args.channel, "core", "linux")
    bootloader = recipe_version(recipes, args.channel, "core", "grub")
    if kernel:
        kernel["in_stage3"] = any(p["name"] == "linux" for p in packages)
    if bootloader:
        bootloader["in_stage3"] = any(p["name"] == "grub" for p in packages)

    artifacts = [{"name": "stage3", **stage_info}]
    recipes_info = None
    for name, file in parse_pairs(args.artifact, "--artifact").items():
        p = Path(file)
        if not p.is_file():
            raise SystemExit(f"artifact {name} not found: {p}")
        info = file_info(p)
        artifacts.append({"name": name, **info})
        if name == "recipes":
            recipes_info = info

    sources = {}
    source_repos = parse_pairs(args.source_repo, "--source-repo")
    for name in ("zignos", "zpkg", "recipes", "build"):
        if name in source_repos:
            sources[name] = git_info(Path(source_repos[name]))
        elif args.source_root:
            sources[name] = git_info(Path(args.source_root) / ("zignos-build" if name == "build" else name))
        else:
            sources[name] = {"commit": "", "dirty": False}
    for name, commit in parse_pairs(args.commit, "--commit").items():
        sources.setdefault(name, {"commit": "", "dirty": False})
        sources[name]["commit"] = commit
        sources[name].setdefault("dirty", False)

    top = base_top_level(Path(args.base_list)) if args.base_list else None
    data = {
        "schema": SCHEMA,
        "release": args.release,
        "channel": args.channel,
        "availability": args.availability,
        "generated": utc_now(),
        "build_date": args.build_date or _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d"),
        "stage3": {
            "revision": args.revision,
            **stage_info,
            "size_mib": size_mib(stage_info["size"]),
            "package_count": len(packages),
            "packages": packages,
        },
        "zpkg": {"version": zpkg_ver},
        "kernel": kernel or {"package": "linux", "version": "", "revision": 0, "in_stage3": False},
        "bootloader": bootloader or {"package": "grub", "version": "", "revision": 0, "in_stage3": False},
        "base": {"top_level": top, "closure": args.base_closure},
        "recipes": {
            "filename": (recipes_info or {}).get("filename", ""),
            "size": (recipes_info or {}).get("size", 0),
            "sha256": (recipes_info or {}).get("sha256", ""),
            "per_channel": per_channel,
            "total": total,
            "channels": channels,
        },
        "boot": load_boot_tests(Path(args.boot_tests) if args.boot_tests else None),
        "source": sources,
        "artifacts": artifacts,
    }
    return data


def cmd_generate(args: argparse.Namespace) -> int:
    data = generate(args)
    write_json(Path(args.out), data)
    print(f"wrote {args.out}")
    return 0


def record_boot(path: Path, mode: str, result: str, kernel: str, image: str, log: str) -> None:
    if mode not in BOOT_MODES:
        raise SystemExit(f"invalid boot mode: {mode}")
    if result not in BOOT_RESULTS:
        raise SystemExit(f"invalid boot result: {result}")
    data = {}
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}
    entry = {
        "result": result,
        "checked": utc_now(),
    }
    if kernel:
        entry["kernel"] = kernel
    if image:
        entry["image"] = os.path.basename(image)
    if log:
        entry["log"] = log
    data[mode] = entry
    write_json(path, data)


def cmd_record_boot(args: argparse.Namespace) -> int:
    record_boot(Path(args.file), args.mode, args.result, args.kernel or "", args.image or "", args.log or "")
    print(f"recorded {args.mode}={args.result} in {args.file}")
    return 0


def validate(data: dict) -> list[str]:
    errors = []
    if data.get("schema") != SCHEMA:
        errors.append(f"schema must be {SCHEMA}")
    for key in ("release", "channel", "generated", "build_date"):
        if not isinstance(data.get(key), str) or not data[key]:
            errors.append(f"{key} is required")
    stage3 = data.get("stage3") or {}
    for key in ("revision", "filename", "sha256"):
        if not isinstance(stage3.get(key), str) or not stage3[key]:
            errors.append(f"stage3.{key} is required")
    if not isinstance(stage3.get("size"), int) or stage3["size"] <= 0:
        errors.append("stage3.size must be a positive integer")
    packages = stage3.get("packages")
    if not isinstance(packages, list):
        errors.append("stage3.packages must be a list")
    elif stage3.get("package_count") != len(packages):
        errors.append(f"package_count {stage3.get('package_count')} != packages {len(packages)}")
    for key in ("zpkg", "kernel", "bootloader", "base", "recipes", "boot", "source"):
        if not isinstance(data.get(key), dict):
            errors.append(f"{key} must be an object")
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        errors.append("artifacts must be a non-empty list")
    else:
        for a in artifacts:
            if not a.get("name") or not a.get("filename"):
                errors.append("artifact name/filename is required")
            sha = a.get("sha256", "")
            if len(sha) != 64:
                errors.append(f"artifact {a.get('name')} sha256 is invalid")
    if len((data.get("stage3") or {}).get("sha256", "")) != 64:
        errors.append("stage3.sha256 is invalid")
    return errors


def cmd_validate(args: argparse.Namespace) -> int:
    try:
        data = json.loads(Path(args.file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"{args.file}: {exc}", file=sys.stderr)
        return 1
    errors = validate(data)
    if errors:
        for e in errors:
            print(f"{args.file}: {e}", file=sys.stderr)
        return 1
    print(f"{args.file}: valid")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="ZIGNOS release manifest generator")
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="generate a release manifest")
    gen.add_argument("--release", required=True)
    gen.add_argument("--revision", required=True)
    gen.add_argument("--channel", default="stable")
    gen.add_argument("--availability", default="coming-soon")
    gen.add_argument("--stage3", required=True)
    gen.add_argument("--db-root", required=True)
    gen.add_argument("--recipes", required=True)
    gen.add_argument("--base-list")
    gen.add_argument("--base-closure", type=int)
    gen.add_argument("--source-root")
    gen.add_argument("--source-repo", action="append", default=[])
    gen.add_argument("--commit", action="append", default=[])
    gen.add_argument("--boot-tests")
    gen.add_argument("--artifact", action="append", default=[])
    gen.add_argument("--build-date")
    gen.add_argument("--out", required=True)
    gen.set_defaults(func=cmd_generate)

    boot = sub.add_parser("record-boot", help="record a qemu boot test result")
    boot.add_argument("--file", required=True)
    boot.add_argument("--mode", required=True)
    boot.add_argument("--result", required=True)
    boot.add_argument("--kernel")
    boot.add_argument("--image")
    boot.add_argument("--log")
    boot.set_defaults(func=cmd_record_boot)

    val = sub.add_parser("validate", help="validate a release manifest")
    val.add_argument("file")
    val.set_defaults(func=cmd_validate)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
