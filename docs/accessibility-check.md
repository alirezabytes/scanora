# Try Scanora with a screen reader

The repository includes a synthetic sample, [english_document.png](../test/fixtures/english_document.png). The sample contains the word “Scanora”, the phrase “without internet”, and the number “12345”.

1. Set up the platform's OCR engine and language data as described in [BUILDING.md](../BUILDING.md), then turn on **Work offline**.
2. On Android with TalkBack, open Image to Text and select the sample. On Windows with NVDA, use Tab and Enter to reach Image to Text and open the same file. Start recognition.
3. Confirm that focus reaches the result and that the expected text is readable. With speech enabled, confirm that you can pause and restart reading.
4. To try live reading, display or print the sample and open **Instant Live Camera Reader** on a device with a camera. Record the first audible guidance, the words announced, and whether moving to a different sample causes a new reading.

The automated OCR regression suite checks the expected phrases using the Windows offline engine. The screen-reader and physical camera steps are manual checks. When reporting a result, include the device, screen reader, sample, and exact steps so another contributor can repeat it.

To run the automated Windows OCR checks after preparing Tesseract and its data:

```powershell
flutter test --no-pub test/ocr_regression_test.dart --plain-name "Real bundled Windows OCR without network"
```

All five cases passed in the local source snapshot, including text extraction at both quality settings and reading a rotated sample.
