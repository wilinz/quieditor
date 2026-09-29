// Measures the editor's hot paths in an AOT build, which `flutter test` cannot
// do — it only ever runs Dart in JIT debug mode.
//
// Without this the comparison is unfair: the Rust core is always built
// `--release`, while every Dart number coming out of `flutter test` is JIT with
// assertions on. As it happens Dart is *slower* in AOT on this workload, so the
// test numbers understate the native win rather than flattering it — but the
// only way to know that was to measure it here.
//
//   flutter build macos --release --target=lib/bench_main.dart
//   ./build/macos/Build/Products/Release/example.app/Contents/MacOS/example
//
// The app prints its results and exits; none of this is a UI.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
// The harness measures the internals, so it imports one: transcribing a
// language is the editor's business rather than a caller's, and there is no
// public name for it.
// ignore: implementation_imports
import 'package:re_editor/src/native/grammar_json.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/re_highlight.dart';

/// True in a release build. Printed rather than assumed: the whole point of
/// this harness is to say which mode the numbers below came from.
const bool _isProduct = bool.fromEnvironment('dart.vm.product');

void report(String label, int us, [String? extra]) {
  final String suffix = extra == null ? '' : '  ($extra)';
  stdout.writeln('${label.padRight(46)} ${(us / 1000).toStringAsFixed(3).padLeft(9)} ms$suffix');
}

/// Runs [body] once to warm up, then times a second run.
///
/// The warm-up matters even in AOT: the first pass over a document pages in the
/// strings and fills the caches.
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
/// This is what the mirror does to decide what to send, repeated here because
/// it is internal. If the two drift apart, this number stops meaning what it
/// says.
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final String text = await rootBundle.loadString('assets/large.txt');
  // The sample the highlighting numbers are built from, in a language — the RFC
  // above is not code, and highlighting it with a code grammar would measure
  // backtracking rather than anything a person does.
  final String sample = await rootBundle.loadString('assets/code.dart');
  stdout.writeln('\n=== release: $_isProduct, backend: ${ReEditorNative.backendDescription} ===');
  run(text);
  runHighlighting(sample);
  stdout.writeln('');
  exit(0);
}

/// How many times the sample is repeated, which is what sets the document's
/// size. Chosen so the highlighting numbers below are about a document of the
/// same order as the one above — 108,000 lines.
const int _highlightRepeats = 7000;

/// What highlighting costs, whole and in pieces.
///
/// The whole-document number is what every keystroke used to cost: the state
/// carries from line to line, so the only way to colour line 500 was to start
/// at line 1. The pieces are what an edit costs when the states between lines
/// are kept — which is the thing that makes an editor of this size usable.
void runHighlighting(String sample) {
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < _highlightRepeats; i++) {
    buffer.write(sample);
  }
  final String code = buffer.toString();
  final List<String> lines = code.split('\n');
  stdout.writeln('\n=== highlighting: ${lines.length} lines, ${code.length} chars ===\n');

  // The native side first, and it has to be: transcribing a language needs it
  // as its author wrote it, and highlighting with it in Dart compiles it in
  // place — following `ref`s, rewriting `match` into `begin` — after which it
  // cannot be transcribed exactly. This is the same ordering the editor uses,
  // where the grammar is transcribed when the theme is set.
  final Map<String, dynamic>? json = nativeGrammarJson(langDart);
  if (json == null) {
    report('rust: the grammar was refused', 0, nativeGrammarRefusal(langDart));
    return;
  }
  // What the core costs on the whole document, which is what every keystroke
  // used to pay and what building a highlighter pays once.
  final NativeGrammar? grammar = ReEditorNative.compileGrammar(jsonEncode(json));
  if (grammar != null) {
    final Stopwatch whole = Stopwatch()..start();
    final List<NativeHighlightNode> nodes = grammar.highlight(code).nodes;
    whole.stop();
    report('rust: highlight the whole document', whole.elapsedMicroseconds,
        '${nodes.length} nodes');
    grammar.dispose();
  }

  final Stopwatch built = Stopwatch()..start();
  final NativeHighlighter? highlighter = ReEditorNative.openHighlighter(
    jsonEncode(json),
    text: code,
  );
  built.stop();
  if (highlighter == null) {
    report('rust: the highlighter was refused', 0);
    return;
  }
  report('rust: build the highlighter (once)', built.elapsedMicroseconds);

  // The Dart implementation, which is what the editor ran before there was a
  // choice. One run, timed: at this size a warm-up would double a measurement
  // that already costs seconds.
  final Highlight highlight = Highlight()..registerLanguage('dart', langDart);
  final Stopwatch dart = Stopwatch()..start();
  highlight.highlight(code: code, language: 'dart');
  dart.stop();
  report('dart: highlight the whole document', dart.elapsedMicroseconds);

  // What an edit costs, at three depths. Where the edit is must not matter:
  // what bounds the work is the next recorded state down, not the distance to
  // the end of the document.
  for (final (String label, int line) in <(String, int)>[
    ('near the top', 30),
    ('in the middle', lines.length ~/ 2),
    ('near the end', lines.length - 10),
  ]) {
    final List<String> added = <String>['  // edited'];
    final Stopwatch edit = Stopwatch()..start();
    final NativeHighlightUpdate update =
        highlighter.splice(start: line, removed: 1, added: added);
    edit.stop();
    report('rust: keystroke $label', edit.elapsedMicroseconds,
        '${update.to - update.from} lines re-highlighted');
  }

  // And opening a brace, which is as bad as a keystroke gets.
  final Stopwatch brace = Stopwatch()..start();
  final NativeHighlightUpdate update = highlighter.splice(
    start: 100,
    removed: 1,
    added: <String>['  {', '    // inside', '  }'],
  );
  brace.stop();
  report('rust: opening a brace', brace.elapsedMicroseconds,
      '${update.to - update.from} lines re-highlighted');

  highlighter.dispose();
}

void run(String source) {
  final CodeLines lines = source.codeLines;
  final List<String> texts = lines.toList().map((CodeLine line) => line.text).toList();
  stdout.writeln('=== ${lines.length} lines ===\n');

  // --- What the core costs per keystroke -----------------------------------
  //
  // There is no Dart column for this any more: the analysis is the core's, and
  // `DefaultCodeChunkAnalyzer` is one of the ways to ask it. A number for "the
  // Dart implementation" would be the same work through a document built from
  // the lines, which measures the route rather than the implementation. The
  // highlighting section below still has a Dart column, because that one is
  // against `re_highlight` — a library of its own, which is what a caller who
  // wants the old highlighter uses.

  final NativeDocument? document = ReEditorNative.openDocument(
    texts.map(NativeLine.new).toList(),
  );
  if (document == null) {
    stdout.writeln('the native side would not take the document');
    return;
  }

  // The Dart half of the sync: copying the line list and locating the span that
  // changed, against the worst realistic case — an edit at the very end, so the
  // prefix scan runs its full length.
  final List<CodeLine> current = lines.toList();
  final List<CodeLine> edited = List<CodeLine>.of(current);
  edited[current.length - 1] = const CodeLine('changed');
  final int syncUs = timeIt(
    'dart: locate the changed span (worst case)',
    () => changedSpan(current, edited),
  );

  // The Rust half: send one line, get the analysis back. A whole-document pass
  // happens on both sides, so this is the same work as the Dart case.
  const int edits = 100;
  int line = 0;
  final int spliceUs = timeIt('rust: splice one line, x$edits', () {
    for (int i = 0; i < edits; i++) {
      line = (line + 1) % texts.length;
      document.splice(start: line, removed: 1, added: <NativeLine>[NativeLine('x$i')]);
    }
  });
  final int analyzeUs = timeIt('rust: analyze, x$edits', () {
    for (int i = 0; i < edits; i++) {
      document.analyzeChunks();
    }
  });

  final int nativePerEdit = (spliceUs + analyzeUs) ~/ edits;
  final int nativeTotal = nativePerEdit + syncUs;

  stdout.writeln('');
  report('per keystroke', nativeTotal, '$nativePerEdit us rust + $syncUs us dart');

  document.dispose();
}
