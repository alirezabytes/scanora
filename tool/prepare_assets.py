"""Fetch verified upstream assets or copy a pinned resource set from a local Scanora checkout."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parent.parent
TESSDATA = "https://raw.githubusercontent.com/tesseract-ocr"
SPEECH = (
    "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/"
    "8f3c18b358db4d1f2fc1eae49d75cd20989e4309"
)
BASE_SPEECH = (
    "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/"
    "bb53ee204431c90d314c1cc08d28d23e5b7927cc"
)
OCR_MODELS = {
    "arabic_PP-OCRv5_mobile_rec.onnx": (
        "https://huggingface.co/PaddlePaddle/arabic_PP-OCRv5_mobile_rec_onnx/resolve/"
        "14aaedcd75825982689ecf5cd64ab33ee083215a/inference.onnx"
    ),
    "en_PP-OCRv5_mobile_rec.onnx": (
        "https://huggingface.co/PaddlePaddle/en_PP-OCRv5_mobile_rec_onnx/resolve/"
        "3fafbc3b5dcf93dd72add9f48368be8a3a2cd33b/inference.onnx"
    ),
    "ddddocr_common_old.onnx": (
        "https://raw.githubusercontent.com/sml2h3/ddddocr/"
        "f0ee6b122e9f6b4ccc0cd96032f93cd43721543f/ddddocr/common_old.onnx"
    ),
}
FIXTURE = {
    "path": "test/fixtures/audio/english_reference.wav",
    "bytes": 212044,
    "sha256": "6bc58a4efdf20daac252b6b1502632601a71efe0308f6757dc1eda34891a7e4f",
}
BUS_FIXTURE = {
    "path": "test/fixtures/vision_bus.jpg",
    "bytes": 137419,
    "sha256": "c02019c4979c191eb739ddd944445ef408dad5679acab6fd520ef9d434bfbc63",
}
TESSERACT_ANDROID = {
    "path": "android/app/libs/tesseract4android-release.aar",
    "bytes": 12848454,
    "sha256": "bce5d6413a1a5ae3d7240033fbbc851ba3217d0a08d9769400e17a077f42cb2a",
}


def verified(path, entry):
    if not path.is_file() or path.stat().st_size != entry["bytes"]:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == entry["sha256"]


def copy_verified(entry, *, source=None, url=None):
    destination = ROOT / entry["path"]
    if verified(destination, entry):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as staging:
        stage = Path(staging.name)
    try:
        if source is not None:
            path = source / entry["path"]
            if not verified(path, entry):
                raise SystemExit(f"Missing or mismatched source file: {path}")
            shutil.copyfile(path, stage)
        else:
            with urlopen(url, timeout=60) as response, stage.open("wb") as output:
                shutil.copyfileobj(response, output)
        if not verified(stage, entry):
            raise SystemExit(f"Integrity check failed for {entry['path']}")
        stage.replace(destination)
        print(f"Prepared {entry['path']}")
    finally:
        stage.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    options = parser.add_mutually_exclusive_group()
    options.add_argument("--from-local", type=Path, help="Path to a local full Scanora source checkout")
    options.add_argument("--speech", action="store_true", help="Also fetch the large Whisper weights")
    options.add_argument("--android-library", action="store_true", help="Fetch only the Android Tesseract library")
    args = parser.parse_args()
    if args.android_library:
        copy_verified(
            TESSERACT_ANDROID,
            url="https://jitpack.io/cz/adaptech/tesseract4android/tesseract4android/4.9.0/tesseract4android-4.9.0.aar",
        )
        return
    manifest = json.loads((ROOT / "tool/offline_assets_manifest.json").read_text(encoding="utf-8"))
    if args.from_local:
        source = args.from_local.resolve()
        if source == ROOT:
            parser.error("--from-local must point to the full source checkout")
        entries = (
            manifest["files"] + manifest["android_native_libraries"]
            + manifest["windows_native_files"] + [FIXTURE, BUS_FIXTURE]
        )
        for entry in entries:
            copy_verified(entry, source=source)
        for path in ("windows/tesseract", "windows/espeak-ng"):
            shutil.copytree(source / path, ROOT / path, dirs_exist_ok=True)
        aar = "android/app/libs/tesseract4android-release.aar"
        (ROOT / aar).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / aar, ROOT / aar)
        print("Prepared the local full runtime.")
        return

    for entry in manifest["files"]:
        path = Path(entry["path"])
        if path.suffix == ".traineddata":
            family = "tessdata_fast" if path.parent.name == "tessdata" else "tessdata_best"
            copy_verified(entry, url=f"{TESSDATA}/{family}/4.1.0/{path.name}")
        elif path.name in OCR_MODELS:
            copy_verified(entry, url=OCR_MODELS[path.name])
        elif args.speech and path.name == "silero_vad.onnx":
            copy_verified(
                entry,
                url="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
            )
        elif args.speech and path.parent.name in ("whisper", "whisper_small"):
            small = path.parent.name == "whisper_small"
            base = SPEECH if small else BASE_SPEECH
            prefix = "small" if small else "base"
            copy_verified(entry, url=f"{base}/{prefix}-{path.name}")
    copy_verified(FIXTURE, url=f"{SPEECH}/test_wavs/0.wav")
    copy_verified(BUS_FIXTURE, url="https://ultralytics.com/images/bus.jpg")
    print("Prepared the available upstream resources.")


if __name__ == "__main__":
    main()
