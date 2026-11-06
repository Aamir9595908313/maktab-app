// One shared guard against double submission, used by every Save / Submit /
// Update / Confirm operation (the *Remote functions).
//
// - The first call of an operation runs; any identical call that arrives while
//   it is still running is rejected immediately (it never reaches the server).
// - While an operation runs, a full-screen "Please wait, saving..." overlay
//   absorbs every tap, so no button on any screen can be pressed again.
// - The overlay disappears as soon as the operation finishes (success or
//   failure), so the user can retry after an error.
import 'package:flutter/material.dart';

const String kBusyMessage = 'Please wait - the previous save is still in progress.';

class SaveGuard {
  SaveGuard._();
  static final Set<String> _running = {};
  static final ValueNotifier<String?> message = ValueNotifier<String?>(null);
  static final List<String> _stack = [];

  /// Runs [fn] unless the same [key] is already running, in which case [onBusy]
  /// is returned at once. [label] is the text shown on the loading overlay.
  static Future<T> run<T>(String key, String label, Future<T> Function() fn, T Function(String) onBusy) async {
    if (_running.contains(key)) return onBusy(kBusyMessage);
    _running.add(key);
    _stack.add(label);
    message.value = label;
    try {
      return await fn();
    } finally {
      _running.remove(key);
      _stack.remove(label);
      message.value = _stack.isEmpty ? null : _stack.last;
    }
  }
}

/// Wrap the app's content in this (MaterialApp.builder) to get the overlay.
class SaveOverlay extends StatelessWidget {
  const SaveOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      child,
      ValueListenableBuilder<String?>(
        valueListenable: SaveGuard.message,
        builder: (context, msg, _) {
          if (msg == null) return const SizedBox.shrink();
          return Positioned.fill(
            child: Stack(children: [
              const ModalBarrier(dismissible: false, color: Color(0x66000000)),
              Center(
                child: Material(
                  color: Colors.white,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      const SizedBox(width: 16),
                      Flexible(child: Text(msg, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.black87))),
                    ]),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    ]);
  }
}
