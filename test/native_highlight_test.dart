// Pins the claim the whole native seam rests on: the Rust highlighter and the
// Dart one colour the same code the same way.
//
// What is compared is the scope tree, not the speed — that is the benchmark
// suite's job — because the class names are what every theme in the ecosystem
// keys on. A difference here is not a slow editor, it is a differently coloured
// one, and nobody reports that as a bug: it looks like the document changed.
//
// The comparison runs against real languages rather than a toy grammar. The
// engine is a port of a port, and what a real grammar reaches that a toy one
// does not — sub-modes shared through `ref`, a keyword inside a string, a
// heredoc that ends on its own marker — is where a port drifts.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_editor/src/native/grammar_json.dart';
import 'package:re_editor/src/native/highlight_spans.dart';
import 'package:re_editor/src/native/native.dart';
import 'package:re_highlight/languages/all.dart' as languages;
import 'package:re_highlight/re_highlight.dart';

/// The languages compared below, and the code each one is compared on.
const Map<String, String> _cases = <String, String>{
  'json': '{"a": 1, "b": [true, null]}\n',
  // Keywords, indentation and a string: the language that made the
  // `unicodeRegex` flag worth having, since Python asks for it.
  'python': 'x = "if for"\nif x:\n    pass\n',
  // Keywords, strings, escapes and comments, which is most of what a grammar
  // is made of.
  'go': 'package main\n\n// A comment.\nfunc main() { fmt.Println("hi") }\n',
  // Markup: attributes inside a tag, text between tags, and a comment.
  'xml': '<a href="x">text<b/>\n<!-- note -->\n</a>',
  // The third of the languages that ask for Unicode patterns.
  'haskell': 'module Main where\n\nmain :: IO ()\nmain = putStrLn "hi"\n',
  // Interpolation inside a string: the string mode contains modes of its own,
  // and they end where the interpolation ends rather than at the string's end.
  'ruby': 'def hello(name)\n  puts "hi #{name.upcase}"\nend\n',
  // The `<` rule: `<div>` is an element and `<T, A>` is a type parameter list,
  // and the two are told apart by what follows.
  'javascript': 'const f = <T, A>(a: T) => a;\nlet div = <div className="x">text</div>;\n',
  // The same rule, in the language that inherits it.
  'typescript': 'class A<T> {\n  value: T;\n}\nconst div = <div>x</div>;\n',
  // A heredoc whose marker is the second group rather than the first.
  'php': '<?php\n\$sql = <<<SQL\n  select 1\nSQL;\necho \$sql;\n',
  // A callback that reads a table rather than the text in front of it: `Table`
  // is a system symbol and `table` is not.
  'mathematica': 'Table[x, {x, 3}]\ntable = 1;\nPlot3D[f, {x, 0, 1}]\n',
  // The case that made the Dart callbacks necessary: the mode ends where it
  // says it does and nowhere else, and the marker is compared to the one the
  // mode began with.
  'bash': 'cat <<EOF\nnot the marker\nEOF\necho done\n',
  // Arduino and C++ are the grammars the compiler's notes call out: their graph
  // is shared enough that expanding it into a tree is what grows without bound,
  // so this is also a check that sharing survived the port. Its `${`-style
  // constructs are not the only thing here that nests in itself.
  'cpp': '#include <stdio.h>\nint main() { std::vector<int> v; std::cout << v[0]; }\n',
};

/// Every grammar, transcribed before anything is highlighted.
///
/// `re_highlight` compiles a language by rewriting it in place, and languages
/// share sub-modes with each other, so highlighting one language can compile a
/// mode another one needs. The transcription therefore has to happen while the
/// designations are still what their authors wrote — and for the same reason
/// the refusals have to be read here too, before a test uses any language.
final Map<String, Map<String, dynamic>> _grammars = <String, Map<String, dynamic>>{
  for (final MapEntry<String, String> entry in _cases.entries)
    if (_transcribe(entry.key) != null) entry.key: _transcribe(entry.key)!,
};

/// What each language was refused for, or nothing when it was accepted.
final Map<String, String> _refusals = <String, String>{
  for (final String name in _cases.keys)
    if (_transcribe(name) == null) name: nativeGrammarRefusal(_language(name))!,
};

Mode _language(String name) => languages.builtinAllLanguages[name]!;

Map<String, dynamic>? _transcribe(String name) => nativeGrammarJson(_language(name));

/// Highlights [code] with both implementations and expects them to agree.
void expectSameScopes(String language, String code) {
  final Map<String, dynamic>? json = _grammars[language];
  expect(json, isNotNull, reason: '$language was refused for: ${_refusals[language]}');

  final ReEditorNativeApi api = createReEditorNativeApi()!;
  final NativeGrammar? grammar = api.compileGrammar(
    json: jsonEncode(json),
    subLanguages: _subLanguages(json!),
  );
  expect(grammar, isNotNull, reason: '$language should compile natively');

  final List<(String, String)> fromNative =
      _scopesOf(code, grammar!.highlight(code).nodes);
  grammar.dispose();

  expect(fromNative, _dartScopes(language, code));
}

/// The same comparison through the incremental highlighter the editor keeps
/// open, rather than a one-shot call.
///
/// It works out its own offsets against line starts it holds itself, and nothing
/// else in this file asks it for any — which is how it came to count them in
/// bytes while every other path counted UTF-16 units, putting every span on a
/// line holding anything outside ASCII in the wrong place.
void expectSameScopesIncrementally(String language, String code) {
  final Map<String, dynamic>? json = _grammars[language];
  expect(json, isNotNull, reason: '$language was refused for: ${_refusals[language]}');

  // Through the API rather than `ReEditorNative`, which the comparison above
  // already goes through: `ReEditorNative` answers `null` for everything on a
  // build asked to use the Dart implementation, and then this would be testing
  // nothing while still reporting that it had.
  final NativeHighlighter? highlighter = createReEditorNativeApi()!.openHighlighter(
    json: jsonEncode(json!),
    subLanguages: _subLanguages(json),
    text: code,
  );
  expect(highlighter, isNotNull, reason: '$language should open natively');

  final List<(String, String)> fromNative = _scopesOf(code, highlighter!.spans());
  highlighter.dispose();

  expect(fromNative, _dartScopes(language, code));
}

/// The same comparison again, asking for the document a piece at a time.
///
/// What the editor does once it highlights only what it is showing: each call
/// covers the lines between the last one's stop and the line it asks for, and
/// the pieces together have to be what one whole scan would have said. The
/// offsets are the same answer asked for the same way, so a chunk boundary that
/// shifted them would show up here rather than on screen.
void expectSameScopesInChunks(String language, String code, List<int> chunks) {
  final Map<String, dynamic>? json = _grammars[language];
  expect(json, isNotNull, reason: '$language was refused for: ${_refusals[language]}');

  final NativeHighlighter highlighter = createReEditorNativeApi()!.openHighlighter(
    json: jsonEncode(json!),
    subLanguages: _subLanguages(json),
    text: code,
  )!;
  final List<NativeHighlightNode> nodes = <NativeHighlightNode>[];
  int scanned = 0;
  for (final int to in chunks) {
    final NativeHighlightChunk chunk = highlighter.scan(to);
    expect(
      chunk.from,
      scanned,
      reason: 'a scan carries on from where the last one stopped',
    );
    nodes.addAll(chunk.nodes);
    scanned = chunk.to;
  }
  highlighter.dispose();

  expect(scanned, code.split('\n').length, reason: 'the whole document was reached');
  expect(_scopesOf(code, nodes), _dartScopes(language, code));
}

/// The grammars [json] reaches through `subLanguage`, transcribed.
///
/// A grammar does not carry the languages it embeds, so they have to be sent
/// with it or the engine shows their text plain.
Map<String, String> _subLanguages(Map<String, dynamic> json) {
  final Map<String, String> out = <String, String>{};
  for (final String name in nativeGrammarSubLanguages(json)) {
    final Mode? definition = languages.builtinAllLanguages[name];
    if (definition == null) {
      continue;
    }
    final Map<String, dynamic>? sub = nativeGrammarJson(definition);
    if (sub != null) {
      out[name] = jsonEncode(sub);
    }
  }
  return out;
}

/// What the Dart implementation scoped, in the order it reports it: a node
/// before the nodes nested inside it, which is the order the native side uses.
List<(String, String)> _dartScopes(String language, String code) {
  final Highlight highlight = Highlight();
  highlight.registerLanguage(language, _language(language));
  final _ScopeCollector collector = _ScopeCollector();
  highlight.highlight(code: code, language: language).render(collector);
  return collector.scopes;
}

/// Records what a renderer would be told, in order.
///
/// This is the shape the editor draws from: the events, not the spans. Where a
/// node's text is split across lines, and where the text between two nodes goes,
/// are decided here — so this is the step that has to match, not just the
/// scopes.
class _EventCollector implements HighlightRenderer {
  final List<String> events = <String>[];

  @override
  void addText(String text) => events.add('text:${jsonEncode(text)}');

  @override
  void openNode(DataNode node) => events.add('open:${node.scope}');

  @override
  void closeNode(DataNode node) => events.add('close');
}

/// Replays the native answer for [language] over [code] into an event recorder.
List<String> _nativeEvents(String language, String code) {
  final Map<String, dynamic> json = _grammars[language]!;
  final ReEditorNativeApi api = createReEditorNativeApi()!;
  final NativeGrammar grammar = api
      .compileGrammar(json: jsonEncode(json), subLanguages: _subLanguages(json))!;
  final _EventCollector collector = _EventCollector();
  replayHighlightSpans(
    code: code,
    nodes: grammar.highlight(code).nodes,
    renderer: collector,
  );
  grammar.dispose();
  return collector.events;
}

/// The same, from the Dart implementation — which is what the editor used
/// before there was a choice, and what it still uses when the core cannot take a
/// language.
List<String> _dartEvents(String language, String code) {
  final Highlight highlight = Highlight();
  highlight.registerLanguage(language, _language(language));
  final _EventCollector collector = _EventCollector();
  highlight.highlight(code: code, language: language).render(collector);
  return collector.events;
}

/// Collects a scope and its text for every scoped node, and nothing for the
/// text between them — the same list the native side reports as spans.
class _ScopeCollector implements HighlightRenderer {
  final List<(String, String)> scopes = <(String, String)>[];

  @override
  void addText(String text) {}

  @override
  void openNode(DataNode node) {
    final String? scope = node.scope;
    if (scope != null && scope.isNotEmpty) {
      scopes.add((scope, _textOf(node)));
    }
  }

  @override
  void closeNode(DataNode node) {}

  /// A node's own text, which is the text of everything inside it.
  static String _textOf(DataNode node) {
    final StringBuffer buffer = StringBuffer();
    for (final Object? child in node.children) {
      if (child is DataNode) {
        buffer.write(_textOf(child));
      } else if (child is String) {
        buffer.write(child);
      }
    }
    return buffer.toString();
  }
}

/// The same thing, from the spans the native side reports.
///
/// Offsets are UTF-16 units within their line, which is what Dart's own string
/// indexing counts in, so the lines are cut where the engine said they were.
List<(String, String)> _scopesOf(String code, List<NativeHighlightNode> nodes) {
  final List<String> lines = code.split('\n');
  String textOf(NativeHighlightNode node) {
    if (node.startLine == node.endLine) {
      return lines[node.startLine].substring(node.startOffset, node.endOffset);
    }
    final StringBuffer buffer = StringBuffer(
      lines[node.startLine].substring(node.startOffset),
    );
    for (int line = node.startLine + 1; line < node.endLine; line++) {
      buffer
        ..write('\n')
        ..write(lines[line]);
    }
    buffer
      ..write('\n')
      ..write(lines[node.endLine].substring(0, node.endOffset));
    return buffer.toString();
  }

  return nodes
      .map((NativeHighlightNode node) => (node.scope, textOf(node)))
      .toList();
}

void main() {
  final ReEditorNativeApi? api = createReEditorNativeApi();
  final String? skip = api == null
      ? 'no native core (${ReEditorNative.backendDescription}) — this test is '
          'about the Rust highlighter agreeing with the Dart one'
      : null;

  group('native highlight', () {
    for (final MapEntry<String, String> entry in _cases.entries) {
      test('agrees on ${entry.key}', () {
        expectSameScopes(entry.key, entry.value);
      }, skip: skip);
    }
  });

  group('native highlight, incrementally', () {
    for (final MapEntry<String, String> entry in _cases.entries) {
      test('agrees on ${entry.key}', () {
        expectSameScopesIncrementally(entry.key, entry.value);
      }, skip: skip);
    }

    test('agrees when the text is not ascii', () {
      // The corpus is all ASCII, and a line of nothing but ASCII counts the same
      // in bytes as in UTF-16 — so it agrees whether or not the conversion
      // happens, which is why this went unnoticed. These are the two ways to
      // tell the units apart: a three-byte character, and one outside the basic
      // plane, which is four bytes but two UTF-16 units rather than one.
      expectSameScopesIncrementally('json', '{"a": "日本"}\n{"b": "café"}\n');
      expectSameScopesIncrementally('json', '{"a": "\u{1F600}"}\n{"b": "x"}\n');
    }, skip: skip);

    test('agrees when the document is asked for a piece at a time', () {
      // The chunk boundaries are the interesting part: a rule that straddles one
      // has to come out the same on the far side of it, and the offsets after a
      // multi-byte character have to survive being counted from a different
      // starting line.
      const String code = '{"a": "café"}\n'
          '{"b": "日本"}\n'
          '{"c": "plain"}\n'
          '{"d": 1}\n'
          '{"e": null}\n'
          '{"f": true}\n';
      expectSameScopesInChunks('json', code, <int>[1, 2, 3, 4, 5, 6]);
      expectSameScopesInChunks('json', code, <int>[2, 4, 5, 10]);
      expectSameScopesInChunks('json', code, <int>[10]);
      // Asking for a line already covered adds nothing, and asking for one past
      // the end is clamped to it rather than refused.
      expectSameScopesInChunks('json', code, <int>[3, 3, 2, 99]);
    }, skip: skip);
  });

  group('native highlight', () {
    test('replays into the same events the Dart side produces', () {
      // `ruby` because its nodes nest, span a line break, and are followed by
      // text: every way the replay can get the ordering wrong.
      const String language = 'ruby';
      const String code = 'def hello(name)\n  puts "hi #{name.upcase}"\nend\n';
      expect(_nativeEvents(language, code), _dartEvents(language, code));
    }, skip: skip);
  });

  group('what the seam refuses', () {
    test('a callback written by the grammar itself, not one of the built-ins', () {
      // The callbacks that ship with `re_highlight` are recognised by identity.
      // Anything else is a closure with behaviour this side cannot read, and a
      // grammar highlighted without it is a grammar with different colours.
      final Mode language = Mode(
        contains: <Mode>[
          Mode(begin: '<', onBegin: (match, response) {}),
        ],
      );
      expect(nativeGrammarJson(language), isNull);
      expect(nativeGrammarRefusal(language), contains('onBegin'));
    });

    test('a language the Dart side has already compiled', () {
      // A language of its own rather than a built-in: the built-ins are shared
      // singletons, so whether one of them is still pristine depends on what
      // else has run, and a test that depends on that is a test that passes for
      // the wrong reason.
      final Mode language = Mode(
        contains: <Mode>[Mode(scope: 'string', begin: '"', end: '"')],
      );
      expect(nativeGrammarJson(language), isNotNull);

      // Using a language compiles it in place, after which its fields are the
      // compiler's rather than the grammar author's.
      Highlight()
        ..registerLanguage('fixture', language)
        ..highlight(code: '"x"', language: 'fixture');

      expect(nativeGrammarJson(language), isNull);
    });

    test('a mode that refers to itself is transcribed as the Rust name', () {
      final Mode language = Mode(
        contains: <Mode>[Mode(scope: 'string', begin: '"', end: '"', self: true)],
      );
      final Map<String, dynamic>? json = nativeGrammarJson(language);
      expect(json, isNotNull);
      expect(
        (json!['contains']! as List<dynamic>).first,
        containsPair('selfReferential', true),
      );
    });
  });
}
