"""Verify bundled offline resources without network access or extra packages."""
import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, help="Windows release directory to verify as well")
    parser.add_argument("--apk", type=Path, help="Android APK to verify as well")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / "tool/offline_assets_manifest.json").read_text(encoding="utf-8"))
    bases = [root]
    if args.release:
        bases.append(args.release.resolve() / "data/flutter_assets")
    problems = []
    native = manifest.get("android_native_libraries", [])
    windows_native = manifest.get("windows_native_files", [])
    for entry in windows_native:
        paths = [root / entry["path"]]
        if args.release:
            paths.append(args.release.resolve() / entry["release_path"])
        for file in paths:
            if (not file.is_file() or file.stat().st_size != entry["bytes"]
                    or digest(file) != entry["sha256"]):
                problems.append(f"Windows native file mismatch: {file}")
    for entry in native:
        file = root / entry["path"]
        if not file.is_file() or digest(file) != entry["sha256"]:
            problems.append(f"Native library mismatch: {file}")
    for base in bases:
        for entry in manifest["files"]:
            file = base / entry["path"]
            if not file.is_file():
                problems.append(f"Missing: {file}")
            elif file.stat().st_size != entry["bytes"] or digest(file) != entry["sha256"]:
                problems.append(f"Integrity mismatch: {file}")
    if args.apk:
        with ZipFile(args.apk) as apk:
            # Flutter's universal APK targets ARM32, ARM64 and x86-64. The
            # separately built x86-32 engine is kept in source for native use.
            packaged_abis = {n.split('/')[1] for n in apk.namelist()
                             if n.startswith('lib/') and n.endswith('/libapp.so')}
            entries = [("assets/flutter_assets/" + e["path"], e) for e in manifest["files"]]
            entries += [("lib/" + e["path"].split("jniLibs/")[1], e) for e in native
                        if e["path"].split("jniLibs/")[1].split('/')[0] in packaged_abis]
            for name, entry in entries:
                try:
                    with apk.open(name) as stream:
                        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
                    if checksum != entry["sha256"]:
                        problems.append(f"APK integrity mismatch: {name}")
                except KeyError:
                    problems.append(f"Missing from APK: {name}")
    if problems:
        raise SystemExit("\n".join(problems))
    print(f"Verified {len(manifest['files'])} offline resources in {len(bases) + bool(args.apk)} location(s), {len(native)} Android native libraries and {len(windows_native)} Windows native files; no network used.")


if __name__ == "__main__":
    main()
