// Dart-side micro-benchmarks of the editor's hot paths.
//
// These are not assertions; they print timings so we can see where the time
// actually goes before moving work into Rust. Run with:
//
//   flutter test benchmark/hotpath_bench_test.dart
//
// The sample document is example/assets/large.txt: 108k lines / 4.6MB, which is
// the workload the README calls out ("large text display and editing").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/re_highlight.dart';

void report(String label, int us, [String? extra]) {
  final String suffix = extra == null ? '' : '  ($extra)';
  // ignore: avoid_print
  print('${label.padRight(46)} ${(us / 1000).toStringAsFixed(1).padLeft(9)} ms$suffix');
}

int timeIt(String label, void Function() body, [String? Function()? extra]) {
  // Warm up once so the JIT has seen the shape.
  body();
  final Stopwatch sw = Stopwatch()..start();
  body();
  sw.stop();
  report(label, sw.elapsedMicroseconds, extra?.call());
  return sw.elapsedMicroseconds;
}

void main() {
  late String large;
  late CodeLines lines;

  setUpAll(() {
    final File file = File('example/assets/large.txt');
    large = file.readAsStringSync();
    lines = large.codeLines;
  });

  test('hot paths', () {
    // ignore: avoid_print
    print('\n=== document: ${large.length} chars, ${lines.length} lines ===\n');

    timeIt('String.codeLines (parse whole doc)', () => large.codeLines);

    timeIt('CodeLines.asString(lf, expandChunks: false)', () {
      lines.asString(TextLineBreak.lf, false);
    });

    // Rendering walks the visible window forward from an index. Each access
    // scans segments until it lands in the right one.
    timeIt('CodeLines[i] x 2000 (walk from top)', () {
      for (int i = 0; i < 2000; i++) {
        lines[i];
      }
    });

    timeIt('CodeLines[i] x 2000 (walk from bottom)', () {
      for (int i = lines.length - 2000; i < lines.length; i++) {
        lines[i];
      }
    });

    timeIt('CodeLines[i] x 2000 (random)', () {
      // Deterministic pseudo-random walk.
      int seed = 12345;
      for (int i = 0; i < 2000; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        lines[seed % lines.length];
      }
    });

    timeIt('CodeLines.index2lineIndex(n) x 200', () {
      for (int i = 0; i < 200; i++) {
        lines.index2lineIndex((i * 541) % lines.length);
      }
    });

    timeIt('CodeLines.lineIndex2Index(n) x 200', () {
      for (int i = 0; i < 200; i++) {
        lines.lineIndex2Index((i * 541) % lines.length);
      }
    });

    timeIt('CodeLines.equals(self) ', () => lines.equals(lines));

    timeIt('CodeLines.sublines(0, 1000)', () => lines.sublines(0, 1000));

    // What the chunk controller runs off-thread on every content change.
    timeIt('DefaultCodeChunkAnalyzer.run (whole doc)', () {
      const DefaultCodeChunkAnalyzer().run(lines);
    });

    // What the highlight engine runs off-thread on every content change.
    const int maxSize = 100 * 1024 * 1024;
    const int maxLineLength = 1000;
    void highlightWholeDoc() {
      final Highlight highlight = Highlight()..registerLanguage('json', langJson);
      bool canHighlight = true;
      int total = 0;
      for (int i = 0; i < lines.length; i++) {
        final int len = lines[i].length;
        if (len > maxLineLength || total > maxSize) {
          canHighlight = false;
          break;
        }
        total += len;
      }
      final String code = lines.asString(TextLineBreak.lf, false);
      final result = canHighlight
          ? highlight.highlight(code: code, language: 'json')
          : highlight.justTextHighlightResult(code);
      final _CountingRenderer r = _CountingRenderer();
      result.render(r);
    }
    timeIt('highlight.js (json mode) whole doc [1st]', highlightWholeDoc);
    timeIt('highlight.js (json mode) whole doc [2nd]', highlightWholeDoc);

    // Editing: what a single keystroke costs on a large document.
    final CodeLineEditingController controller =
        CodeLineEditingController.fromText(large);
    timeIt('controller.replaceSelection (1 keystroke)', () {
      controller.replaceSelection('x');
    });
    timeIt('controller text getter (whole doc to string)', () {
      controller.text;
    });
    timeIt('controller.deleteBackward x 100', () {
      for (int i = 0; i < 100; i++) {
        controller.deleteBackward();
      }
    });
    timeIt('controller.replaceAll("\n", "\n")', () {
      controller.replaceAll('\n', '\n');
    });
    controller.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('search view cost', () {
    // What search scans: `flat()` expands collapsed chunks, so this is the
    // document the find panel searches — and the reason a Rust-side search
    // document cannot be the same one bracket analysis reads, which sees only
    // the collapsed view.
    //
    // Whether rebuilding it per keystroke is affordable decides the shape of
    // that document: if it is cheap, the document can simply hold the flattened
    // lines; if not, it needs to carry both views.
    //
    // Kept out of the 'hot paths' test so it can be run on its own — that one
    // also times a whole-document highlight, which takes the better part of a
    // minute and buries this.
    timeIt('CodeLines -> flattened lines, nothing collapsed', () {
      lines.toList().fold(<String>[], (previousValue, element) {
        previousValue.addAll(element.flat());
        return previousValue;
      });
    });

    // The same thing, with one line carrying hidden content — the case that
    // actually makes the two views differ.
    final List<CodeLine> withChunk = lines.toList();
    withChunk[0] = CodeLine(withChunk[0].text, [const CodeLine('hidden'), const CodeLine('also hidden')]);
    final CodeLines collapsed = CodeLines.of(withChunk);
    timeIt('CodeLines -> flattened lines, one line collapsed', () {
      collapsed.toList().fold(<String>[], (previousValue, element) {
        previousValue.addAll(element.flat());
        return previousValue;
      });
    });
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('find: looking up the line for each match', () {
    // Matches come back from the regex in ascending order, so the line each one
    // falls on can be walked forward. The original scanned from line 0 for
    // every match, which is O(matches x lines) — this is the measurement
    // behind replacing it with the forward walk.
    final List<String> raw =
        lines.toList().map((CodeLine line) => line.text).toList();
    int total = 0;
    for (final String line in raw) {
      total += line.length + 1;
    }
    total -= 1;
    // Every 4000th character is a match — around a thousand of them, which a
    // common search term produces easily. Not more, because the quadratic case
    // below is genuinely quadratic and this still has to finish.
    final List<int> offsets = <int>[for (int i = 0; i < total; i += 4000) i];
    // ignore: avoid_print
    print('\n${offsets.length} matches across ${raw.length} lines\n');

    timeIt('find: scan from line 0 per match', () {
      for (final int offset in offsets) {
        int start = 0;
        int line = 0;
        for (; line < raw.length; line++) {
          if (offset <= start + raw[line].length) {
            break;
          }
          start += raw[line].length + 1;
        }
      }
    });

    timeIt('find: walk forward', () {
      int cursor = 0;
      int cursorStart = 0;
      for (final int offset in offsets) {
        while (cursor < raw.length && offset > cursorStart + raw[cursor].length) {
          cursorStart += raw[cursor].length + 1;
          cursor++;
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
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
