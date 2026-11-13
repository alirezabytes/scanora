import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Captures the visible bounds of a uniquely labelled captcha.
class WindowsCaptchaCapture {
  static Future<Uint8List?> capture() async {
    if (!Platform.isWindows) return null;
    final foreground = DynamicLibrary.open('user32.dll')
        .lookupFunction<IntPtr Function(), int Function()>(
            'GetForegroundWindow');
    final window = foreground();
    if (window == 0) return null;
    final script = _script.replaceFirst('__WINDOW__', window.toString());
    final utf16 = ByteData(script.length * 2);
    for (var i = 0; i < script.length; i++) {
      utf16.setUint16(i * 2, script.codeUnitAt(i), Endian.little);
    }
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      base64Encode(utf16.buffer.asUint8List()),
    ]);
    final stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 8));
      final output = (await stdout).trim();
      await stderr;
      if (code != 0 || output.isEmpty) return null;
      return base64Decode(output);
    } on TimeoutException {
      return null;
    } finally {
      process.kill();
    }
  }

  static const _script = r"""
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CaptureWindow {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@
[void][CaptureWindow]::SetThreadDpiAwarenessContext([IntPtr](-4))
$window = [IntPtr]__WINDOW__
if ([CaptureWindow]::GetForegroundWindow() -ne $window) { return }
$root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
$condition = [System.Windows.Automation.PropertyCondition]::new(
  [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
  [System.Windows.Automation.ControlType]::Image)
$images = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
$pattern = '(?i)captcha|security[ _-]*code|verification[ _-]*code|کپچا|کد امنیتی|تصویر امنیتی'
$matchesFound = @()
$nearbyImages = @()
foreach ($image in $images) {
  $info = $image.Current
  if ($info.IsOffscreen) { continue }
  $label = "$($info.Name) $($info.AutomationId) $($info.HelpText)"
  $box = $info.BoundingRectangle
  if ($box.IsEmpty -or $box.Width -lt 20 -or $box.Height -lt 12 -or
      $box.Width -gt 1400 -or $box.Height -gt 650) { continue }
  if ($label -match $pattern) { $matchesFound += $box }
  elseif ([string]::IsNullOrWhiteSpace($info.Name) -and
          $box.Width -ge 55 -and $box.Width -le 700 -and
          $box.Height -le 200 -and $box.Width -gt $box.Height * 1.3) {
    $nearbyImages += $box
  }
  if ($matchesFound.Count -gt 1) { return }
}
if ($matchesFound.Count -eq 0 -and $nearbyImages.Count -gt 0) {
  $edit = [System.Windows.Automation.AutomationElement]::FocusedElement
  if ($edit -and $edit.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
      "$($edit.Current.Name) $($edit.Current.AutomationId)" -match $pattern) {
    $field = $edit.Current.BoundingRectangle
    foreach ($candidate in $nearbyImages) {
      $overlapsHorizontally = $candidate.Right -gt $field.Left -and $candidate.Left -lt $field.Right
      $distanceAbove = $field.Top - $candidate.Bottom
      if ($overlapsHorizontally -and $distanceAbove -ge 0 -and $distanceAbove -le 125) {
        $matchesFound += $candidate
      }
    }
  }
}
if ($matchesFound.Count -ne 1 -or [CaptureWindow]::GetForegroundWindow() -ne $window) { return }
$box = $matchesFound[0]
$bounds = $root.Current.BoundingRectangle
if (!$bounds.Contains($box)) { return }
$width = [int][Math]::Ceiling($box.Width)
$height = [int][Math]::Ceiling($box.Height)
$bitmap = [Drawing.Bitmap]::new($width, $height)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$stream = [IO.MemoryStream]::new()
try {
  $graphics.CopyFromScreen([int]$box.X, [int]$box.Y, 0, 0, $bitmap.Size)
  if ([CaptureWindow]::GetForegroundWindow() -ne $window) { return }
  $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
  [Console]::Write([Convert]::ToBase64String($stream.ToArray()))
} finally {
  $stream.Dispose()
  $graphics.Dispose()
  $bitmap.Dispose()
}
""";
}
