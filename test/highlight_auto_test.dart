// Which language a document is written in, when the theme offers several.
//
// Two things to get right, and they are separate: the rule that picks between
// scores, and the scores themselves. The rule is a few lines and is tested
// against highlight.js's three cases; the scores are the Rust core's, and are
// tested by asking both implementations the same question — a document in one
// language, a theme offering two, and whether they agree on which it is.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_editor/src/native/auto_detect.dart';
import 'package:re_editor/src/native/grammar_json.dart';
import 'package:re_editor/src/native/native.dart';
import 'package:re_highlight/languages/all.dart' as languages;
import 'package:re_highlight/re_highlight.dart';

/// One language's case, with the score spelled out.
NativeHighlightCandidate candidate(String name, double relevance, {String? supersetOf}) =>
    NativeHighlightCandidate(name: name, relevance: relevance, supersetOf: supersetOf);

void main() {
  group('the rule', () {
    test('takes the highest score', () {
      expect(
        bestLanguage(<NativeHighlightCandidate>[
          candidate('a', 1),
          candidate('b', 5),
          candidate('c', 3),
        ]),
        'b',
      );
    });

    test('keeps the first of two that scored the same', () {
      // highlight.js sorts stably on relevance, so the language a theme lists
      // first is the one a tie goes to.
      expect(
        bestLanguage(<NativeHighlightCandidate>[
          candidate('a', 4),
          candidate('b', 4),
        ]),
        'a',
      );
    });

    test('gives way to the narrower language it is a superset of', () {
      // A document written in C is also valid C++, and a theme offering both
      // wants the answer that says more.
      expect(
        bestLanguage(<NativeHighlightCandidate>[
          candidate('cpp', 4, supersetOf: 'c'),
          candidate('c', 4),
        ]),
        'c',
      );
      // And the other order gives the same answer.
      expect(
        bestLanguage(<NativeHighlightCandidate>[
          candidate('c', 4),
          candidate('cpp', 4, supersetOf: 'c'),
        ]),
        'c',
      );
    });

    test('a higher score still wins over being narrower', () {
      expect(
        bestLanguage(<NativeHighlightCandidate>[
          candidate('c', 4),
          candidate('cpp', 9, supersetOf: 'c'),
        ]),
        'cpp',
      );
    });

    test('answers nothing when there is nothing to choose between', () {
      expect(bestLanguage(const <NativeHighlightCandidate>[]), isNull);
    });
  });

  group('the scores', () {
    final ReEditorNativeApi? api = createReEditorNativeApi();

    // Transcribed once, before any test highlights with them: `re_highlight`
    // compiles a language by rewriting it in place, and a language that has been
    // through that cannot be transcribed exactly. Doing it here is the same
    // ordering the editor uses, where a grammar is transcribed when the theme is
    // set and highlighted afterwards.
    late final Map<String, String> transcribed;
    setUpAll(() {
      transcribed = <String, String>{
        for (final String name in <String>['json', 'dart'])
          name: jsonEncode(nativeGrammarJson(languages.builtinAllLanguages[name]!)),
      };
    });
    final String? skip = api == null
        ? 'no native core (${ReEditorNative.backendDescription})'
        : null;

    /// What the Dart implementation decides, for the same document.
    String? dartChoice(List<String> names, String code) {
      final Highlight highlight = Highlight();
      highlight.registerLanguages(<String, Mode>{
        for (final String name in names) name: languages.builtinAllLanguages[name]!,
      });
      // `AutoHighlightResult` carries the best of them as itself: its
      // language, its relevance, and so on.
      return highlight.highlightAuto(code, names).language;
    }

    /// What the core decides, with the same rule applied to its scores.
    String? nativeChoice(List<String> names, String code) {
      final List<NativeHighlightCandidate> candidates = <NativeHighlightCandidate>[];
      for (final String name in names) {
        final NativeGrammar grammar = api!.compileGrammar(json: transcribed[name]!)!;
        final NativeHighlightResult result = grammar.highlight(code);
        grammar.dispose();
        candidates.add(NativeHighlightCandidate(
          name: name,
          relevance: result.relevance,
          supersetOf: languages.builtinAllLanguages[name]!.supersetOf,
        ));
      }
      return bestLanguage(candidates);
    }

    test('agree on a JSON document, offered JSON and Dart', () {
      const String code = '{"a": [1, 2, 3], "b": {"c": null}, "d": "text"}\n';
      expect(nativeChoice(<String>['json', 'dart'], code),
          dartChoice(<String>['json', 'dart'], code));
    }, skip: skip);

    test('agree on a Dart document, offered JSON and Dart', () {
      // The mirror of the case above: the same two languages, a document in the
      // other one. This is what says the scores are comparable at all — that
      // they are not merely both numbers.
      const String code = 'import "dart:io";\n\n'
          'class A {\n  final String name;\n  A(this.name);\n}\n'
          'void main() {\n  final a = A("x");\n  print(a.name);\n}\n';
      expect(nativeChoice(<String>['json', 'dart'], code),
          dartChoice(<String>['json', 'dart'], code));
    }, skip: skip);
  });
}
