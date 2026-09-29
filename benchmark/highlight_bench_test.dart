// What syntax highlighting actually costs on a large file, in a language the
// file is really written in.
//
// `hotpath_bench_test.dart` measures the JSON grammar over a plain-text RFC,
// which is the worst pairing there is: highlight.js backtracks hard when the
// grammar does not fit. That number (tens of seconds) has been used to justify
// work, and it is not the number anyone experiences. This is.
//
// The file is the package's own Dart sources, repeated to a realistic size, so
// the grammar and the text agree the way they do in a real project.
//
//   flutter test benchmark/highlight_bench_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_editor/src/native/grammar_json.dart';
import 'package:re_editor/src/native/highlight_spans.dart';
import 'package:re_editor/src/native/native.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/re_highlight.dart';

void report(String label, int us, [String? extra]) {
  final String suffix = extra == null ? '' : '  ($extra)';
  // ignore: avoid_print
  print('${label.padRight(52)} ${(us / 1000).toStringAsFixed(0).padLeft(8)} ms$suffix');
}

void main() {
  final File file = File('/tmp/bigger.dart');
  if (!file.existsSync()) {
    // Built by concatenating lib/**.dart twelve times over; see the README in
    // this directory. Skipped rather than failed so the suite stays runnable
    // without it.
    return;
  }

  test('highlighting a large file in its own language', () {
    final String source = file.readAsStringSync();
    final CodeLines lines = source.codeLines;
    final String code = lines.asString(TextLineBreak.lf, false);
    // ignore: avoid_print
    print('\n=== ${lines.length} lines, ${code.length} chars ===\n');

    // The Rust core goes first, and has to: `re_highlight` compiles a language
    // by rewriting it in place, so the transcription below has to happen while
    // the grammar is still the one its author wrote. It is also the order the
    // editor uses, where the native grammar is compiled when the theme is set.
    //
    // Everything the editor pays is in the number: transcribe the grammar,
    // compile it, highlight, and replay the answer into the same renderer the
    // editor draws from.
    final ReEditorNativeApi? api = createReEditorNativeApi();
    final Map<String, dynamic>? grammarJson =
        api == null ? null : nativeGrammarJson(langDart);
    NativeGrammar? native;
    if (api == null) {
      report('native (no core loaded)', 0, ReEditorNative.backendDescription);
    } else if (grammarJson == null) {
      report('native (grammar refused)', 0, nativeGrammarRefusal(langDart));
    } else {
      final Stopwatch compile = Stopwatch()..start();
      native = api.compileGrammar(json: jsonEncode(grammarJson));
      compile.stop();
      report('grammar compile (rust core)', compile.elapsedMicroseconds);
    }

    if (native != null) {
      final Stopwatch core = Stopwatch()..start();
      final List<NativeHighlightNode> nodes = native.highlight(code).nodes;
      core.stop();
      final _CountingRenderer replayRenderer = _CountingRenderer();
      final Stopwatch replay = Stopwatch()..start();
      replayHighlightSpans(code: code, nodes: nodes, renderer: replayRenderer);
      replay.stop();
      report('  highlight in the core', core.elapsedMicroseconds, '${nodes.length} nodes');
      report('  replay into the renderer', replay.elapsedMicroseconds,
          '${replayRenderer.texts} spans, ${replayRenderer.nodes} nodes');
      report('highlight whole document (rust core)',
          core.elapsedMicroseconds + replay.elapsedMicroseconds);
      report('  per keystroke', core.elapsedMicroseconds + replay.elapsedMicroseconds);
      native.dispose();
    }

    // The same document through the Dart implementation, which is what the
    // editor did before there was a choice — and what it still does on the web,
    // for a language the core cannot take, and in the frame or two before a
    // native answer arrives.
    final Highlight highlight = Highlight()..registerLanguage('dart', langDart);

    // One run, timed. `hotpath_bench_test.dart` warms up before timing because
    // its unit is milliseconds; at this size the warm-up would double a
    // measurement that already costs minutes.
    final Stopwatch sw = Stopwatch()..start();
    final HighlightResult result = highlight.highlight(code: code, language: 'dart');
    final _CountingRenderer renderer = _CountingRenderer();
    result.render(renderer);
    sw.stop();

    report('highlight whole document (dart grammar)', sw.elapsedMicroseconds,
        '${renderer.texts} spans, ${renderer.nodes} nodes');

    // What the editor pays per keystroke, which is this number — the highlight
    // is re-run over the whole document on every change.
    report('  per keystroke', sw.elapsedMicroseconds);
  }, timeout: const Timeout(Duration(minutes: 30)));
}
class _CountingRenderer implements HighlightRenderer {
  int texts = 0;
  int nodes = 0;

  @override
  void addText(String text) => texts++;

  @override
  void openNode(DataNode node) => nodes++;

  @override
  void closeNode(DataNode node) {}
}
