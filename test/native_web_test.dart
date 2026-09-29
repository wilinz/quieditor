// The Rust core, running in a browser.
//
// Every other native test runs on the VM against a linked library. This one
// runs through `WebAssembly`, and almost nothing about the crossing is the
// same: there are no symbols to resolve, the memory is the module's own, and
// the room for a request has to be asked for. What it checks is that the same
// answers come out of it — the same lines, the same folds, the same scopes —
// because the point of a second transport is that the editor above it cannot
// tell which one it got.
//
//   flutter test --platform chrome test/native_web_test.dart \
//     --dart-define=RE_EDITOR_WEB_MODULE=http://127.0.0.1:8789/quieditor_wasm.wasm
//
// The module is not in this package, by design — see doc/web_build.md — and the
// test server does not serve it, so the URL has to be given. Without it this
// skips rather than pretending to pass: a browser test that silently tested
// nothing would be the same trap the web arm itself nearly was.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' show ReEditorNative;
import 'package:re_editor/src/native/native.dart';
import 'package:re_editor/src/native/native_api.dart';
import 'package:re_editor/src/native/native_wasm.dart';

/// Where a server has the module. Empty unless one was named.
///
/// A `const` because `skip` is decided when the tests are registered, which is
/// before anything could be fetched.
const String _moduleUrl = String.fromEnvironment('RE_EDITOR_WEB_MODULE');

void main() {
  final String? skip = _moduleUrl.isEmpty
      ? 'no module URL: pass --dart-define=RE_EDITOR_WEB_MODULE=<url> with a '
          'server that has quieditor_wasm.wasm. See doc/web_build.md.'
      : null;

  late ReEditorNativeApi api;

  setUpAll(() async {
    if (skip != null) {
      return;
    }
    configureReEditorWeb(moduleUrl: _moduleUrl);
    // The same door an application uses, rather than reaching past it for the
    // transport: `ReEditorNative` is what has to end up with the core, and on
    // the web the only way it gets one is by being waited for.
    await ReEditorNative.prepare();
    expect(
      ReEditorNative.isAvailable,
      isTrue,
      reason: 'the module at $_moduleUrl did not load',
    );
    api = ReEditorNative.api!;
  });

  group('the wasm arm', () {
    test('reports the ABI the module was built against', () {
      expect(api.readAbiInfo().abiVersion, api.abiVersion);
      expect(ReEditorNative.backendDescription, startsWith('rust '));
    });

    test('holds a document and answers for it', () async {
      final NativeDocument document = api.openDocument(<NativeLine>[
        const NativeLine('abc('),
        const NativeLine('abc'),
        const NativeLine('abc)'),
        const NativeLine('found "needle" here'),
      ])!;
      expect(document.lineCount, 4);
      expect(document.revision, 0);
      expect(document.analyzeChunks().chunks, <NativeChunk>[
        const NativeChunk(index: 0, end: 2),
      ]);

      expect(
        document.splice(
          start: 1,
          removed: 1,
          added: <NativeLine>[const NativeLine('XYZ')],
        ),
        isTrue,
      );
      expect(document.revision, 1);

      // The revision inside the response as well as beside it: the field is a
      // `ulong`, and a `ulong` is the one thing the generated reader cannot read
      // the way every other platform does.
      final NativeFindResult? found = await document.find(
        pattern: 'needle',
        caseSensitive: true,
        regex: false,
      );
      expect(found!.matches.single.startLine, 3);
      expect(found.matches.single.startOffset, 7);
      expect(found.revision, 1);

      document.dispose();
    });

    test('highlights with a compiled grammar', () {
      final NativeGrammar grammar = api.compileGrammar(json: _json)!;
      final NativeHighlightResult result = grammar.highlight('for x = "a"');
      expect(
        result.nodes.map((NativeHighlightNode node) => node.scope).toList(),
        <String>['keyword', 'string'],
      );
      expect(result.relevance, greaterThan(0));
      grammar.dispose();
    });

    test('highlights a document in pieces', () {
      final NativeHighlighter highlighter = api.openHighlighter(
        json: _json,
        text: 'for x = "a"\nfor y = "b"',
      )!;
      final NativeHighlightChunk scanned = highlighter.scan(100);
      expect(scanned.from, 0);
      expect(
        scanned.nodes.map((NativeHighlightNode node) => node.scope).toList(),
        <String>['keyword', 'string', 'keyword', 'string'],
      );

      final NativeHighlightUpdate update = highlighter.splice(
        start: 0,
        removed: 1,
        added: <String>['for z = "c"'],
      );
      expect(update.from, 0);
      expect(update.scannedTo, greaterThan(0));
      highlighter.dispose();
    });

    test('refuses what the other platforms refuse', () async {
      expect(api.openDocument(<NativeLine>[const NativeLine('a\nb')]), isNull);
      expect(api.compileGrammar(json: '{'), isNull);
      expect(await api.openDocument(<NativeLine>[const NativeLine('a')])!
          .find(pattern: '(', caseSensitive: true, regex: true), isNull);
    });
  }, skip: skip);
}

/// A grammar in the shape `re_highlight` names its fields in, small enough to
/// read: one keyword table and one string rule.
const String _json = '{"name":"T","keywords":{"keyword":"for"},'
    '"contains":[{"scope":"string","begin":"\\"","end":"\\""}]}';
