// What a keystroke costs, which is the number the editor lives by.
//
// `highlight_bench_test.dart` measures a whole document: 904 ms through the Rust
// core over the package's own sources at 181,000 lines, against 51,824 ms for the
// Dart implementation. Both are re-run on every keystroke by an editor that
// highlights the whole document, which is why the second one is unusable and the
// first one is still too slow.
//
// The incremental highlighter is the answer to the per-keystroke part: it holds
// the states between the document's lines, so an edit costs the lines it touched.
//
// The opening cost is the other half, and it is no longer a whole-document pass:
// building a highlighter highlights nothing, and the lines are scanned as the
// editor draws them — so what opening costs is the window it opens with, and the
// rest of the document follows on the frames after it. The number that pass used
// to cost is measured here too, because it is what the window is being compared
// against.
//
//   flutter test benchmark/incremental_bench_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_editor/src/native/grammar_json.dart';
import 'package:re_editor/src/native/native.dart';
import 'package:re_highlight/languages/dart.dart';

void report(String label, int us, [String? extra]) {
  final String suffix = extra == null ? '' : '  ($extra)';
  // ignore: avoid_print
  print('${label.padRight(46)} ${(us / 1000).toStringAsFixed(3).padLeft(9)} ms$suffix');
}

void main() {
  final File file = File('/tmp/bigger.dart');
  if (!file.existsSync()) {
    return;
  }

  test('a keystroke in a large document', () {
    final String source = file.readAsStringSync();
    final List<String> lines = source.split('\n');
    final ReEditorNativeApi? api = createReEditorNativeApi();
    if (api == null) {
      report('no native core', 0, ReEditorNative.backendDescription);
      return;
    }
    final Map<String, dynamic>? json = nativeGrammarJson(langDart);
    if (json == null) {
      report('the grammar was refused', 0, nativeGrammarRefusal(langDart));
      return;
    }
    // ignore: avoid_print
    print('\n=== ${lines.length} lines, ${source.length} chars ===\n');

    // Building one, which highlights nothing: a document is highlighted from
    // its top as the editor draws it, so opening a large file does not wait for
    // the end of it. What that costs is the grammar and the state at line 0.
    final Stopwatch build = Stopwatch()..start();
    final NativeHighlighter? highlighter = api.openHighlighter(
      json: jsonEncode(json),
      subLanguages: const <String, String>{},
      text: source,
    );
    build.stop();
    if (highlighter == null) {
      report('the highlighter was refused', build.elapsedMicroseconds);
      return;
    }
    report('open a highlighter (was: highlight it once)', build.elapsedMicroseconds);

    // The window an editor opens with, and then the rest of the document, which
    // is what opening used to cost.
    final Stopwatch window = Stopwatch()..start();
    highlighter.scan(264);
    window.stop();
    report('  scan the window it opens with', window.elapsedMicroseconds, '264 lines');

    final Stopwatch rest = Stopwatch()..start();
    highlighter.scan(1 << 30);
    rest.stop();
    report('  scan the rest (what opening cost before)', rest.elapsedMicroseconds);

    // Typing at various depths. Where the edit is should not matter, which is
    // the property the states between lines exist to give: what bounds the work
    // is the next recorded state down, not the distance to the end.
    for (final (label, line) in <(String, int)>[
      ('typing near the top', 30),
      ('typing 1,000 lines in', 1000),
      ('typing in the middle', lines.length ~/ 2),
      ('typing near the end', lines.length - 10),
    ]) {
      final Stopwatch edit = Stopwatch()..start();
      final NativeHighlightUpdate update =
          highlighter.splice(start: line, removed: 1, added: <String>['  // edited']);
      edit.stop();
      report('  $label', edit.elapsedMicroseconds,
          '${update.to - update.from} lines re-highlighted');
    }

    // Opening a brace, which is as bad as a keystroke gets: everything it
    // encloses has to be looked at again.
    final Stopwatch brace = Stopwatch()..start();
    final NativeHighlightUpdate update = highlighter.splice(
      start: 1000,
      removed: 1,
      added: <String>['  {', '    // inside', '  }'],
    );
    brace.stop();
    report('  opening a brace', brace.elapsedMicroseconds,
        '${update.to - update.from} lines re-highlighted');

    highlighter.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
