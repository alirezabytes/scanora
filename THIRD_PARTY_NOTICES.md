# Third-party notices

The repository license covers original Scanora code. Other software, fonts, test media and model weights retain their upstream terms. The resource script checks pinned file sizes and SHA-256 values recorded in [the offline resource manifest](tool/offline_assets_manifest.json). Verify provenance and the applicable redistribution terms before packaging binaries or weights.

| Component | Source and terms |
| --- | --- |
| Flutter and Dart dependencies | Versions are in [pubspec.lock](pubspec.lock). Package licenses remain in force. |
| Syncfusion Flutter PDF | [Syncfusion terms](https://help.syncfusion.com/flutter/licensing/overview) apply. Obtain the appropriate license from Syncfusion. |
| Tesseract and Tesseract4Android | [Tesseract OCR](https://github.com/tesseract-ocr/tesseract), [fast data](https://github.com/tesseract-ocr/tessdata_fast), [best data](https://github.com/tesseract-ocr/tessdata_best) and [Tesseract4Android](https://github.com/adaptech-cz/Tesseract4Android) use Apache 2.0. Native distributions also contain dependencies with separate terms. |
| eSpeak NG and Sonic | [eSpeak NG](https://github.com/espeak-ng/espeak-ng) uses GPL 3 or later. [Sonic](https://github.com/waywardgeek/sonic) uses Apache 2.0. See the copies under [assets/licenses](assets/licenses) and source revisions in [Android](tool/espeak_android_build.json) and [Windows](tool/espeak_windows_build.json) build metadata. |
| Vazirmatn | [Upstream font release](https://github.com/rastikerdar/vazirmatn/releases/tag/v33.003) and the included [SIL Open Font License](assets/fonts/OFL.txt). |
| PaddleOCR and handwriting models | [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) and the exact upstream model references in the asset manifest. The two included PP-OCRv5 dictionaries come from the pinned model configuration files and retain their Apache 2.0 terms. The Bina model was converted to ONNX in Scanora's full build. See its [model notice](assets/licenses/bina-rizehpizeh.txt). |
| ddddocr | [Upstream source](https://github.com/sml2h3/ddddocr). Refer to the upstream terms for model files and character data. |
| Whisper and voice activity detection | [Whisper](https://github.com/openai/whisper), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), [Silero VAD](https://github.com/snakers4/silero-vad), and the pinned model and test sample references in the asset manifest and [audio fixture note](test/fixtures/audio/SOURCE.txt). |
| Ultralytics YOLO | [Ultralytics model license information](https://www.ultralytics.com/license). The weights are separate from this source checkout. |
| Android Google libraries and optional cloud providers | Provider terms apply to the respective SDKs and online services. Scanora's [privacy policy](privacy.html) describes what is sent to a chosen provider. |

## Preparing the remaining resources

- Fetch the resources supported by `python tool/prepare_assets.py`. The manifest records where the full build expects other model weights, dictionaries and audio files, and which revisions are known.
- The current snapshot omits the remaining ONNX assets, original page-turn audio and bundled native engines. Some models used by the full build are local conversions. The manifest is an integrity reference and does not provide a public download for every converted file.
- To build the eSpeak libraries, check out [eSpeak NG at the pinned revision](https://github.com/espeak-ng/espeak-ng/tree/ba90c8e9f440ad544f674a790bb5f53878b6ffc5). Use `tool/build_espeak_android.ps1 -SourceDirectory PATH -NdkDirectory PATH -CmakeExecutable PATH`. For Windows, also check out [Sonic at the pinned revision](https://github.com/waywardgeek/sonic/tree/fbf75c3d6d846bad3bb3d456cbc5d07d9fd8c104) and use `tool/build_espeak_windows.ps1 -SourceDirectory PATH -SonicDirectory PATH -CmakeExecutable PATH`. Supply your local tool paths in place of `PATH`.
