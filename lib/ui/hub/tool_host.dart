import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/confirm_dialog.dart';

/// Full-screen host for one tool (Image to Text, Captcha, Reading & Documents, ...).
///
/// Implements the safe-exit contract with [PopScope] and Windows Escape key:
/// * Always displays and announces the **exact section name** (`widget.title`) in the exit
///   confirmation dialog instead of the generic phrase "current section" / "بخش فعلی",
///   with default focus on **Cancel**.
class ToolHost<S extends State> extends StatefulWidget {
  final String title;
  final Widget Function(GlobalKey<S> key) builder;
  final bool Function(S state) hasActiveContent;
  final void Function(S state) onReset;

  /// Optional image that is delivered to the tool right after its first frame.
  final Uint8List? initialImage;
  final Future<void> Function(S state, Uint8List bytes)? onLoadImage;

  const ToolHost({
    super.key,
    required this.title,
    required this.builder,
    required this.hasActiveContent,
    required this.onReset,
    this.initialImage,
    this.onLoadImage,
  });

  @override
  State<ToolHost<S>> createState() => _ToolHostState<S>();
}

class _ToolHostState<S extends State> extends State<ToolHost<S>> {
  final GlobalKey<S> _childKey = GlobalKey<S>();

  @override
  void initState() {
    super.initState();
    final bytes = widget.initialImage;
    final loader = widget.onLoadImage;
    if (bytes != null && bytes.isNotEmpty && loader != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _childKey.currentState;
        if (mounted && state != null) {
          loader(state, bytes);
        }
      });
    }
  }

  Future<void> _handleBack() async {
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final sectionName = widget.title.trim();

    final exitTitle =
        l10n.isPersian ? 'خروج از $sectionName' : 'Exit from $sectionName';
    final exitMessage = l10n.isPersian
        ? 'آیا می‌خواهید از بخش «$sectionName» خارج شوید؟'
        : 'Are you sure you want to exit from "$sectionName"?';

    final confirmed = await showSafeConfirmDialog(
      context,
      title: exitTitle,
      message: exitMessage,
      confirmLabel: l10n.translate('exit_section_btn'),
    );
    if (!confirmed || !mounted) return;
    final state = _childKey.currentState;
    if (state != null) widget.onReset(state);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): _BackIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _BackIntent: CallbackAction<_BackIntent>(
              onInvoke: (_) {
                _handleBack();
                return null;
              },
            ),
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            includeSemantics: false,
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: l10n.translate('back'),
                  onPressed: _handleBack,
                ),
                title: Semantics(
                  header: true,
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                ),
              ),
              body: SafeArea(child: widget.builder(_childKey)),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackIntent extends Intent {
  const _BackIntent();
}
