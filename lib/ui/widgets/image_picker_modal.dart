import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'in_app_camera_screen.dart';

class ImagePickerModal {
  static final ImagePicker _picker = ImagePicker();

  /// Picks an image from clipboard (supports file paths, base64 strings, and Windows bitmap clipboard)
  static Future<Uint8List?> pickFromClipboard() async {
    try {
      // 1. Check text clipboard for image file paths or data URLs
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboardData?.text?.trim();

      if (text != null && text.isNotEmpty) {
        final cleanPath = text.replaceAll('"', '').replaceAll("'", '');
        final file = File(cleanPath);
        if (file.existsSync()) {
          final lower = cleanPath.toLowerCase();
          if (lower.endsWith('.png') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.bmp') ||
              lower.endsWith('.webp')) {
            return await file.readAsBytes();
          }
        }

        if (text.startsWith('data:image')) {
          final base64Part = text.split(',').last;
          return base64Decode(base64Part);
        }
      }

      // 2. On Windows, check native bitmap clipboard
      if (Platform.isWindows) {
        final res = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          r'Add-Type -AssemblyName System.Windows.Forms; if ([System.Windows.Forms.Clipboard]::ContainsImage()) { $img = [System.Windows.Forms.Clipboard]::GetImage(); $ms = New-Object System.IO.MemoryStream; $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); [System.Convert]::ToBase64String($ms.ToArray()) }',
        ]);
        final b64 = res.stdout.toString().trim();
        if (b64.isNotEmpty) {
          return base64Decode(b64);
        }
      }
    } catch (e) {
      debugPrint('Error picking from clipboard: $e');
    }
    return null;
  }

  /// Shows the image selection sheet using the standard In-App Camera (`InAppCameraScreen`)
  static Future<Uint8List?> show(BuildContext context) async {
    final l10n = AppLocalizations.of(context);

    return showModalBottomSheet<Uint8List?>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.translate('tab_image_to_text'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: AppTheme.primaryCyan,
                    child: Icon(Icons.paste_rounded, color: Colors.black),
                  ),
                  title: Text(l10n.translate('source_clipboard')),
                  onTap: () async {
                    final bytes = await pickFromClipboard();
                    if (ctx.mounted) Navigator.pop(ctx, bytes);
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: AppTheme.primaryBlue,
                    child:
                        Icon(Icons.photo_library_rounded, color: Colors.white),
                  ),
                  title: Text(l10n.translate('source_gallery')),
                  onTap: () async {
                    final XFile? file =
                        await _picker.pickImage(source: ImageSource.gallery);
                    if (file != null) {
                      final bytes = await file.readAsBytes();
                      if (ctx.mounted) Navigator.pop(ctx, bytes);
                    }
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: AppTheme.accentIndigo,
                    child: Icon(Icons.camera_alt_rounded, color: Colors.white),
                  ),
                  title: Text(l10n.translate('source_camera')),
                  onTap: () async {
                    final bytes = await InAppCameraScreen.capture(
                      ctx,
                      title: l10n.translate('source_camera'),
                    );
                    if (ctx.mounted) Navigator.pop(ctx, bytes);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Generates an in-memory sample captcha PNG using pure Dart
  static Uint8List generateSampleCaptcha(String text) {
    const width = 200;
    const height = 70;
    final image = img.Image(width: width, height: height);

    img.fill(image, color: img.ColorRgb8(240, 243, 246));

    final rand = text.hashCode;
    for (int i = 0; i < 6; i++) {
      final y1 = (rand * (i + 1)) % height;
      final y2 = (rand * (i + 5)) % height;
      img.drawLine(
        image,
        x1: 0,
        y1: y1,
        x2: width,
        y2: y2,
        color: img.ColorRgb8(180, 190, 200),
      );
    }

    img.drawString(
      image,
      text,
      font: img.arial24,
      x: 30,
      y: 22,
      color: img.ColorRgb8(20, 30, 60),
    );

    return Uint8List.fromList(img.encodePng(image));
  }
}
