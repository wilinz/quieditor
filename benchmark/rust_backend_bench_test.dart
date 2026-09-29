// Compares the Rust core against the Dart implementation it replaces.
//
//   flutter test benchmark/rust_backend_bench_test.dart
//
// Runs on the same 108k-line sample as `hotpath_bench_test.dart`, which measures
// the Dart paths.
//
// CAVEAT: `flutter test` only ever runs Dart as JIT debug — there is no release
// or profile mode for it. That does not flatter the Rust side (Dart turns out to
// be *slower* in AOT on this workload), but it does mean the numbers here are
// not release numbers. For those, build and run example/lib/bench_main.dart:
//
//   flutter build macos --release --target=lib/bench_main.dart
//   ./build/macos/Build/Products/Release/example.app/Contents/MacOS/example
//
// Both harnesses measure the same things, so the two sets are comparable.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void report(String label, int us, [String? extra]) {
  final String suffix = extra == null ? '' : '  ($extra)';
  // ignore: avoid_print
  print('${label.padRight(46)} ${(us / 1000).toStringAsFixed(3).padLeft(9)} ms$suffix');
}

/// Runs [body] once to warm up, then times a second run.
///
/// The asynchronous counterpart of [timeIt], for work that leaves the thread.
Future<int> timeAsync(String label, Future<void> Function() body) async {
  await body();
  final Stopwatch sw = Stopwatch()..start();
  await body();
  sw.stop();
  report(label, sw.elapsedMicroseconds);
  return sw.elapsedMicroseconds;
}

int timeIt(String label, void Function() body, [String? extra]) {
  body();
  final Stopwatch sw = Stopwatch()..start();
  body();
  sw.stop();
  report(label, sw.elapsedMicroseconds, extra);
  return sw.elapsedMicroseconds;
}

/// The span that differs between two line lists, found by identity.
///
/// This is what `_NativeDocumentMirror` does to decide what to send, repeated
/// here because the mirror is internal. If the two drift apart, these numbers
/// stop meaning what they say.
({int start, int removed, int addedLength}) changedSpan(
  List<CodeLine> before,
  List<CodeLine> after,
) {
  int start = 0;
  final int shared = before.length < after.length ? before.length : after.length;
  while (start < shared && identical(before[start], after[start])) {
    start++;
  }
  int head = before.length;
  int tail = after.length;
  while (head > start && tail > start && identical(before[head - 1], after[tail - 1])) {
    head--;
    tail--;
  }
  return (start: start, removed: head - start, addedLength: tail - start);
}

void main() {
  late CodeLines lines;
  late List<String> texts;

  setUpAll(() {
    final String large = File('example/assets/large.txt').readAsStringSync();
    lines = large.codeLines;
    texts = lines.toList().map((CodeLine line) => line.text).toList();
  });

  test('rust vs dart', () {
    // ignore: avoid_print
    print('\n=== ${lines.length} lines, backend: ${ReEditorNative.backendDescription} ===\n');

    if (!ReEditorNative.isAvailable) {
      fail(
        'No native backend: ${ReEditorNative.backendDescription}. '
        'This benchmark compares against it and cannot say anything without it.',
      );
    }

    // --- What the Dart implementation costs per keystroke ------------------

    const DefaultCodeChunkAnalyzer dartAnalyzer = DefaultCodeChunkAnalyzer();
    final int dartUs = timeIt(
      'dart: analyze the whole document',
      () => dartAnalyzer.run(lines),
    );

    // --- What the native implementation costs per keystroke ----------------

    // The one time the whole document crosses. Everything after this is a
    // splice.
    final NativeDocument? document = ReEditorNative.openDocument(
      texts.map(NativeLine.new).toList(),
    );
    expect(document, isNotNull, reason: 'the native side would not take the document');

    // The Dart half of the sync: copying the line list and finding the span
    // that changed, against the worst realistic case — an edit at the very end
    // of the document, so the prefix scan runs its full length.
    final List<CodeLine> current = lines.toList();
    final List<CodeLine> edited = List<CodeLine>.of(current);
    edited[current.length - 1] = const CodeLine('changed');
    int spanStart = 0;
    final int syncUs = timeIt('dart: locate the changed span (worst case)', () {
      final ({int start, int removed, int addedLength}) span = changedSpan(current, edited);
      spanStart = span.start;
    }, '$spanStart');
    expect(spanStart, current.length - 1, reason: 'the span was not found where it was made');

    // The Rust half: send one line, get the analysis back. A whole-document
    // pass happens on both sides, so this is the same work as the Dart case.
    const int edits = 100;
    int line = 0;
    final int spliceUs = timeIt('rust: splice one line, x$edits', () {
      for (int i = 0; i < edits; i++) {
        line = (line + 1) % texts.length;
        document!.splice(start: line, removed: 1, added: <NativeLine>[NativeLine('x$i')]);
      }
    });
    final int analyzeUs = timeIt('rust: analyze, x$edits', () {
      for (int i = 0; i < edits; i++) {
        document!.analyzeChunks();
      }
    });

    final int nativePerEdit = (spliceUs + analyzeUs) ~/ edits;
    final int nativeTotal = nativePerEdit + syncUs;

    // ignore: avoid_print
    print('');
    report(
      'native per keystroke',
      nativeTotal,
      '$nativePerEdit us rust + $syncUs us dart',
    );
    report('dart per keystroke', dartUs);
    report(
      'speedup per keystroke',
      0,
      '${(dartUs / nativeTotal).toStringAsFixed(1)}x',
    );

    document!.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('search', () async {
    // The Dart path rebuilds the flattened view and joins it before the engine
    // can look at it; the native path searches the view the document already
    // keeps, on a worker thread, so the only thing this thread pays for is
    // asking.
    //
    // Two patterns, because the answer depends entirely on which kind you look
    // for: a common one turns this into a measurement of how fast 400,000
    // results can be built, which is not the question.
    final String large = File('example/assets/large.txt').readAsStringSync();
    final CodeLines lines = large.codeLines;
    final List<String> texts = lines.toList().map((CodeLine line) => line.text).toList();

    // ignore: avoid_print
    print('\n=== search, ${ReEditorNative.backendDescription} ===');

    final NativeDocument? document =
        ReEditorNative.openDocument(texts.map(NativeLine.new).toList());
    expect(document, isNotNull);
    if (document == null) {
      return;
    }

    for (final String pattern in <String>['index', 'the']) {
      // ignore: avoid_print
      print('');

      int dartMatches = 0;
      await timeAsync('dart: flatten + join + allMatches "$pattern"', () async {
        final List<String> raw = lines.toList().fold(<String>[], (previousValue, element) {
          previousValue.addAll(element.flat());
          return previousValue;
        });
        dartMatches = RegExp(pattern, caseSensitive: false).allMatches(raw.join('\n')).length;
      });
      report('  dart found', 0, '$dartMatches matches');

      NativeFindResult? found;
      await timeAsync('rust: find "$pattern", whole document', () async {
        found = await document.find(pattern: pattern, caseSensitive: false, regex: false);
      });
      report('  rust found', 0, '${found?.matches.length ?? -1} matches');

      expect(found, isNotNull, reason: 'the native side declined "$pattern"');
      expect(
        found!.matches.length,
        dartMatches,
        reason: 'the two engines disagree on "$pattern", which would change what '
            'the find panel shows',
      );
    }

    document.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('what a keystroke costs with the find panel open', () async {
    // Every keystroke re-runs the search when the panel is open, and the two
    // engines pay for it on different threads: the Dart one serialises the
    // document to an isolate, the native one searches in place but blocks the
    // caller. This is the number that says which is better for the person
    // typing, and it is the reason a native search may still need to move off
    // the UI thread.
    // Whichever backend is live — run this file twice, once with
    // `--dart-define=RE_EDITOR_FORCE_DART=true`, to get both numbers.
    final bool native = ReEditorNative.isAvailable;
    // ignore: avoid_print
    print('\n=== keystroke with the find panel open, ${ReEditorNative.backendDescription} ===');

    // The whole document, because that is what makes the two paths differ:
    // on a handful of lines both are free.
    final CodeLineEditingController controller = CodeLineEditingController.fromText(
      File('example/assets/large.txt').readAsStringSync(),
    );
    final CodeFindController find = CodeFindController(
      controller,
      const CodeFindValue(
        option: CodeFindOption(
          pattern: 'index',
          caseSensitive: false,
          regex: false,
        ),
        replaceMode: false,
      ),
    );
    // Let the first search land before anything is timed.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    timeIt(
      native ? 'keystroke, native search' : 'keystroke, dart search',
      () => controller.replaceSelection('x'),
    );

    // The native result is applied in a microtask and the Dart one from an
    // isolate, so neither has landed by the time the clock stops.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(find.value?.result, isNotNull, reason: 'the search did not run');

    find.dispose();
    controller.dispose();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
