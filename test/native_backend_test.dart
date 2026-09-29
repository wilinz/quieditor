// Guards the seam between the editor and the Rust core.
//
// What matters here is not that the native path is fast — that is the
// benchmark suite's job — but that the two implementations stay
// interchangeable: everything above the seam must behave the same whether the
// native library is loaded or not, and a build without one must degrade
// quietly rather than half-work.
//
// Run the fallback side of that claim with:
//
//   flutter test --dart-define=RE_EDITOR_FORCE_DART=true
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// Mirrors `_kForcePureDart` in the library.
const bool _forcePureDart = bool.fromEnvironment('RE_EDITOR_FORCE_DART');

void main() {
  group('ReEditorNative', () {
    test('describes its backend in one line', () {
      // Always answerable, and the only thing a bug report needs in order to
      // say which implementation produced the behaviour.
      expect(ReEditorNative.backendDescription, isNotEmpty);
      // ignore: avoid_print
      print('re_editor backend: ${ReEditorNative.backendDescription}');
    });

    test('loads the Rust core, unless pure Dart was requested', () {
      if (_forcePureDart) {
        expect(ReEditorNative.isAvailable, isFalse);
        expect(ReEditorNative.backendDescription, contains('forced')); // see below
        return;
      }
      if (!ReEditorNative.isPlatformSupported) {
        // The web. There is no native code to load and no probe to run.
        expect(ReEditorNative.isAvailable, isFalse);
        return;
      }
      expect(
        ReEditorNative.isAvailable,
        isTrue,
        reason: 'The Rust core is built by hook/build.dart during `flutter test`. '
            'If this fails, the hook could not build it — check the build output '
            'for the reason, and that `cargo` is on PATH. To run the Dart '
            'fallback deliberately, pass '
            '--dart-define=RE_EDITOR_FORCE_DART=true.',
      );
    });

    test('reports an identity matching the Rust ABI when loaded', () {
      final NativeAbiInfo? info = ReEditorNative.abiInfo;
      if (info == null) {
        return;
      }
      expect(info.abiVersion, 4);
      expect(info.coreVersion, isNotEmpty);
      expect(ReEditorNative.backendDescription, startsWith('rust '));
    });
  });
}
