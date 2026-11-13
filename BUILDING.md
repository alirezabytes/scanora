# Build and test Scanora

Use Flutter 3.47.7 or a compatible version and Python 3.11 or newer for the resource scripts. Run commands from the repository root.

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub test/reading_layout_and_color_test.dart test/document_processing_test.dart test/google_configuration_test.dart test/online_access_test.dart
```

These checks do not require cloud accounts or camera hardware. The full suite includes tests that require real recognition models and native engines. See the resource instructions before running it.

## Prepare offline OCR

```powershell
python tool/prepare_assets.py
```

This downloads and checks the exact Tesseract language data, selected model files and sample fixtures. Pass `--speech` to also download the Whisper weights (about 535 MB). See [third-party notices](THIRD_PARTY_NOTICES.md) for the remaining assets. Engine-backed functions require their corresponding models, native libraries or optional online provider.

## Windows

Install Visual Studio with the Desktop development with C++ workload and Windows SDK. For offline OCR, install [Tesseract 5 for Windows](https://tesseract-ocr.github.io/tessdoc/Installation.html) in its default location, or put the engine and its required DLLs in `windows/tesseract/`. For offline speech, install [eSpeak NG](https://github.com/espeak-ng/espeak-ng/releases) in its default location, or put it and its data in `windows/espeak-ng/`.

```powershell
flutter build windows --debug --no-pub
flutter run -d windows --no-pub
```

Keep the generated Windows executable with its DLLs and `data/` folder.

## Android

Set up the Android SDK, a JDK 17 or newer compatible with the Android Gradle plugin, and Android NDK `28.2.13676358`. Use `flutter doctor -v` to check the toolchain. Flutter generates the Gradle wrapper files and local SDK settings. The Gradle build can resolve Tesseract4Android from JitPack. It also accepts a locally built AAR at `android/app/libs/tesseract4android-release.aar`.

If Gradle has trouble reaching JitPack, use `python tool/prepare_assets.py --android-library` to download and verify the same upstream library separately.

```powershell
flutter build apk --debug --no-pub
flutter devices
flutter run -d DEVICE_ID --no-pub
```

Replace `DEVICE_ID` with the ID from `flutter devices`. A debug APK uses the local debug certificate. Use a test device or emulator if it already has an official build with a different certificate. Building a signed release requires your own ignored `android/key.properties` with `storeFile`, `storePassword`, `keyAlias`, and `keyPassword`.

For native offline speech on Android, run `tool/build_espeak_android.ps1` with the pinned source and SDK paths described in [third-party notices](THIRD_PARTY_NOTICES.md), and supply compatible eSpeak NG data at `assets/espeakdata.zip`.

## Full runtime and tests

If you have access to the full local Scanora checkout, you can prepare the matching runtime without signing or account credentials:

```powershell
python tool/prepare_assets.py --from-local "C:/path/to/full/Scanora"
python tool/verify_offline_assets.py
flutter test test --no-pub
flutter test integration_test/offline_audit_test.dart -d windows --no-pub
```

The runtime files are ignored by Git. Online services are optional. The Google configuration example contains blank fields. Some integration tests intentionally make provider requests and require an authorized test configuration. Use synthetic inputs for those tests.

The source checkout uses a separate sample value for demo activation tests. It does not validate activation codes issued for private demo builds.
