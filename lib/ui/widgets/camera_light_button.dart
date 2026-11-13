import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';

class CameraLightButton extends StatelessWidget {
  final CameraController? controller;
  const CameraLightButton({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final camera = controller;
    if (camera == null || !camera.value.isInitialized) {
      return IconButton(
        tooltip: l.tx('Camera light', 'چراغ دوربین'),
        onPressed: null,
        icon: const Icon(Icons.flashlight_off),
      );
    }
    return ValueListenableBuilder<CameraValue>(
      valueListenable: camera,
      builder: (context, value, _) {
        final on = value.flashMode == FlashMode.torch;
        final label = on
            ? l.tx('Turn camera light off', 'خاموش کردن چراغ دوربین')
            : l.tx('Turn camera light on', 'روشن کردن چراغ دوربین');
        return IconButton(
          tooltip: label,
          icon: Icon(on ? Icons.flashlight_on : Icons.flashlight_off),
          onPressed: () async {
            try {
              await camera
                  .setFlashMode(on ? FlashMode.off : FlashMode.torch)
                  .timeout(const Duration(seconds: 2));
            } catch (_) {
              if (context.mounted) {
                AccessibilityService.announce(
                    context,
                    l.tx(
                      'Camera light is unavailable. Use more room lighting.',
                      'چراغ این دوربین در دسترس نیست. نور محیط را بیشتر کنید.',
                    ));
              }
            }
          },
        );
      },
    );
  }
}
