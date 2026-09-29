// Pins the invariant that makes the native document safe to rely on: after any
// sequence of edits, the analysis it holds is the one a fresh analysis of the
// same lines gives.
//
// `test/code_chunk_test.dart` already covers the controller's behaviour on both
// paths. What this adds is the equivalence itself — the mirror sends only the
// span that changed and the native side edits its copy in place, so the two can
// drift in ways a single-document test would never show.
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// What the core says about [codeLines], asked through a document of its own.
///
/// A second route to the same analysis rather than a second implementation of
/// it: the edit path keeps one document and patches it, this builds a document
/// from the lines as they are now. The two must agree, which is what says the
/// patching is right.
List<CodeChunk> freshChunks(CodeLines codeLines) =>
    const DefaultCodeChunkAnalyzer().run(codeLines);

/// Lets everything the controller scheduled — including the deferred
/// application of a native analysis — run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

/// Mirrors [source] and drives it through [edits], checking after every one
/// that the controller's chunks still match the Dart analyzer's answer.
Future<void> expectStaysInStep(
  String source,
  List<void Function(CodeLineEditingController)> edits,
) async {
  final CodeLineEditingController controller = CodeLineEditingController.fromText(source);
  final CodeChunkController chunks =
      CodeChunkController(controller, const DefaultCodeChunkAnalyzer());
  addTearDown(() {
    chunks.dispose();
    controller.dispose();
  });

  await settle();
  for (var i = 0; i < edits.length; i++) {
    edits[i](controller);
    await settle();
    expect(
      chunks.value,
      freshChunks(controller.codeLines),
      reason: 'after edit ${i + 1} of ${edits.length}',
    );
  }
}

void main() {
  // Without the native core this is the Dart analyzer compared against itself,
  // which proves nothing. Say so rather than passing quietly.
  final bool native = ReEditorNative.isAvailable;
  final String? skip = native
      ? null
      : 'no native core (${ReEditorNative.backendDescription}) — this test is '
          'about keeping the native document in step with the model';

  group('native document', () {
    test('follows a document through typing', () async {
      await expectStaysInStep('abc\ndef\nghi', <void Function(CodeLineEditingController)>[
        (c) => c.selectLine(0),
        (c) => c.replaceSelection('abc('),
        (c) => c.moveCursorToPageEnd(),
        (c) => c.replaceSelection(')'),
        (c) => c.selectLine(1),
        (c) => c.replaceSelection('['),
        (c) => c.moveCursorToPageEnd(),
        (c) => c.replaceSelection(']'),
      ]);
    }, skip: skip);

    test('follows lines being inserted and removed', () async {
      await expectStaysInStep('a(\nb\nc)', <void Function(CodeLineEditingController)>[
        // Open the region up.
        (c) => c.selectLine(1),
        (c) => c.replaceSelection(''),
        (c) => c.selectLine(1),
        (c) => c.replaceSelection(''),
        // Put more lines inside it, moving the closing bracket further away.
        (c) => c.selectLine(2),
        (c) => c.replaceSelection('x\ny\nz'),
        // And take them out again.
        (c) => c.selectLines(1, 3),
        (c) => c.deleteSelectionLines(),
      ]);
    }, skip: skip);

    test('follows a document that ends up empty', () async {
      await expectStaysInStep('a(\nb\nc)', <void Function(CodeLineEditingController)>[
        (c) => c.selectAll(),
        (c) => c.replaceSelection(''),
        (c) => c.replaceSelection('{'),
        (c) => c.replaceSelection('\n'),
        (c) => c.replaceSelection('\n'),
        (c) => c.replaceSelection('}'),
      ]);
    }, skip: skip);

    test('follows collapsing and expanding', () async {
      await expectStaysInStep(
        '{\nabc\n{\ndef\n}\n}',
        <void Function(CodeLineEditingController)>[
          (c) => c.collapseChunk(0, 5),
          (c) => c.expandChunk(0),
        ],
      );
    }, skip: skip);

    test('follows a long run of edits without drifting', () async {
      // The splice is where a mistake would hide: every edit sends a span
      // computed against the previous document, so an off-by-one compounds
      // instead of showing up immediately.
      await expectStaysInStep('a(\nb\nc)', <void Function(CodeLineEditingController)>[
        for (var i = 0; i < 20; i++) ...<void Function(CodeLineEditingController)>[
          (c) => c.moveCursorToPageEnd(),
          (c) => c.replaceSelection('x'),
          (c) => c.deleteBackward(),
        ],
      ]);
    }, skip: skip);

    test('reports a document it cannot take rather than guessing', () {
      // A line holding a newline of its own cannot survive the join-and-split
      // the wire format uses: one line would come apart as two, and every index
      // after it would be wrong. Refusing is the only safe answer.
      final NativeDocument? document =
          ReEditorNative.openDocument(const <NativeLine>[NativeLine('a\nb')]);
      expect(document, isNull);
      document?.dispose();
    }, skip: skip);

    test('carries folded content from the moment it opens', () async {
      // Opening and editing share one encoding. They did not at first, and the
      // document that resulted held two kinds of line: the ones it opened with,
      // which had lost what they hid, and the ones edited later, which had not.
      // A search over it silently missed whatever was folded away in the part
      // it opened with — which is what `code_search_controller_test.dart`'s
      // folded-document case catches.
      final NativeDocument? document = ReEditorNative.openDocument(const <NativeLine>[
        NativeLine('{', <String>['hidden line', 'another']),
        NativeLine('}'),
      ]);
      expect(document, isNotNull);
      // The search runs on a worker thread, so this awaits it.
      final NativeFindResult? found =
          await document!.find(pattern: 'another', caseSensitive: true, regex: false);
      document.dispose();

      expect(found, isNotNull);
      // Flattened line 2: "{", then "hidden line", then "another", then "}".
      expect(found!.matches.single.startLine, 2);
      expect(found.matches.single.startOffset, 0);
    }, skip: skip);

    test('takes a folded region whose whole content is empty', () {
      // A hidden line that is itself empty joins to the empty string, which is
      // also what *no* hidden lines join to. Deciding how many there were from
      // that string refused the edit, and the shape is an ordinary one: a `{`,
      // a blank line and a `}`.
      final NativeDocument? document = ReEditorNative.openDocument(
        const <NativeLine>[
          NativeLine('{'),
          NativeLine('}{', <String>['']),
          NativeLine('}'),
        ],
      );
      expect(document, isNotNull);
      document?.dispose();
    }, skip: skip);

    test('says how many lines the native side had when it refuses', () {
      // Everything else in the message is what the caller passed in — the side
      // that already knows. The count is the other side, and without it a
      // refusal reads as "your own numbers were wrong", which is the one thing
      // it does not mean.
      final NativeDocument? opened = ReEditorNative.openDocument(
        const <NativeLine>[NativeLine('a'), NativeLine('b')],
      );
      expect(opened, isNotNull);
      final NativeDocument document = opened!;
      expect(
        () => document.splice(start: 1, removed: 5, added: const <NativeLine>[]),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('against its 2 lines'),
          ),
        ),
      );
      // A refusal leaves the document alone, which is what makes reading the
      // count after one safe.
      expect(document.lineCount, 2);
      document.dispose();
    }, skip: skip);

    test('folds a region whose whole content is a blank line', () async {
      // The equivalence checks above cannot see this one, which is why it went
      // unnoticed: a refused mirror falls back to asking the core with the same
      // lines, that fails the same way, and the two agree on an empty answer —
      // so folding had stopped working while every comparison still held. What
      // has to be asserted is that the answer is not empty.
      final CodeLineEditingController controller =
          CodeLineEditingController.fromText('{\n\n}\n{\n\n}');
      final CodeChunkController chunks =
          CodeChunkController(controller, const DefaultCodeChunkAnalyzer());
      addTearDown(() {
        chunks.dispose();
        controller.dispose();
      });
      await settle();

      final int before = controller.codeLines.length;
      chunks.collapse(0);
      await settle();

      expect(chunks.value, isNotEmpty);
      expect(controller.codeLines.length, lessThan(before));
      // And the route through a fresh document, which the editor takes once the
      // mirror is gone.
      expect(freshChunks(controller.codeLines), isNotEmpty);
    }, skip: skip);
  });
}
