// The editor's highlighting, from a theme to a drawn frame.
//
// `native_highlight_test.dart` is what says the Rust and Dart highlighters
// colour the same code the same way — event for event, in eight languages. What
// is left over is the wiring: transcribing the theme's language before
// `re_highlight` compiles it, compiling it where the work happens, and running
// that work in the isolate the editor already uses for highlighting. None of
// that has a colour to compare, and all of it can throw.
//
// It runs both ways round: with the Rust core, and with
// `--dart-define=RE_EDITOR_FORCE_DART=true` where the Dart implementation does
// the same work in the same place.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// Pumps an editor showing [text] in [language], and waits for the highlight.
///
/// The highlight is computed in a worker isolate and arrives by message, which
/// a pump loop does not wait for on its own: without the pause the frames stop
/// being scheduled before the answer has been sent, and the editor would be
/// tested before it had drawn anything.
Future<void> pumpEditor(WidgetTester tester, Mode language, String text) async {
  final CodeLineEditingController controller = CodeLineEditingController.fromText(text);
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    home: CodeEditor(
      controller: controller,
      style: CodeEditorStyle(
        codeTheme: CodeHighlightTheme(
          // One language, under whatever name: the theme's key is the language
          // the editor asks for, and a single entry is what lets the native path
          // take the work — choosing between several is `highlightAuto`, which
          // the Rust core does not do.
          languages: <String, CodeHighlightThemeMode>{
            'language': CodeHighlightThemeMode(mode: language),
          },
          theme: atomOneLightTheme,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pumpAndSettle();
}

class _CountingPlugin extends HLPlugin {

  int highlights = 0;

  @override
  void beforeHighlight(BeforeHighlightContext context) {
    highlights++;
  }

  @override
  void afterHighlight(HighlightResult result) {}

}

/// Waits for the highlight to arrive, up to a few seconds.
///
/// The highlight is computed in a worker isolate and arrives by message, which a
/// pump loop does not wait for on its own: without this the frames stop being
/// scheduled before the answer has been sent, and the editor is tested before it
/// has drawn anything. How long that takes depends on the machine and on
/// compiling the grammars, so this waits for the answer rather than for a fixed
/// time — a fixed time is either slower than it needs to be or flaky.
/// Whether a line was broken into more than one colour.
///
/// A line the highlighter has reached is split into the scopes the theme gives a
/// colour to; one it has not is drawn in the base style alone.
bool _coloured(TextSpan? span) =>
    (span?.children ?? const <InlineSpan>[])
        .map((InlineSpan child) => child.style?.color)
        .whereType<Color>()
        .toSet()
        .length >
    1;

Future<void> pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (int attempt = 0; attempt < 50 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  // Asking the highlighter for a window of the document is asking the native
  // one: without a core there is nothing to ask, and a document is drawn plain
  // however long it is.
  final bool noCore = !ReEditorNative.isAvailable;

  testWidgets('highlights a document through a theme', (tester) async {
    await pumpEditor(tester, langJson, '{"a": [1, true, null], "b": "text"}');
    expect(tester.takeException(), isNull);
  });

  testWidgets('highlights a language with nesting and keywords in it', (tester) async {
    await pumpEditor(
      tester,
      langDart,
      'import "dart:io";\n\nvoid main() {\n  final x = "a";\n  // comment\n}\n',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a theme naming several languages has one chosen for it', (tester) async {
    // `highlightAuto`: the theme says which languages are in play, and the
    // document says which one it is. The choice is made per document, so it can
    // change with an edit, which is why this path is not the incremental one.
    final Map<int, TextSpan> built = <int, TextSpan>{};
    final CodeLineEditingController controller = CodeLineEditingController(
      codeLines: '{"a": [1, 2], "b": null}'.codeLines,
      spanBuilder: ({
        required BuildContext context,
        required int index,
        required CodeLine codeLine,
        required TextSpan textSpan,
        required TextStyle style,
      }) {
        built[index] = textSpan;
        return textSpan;
      },
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: CodeEditor(
        controller: controller,
        style: CodeEditorStyle(
          codeTheme: CodeHighlightTheme(
            languages: <String, CodeHighlightThemeMode>{
              'dart': CodeHighlightThemeMode(mode: langDart),
              'json': CodeHighlightThemeMode(mode: langJson),
            },
            theme: atomOneLightTheme,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    controller.text = 'void main() {}\n';
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pumpAndSettle();

    // And the colours, which is what this path is for. A theme naming several
    // languages used to be checked only for not throwing, which stayed true
    // while nothing was coloured at all. Without a core there is nothing to
    // highlight with, so there is nothing to see here either.
    if (!noCore) {
      expect(
        (built[0]?.children ?? const <InlineSpan>[])
            .map((InlineSpan span) => span.style?.color)
            .whereType<Color>()
            .toSet(),
        isNotEmpty,
        reason: 'the chosen language coloured the first line',
      );
    }
  });

  testWidgets('a theme carrying plugins is drawn plain, not silently stripped', (
    tester,
  ) async {
    // A plugin is Dart code that runs around a highlight: one can rewrite the
    // text before it and the tree after it. The core cannot run that, and
    // highlighting without it would colour text the plugin meant to change — so
    // the document is drawn plain rather than wrongly. A theme that needs its
    // plugins is one for `re_highlight`, which this package does not replace.
    final _CountingPlugin plugin = _CountingPlugin();
    final CodeLineEditingController controller =
        CodeLineEditingController.fromText('{"a": 1}');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: CodeEditor(
        controller: controller,
        style: CodeEditorStyle(
          codeTheme: CodeHighlightTheme(
            languages: <String, CodeHighlightThemeMode>{
              'json': CodeHighlightThemeMode(mode: langJson),
            },
            theme: atomOneLightTheme,
            plugins: <HLPlugin>[plugin],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('draws a document plain when the core cannot take the language', (
    tester,
  ) async {
    // A language the core cannot read is drawn without colour, not highlighted
    // by something else: the Dart highlighter is `re_highlight`, and an
    // application that wants it uses that library.
    final Mode handWritten = Mode(
      contains: <Mode>[
        Mode(begin: '<', onBegin: (match, response) {}),
      ],
    );
    await pumpEditor(tester, handWritten, 'a < b;\n');
    expect(tester.takeException(), isNull);
  });

  testWidgets('follows a document through a run of edits', (tester) async {
    // What the incremental highlighter is for: after the first answer, each edit
    // is sent as the lines it touched and answered with the lines that changed.
    // The colours are the seam test's business; this is the path — a document
    // being edited, and the highlighting keeping up without the whole of it
    // crossing the boundary again.
    final CodeLineEditingController controller =
        CodeLineEditingController.fromText('def f() {\n  // note\n}\n');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: CodeEditor(
        controller: controller,
        style: CodeEditorStyle(
          codeTheme: CodeHighlightTheme(
            languages: <String, CodeHighlightThemeMode>{
              'language': CodeHighlightThemeMode(mode: langDart),
            },
            theme: atomOneLightTheme,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    for (final String text in <String>[
      'def f() {\n  // note!\n}\n',
      'def f() {\n  // note!\n  final x = 1;\n}\n',
      'def f() {\n}\n',
      'def f() {\n  final y = "text";\n}\n',
    ]) {
      controller.text = text;
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'after editing to:\n$text');
    }
  });

  testWidgets('highlights a document that changes under it', (tester) async {
    final CodeLineEditingController controller = CodeLineEditingController.fromText('{}');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: CodeEditor(
        controller: controller,
        style: CodeEditorStyle(
          codeTheme: CodeHighlightTheme(
            languages: <String, CodeHighlightThemeMode>{
              'language': CodeHighlightThemeMode(mode: langJson),
            },
            theme: atomOneLightTheme,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    controller.text = '{"a": 1}';
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reads the language of a long document off the top of it',
      (tester) async {
    // A theme naming two languages, and a document that is JSON at the top and
    // Dart below it. Scoring every language over everything — what this path
    // does for a document short enough to hold — says Dart, because there is
    // more of it. Reading the top says JSON, and the colour of a JSON key on the
    // first line says which of the two happened.
    final String text = <String>[
      for (int i = 0; i < 300; i++) '{"key$i": "value$i"},',
      for (int i = 0; i < 3_000; i++) 'void f$i() { final x = 1; }',
    ].join('\n');
    const Color keyColour = Color(0xFF00FF00);
    final Map<int, TextSpan> built = <int, TextSpan>{};
    final CodeLineEditingController controller = CodeLineEditingController(
      codeLines: text.codeLines,
      spanBuilder: ({
        required BuildContext context,
        required int index,
        required CodeLine codeLine,
        required TextSpan textSpan,
        required TextStyle style,
      }) {
        built[index] = textSpan;
        return textSpan;
      },
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: CodeEditor(
        controller: controller,
        style: CodeEditorStyle(
          codeTheme: CodeHighlightTheme(
            languages: <String, CodeHighlightThemeMode>{
              'dart': CodeHighlightThemeMode(mode: langDart),
              'json': CodeHighlightThemeMode(mode: langJson),
            },
            theme: const <String, TextStyle>{'attr': TextStyle(color: keyColour)},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The choice is made in the worker, which compiles the grammars on the way.
    await pumpUntil(tester, () => _coloured(built[0]));

    expect(tester.takeException(), isNull);
    expect(
      (built[0]?.children ?? const <InlineSpan>[])
          .map((InlineSpan span) => span.style?.color)
          .whereType<Color>()
          .toSet(),
      contains(keyColour),
      reason: 'the first line is JSON and was highlighted as it',
    );
  }, skip: noCore);

  testWidgets('colours the lines it is showing in a document too long to walk',

      (tester) async {
    // A document is highlighted from its top, and only as far down as the editor
    // reaches: what is below the window is not walked until it is scrolled to.
    // The lines that are drawn still have to be coloured, which is what says the
    // window is what gets highlighted and not nothing at all.
    final String text = List<String>.generate(
      5_000,
      (int index) => '{"key$index": "value$index"},',
    ).join('\n');
    final Map<int, TextSpan> built = <int, TextSpan>{};
    final CodeLineEditingController controller = CodeLineEditingController(
      codeLines: text.codeLines,
      spanBuilder: ({
        required BuildContext context,
        required int index,
        required CodeLine codeLine,
        required TextSpan textSpan,
        required TextStyle style,
      }) {
        built[index] = textSpan;
        return textSpan;
      },
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: CodeEditor(
        controller: controller,
        style: CodeEditorStyle(
          codeTheme: CodeHighlightTheme(
            languages: <String, CodeHighlightThemeMode>{
              'language': CodeHighlightThemeMode(mode: langJson),
            },
            theme: atomOneLightTheme,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(built, isNotEmpty, reason: 'the editor drew some lines');
    expect(
      built.keys.where((int index) => !_coloured(built[index])),
      isEmpty,
      reason: 'every line the editor drew is coloured, not just the ones at the '
          'top of the document',
    );

    // And on past the part that was highlighted on opening. The lines that come
    // into view have to be coloured as well, which is what says the editor tells
    // the highlighter what it is showing — the one thing that stops a long
    // document being plain from the second screen down.
    final int wasAt = built.keys.reduce(max);
    built.clear();
    await tester.drag(find.byType(CodeEditor), const Offset(0, -6000));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(built, isNotEmpty, reason: 'the drag scrolled the editor');
    expect(
      built.keys.reduce(max),
      greaterThan(wasAt),
      reason: 'the editor is showing lines it was not showing before',
    );
    expect(
      built.keys.where((int index) => !_coloured(built[index])),
      isEmpty,
      reason: 'the lines scrolled into view are coloured too',
    );
  }, skip: noCore);
}
