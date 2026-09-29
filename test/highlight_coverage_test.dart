// How much of the language catalogue the core can highlight, and what stops the
// rest.
//
// Not a behaviour test: it is the answer to "how much of this is native now",
// written down so that it is checked rather than remembered. It fails when the
// answer moves in either direction — a language that becomes transcribable
// should be noticed, and so should one that stops being.
//
// Every language that ships is taken by the core. The list below was never empty
// — Mathematica was the last of them, held out because the table its callback
// reads is private to the Dart package; it is in the core now, beside the
// callback.
//
// The Dart highlighter is not a second implementation of this: it is
// `re_highlight` itself, which an application can use directly wherever this one
// has nothing to call — a web build, or a machine with no native library.
//
// Transcribing is the whole of the test, and it has to be: `re_highlight`
// compiles a language in place, so a file that highlighted anything first would
// be measuring that instead. This file highlights nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/src/native/grammar_json.dart';
import 'package:re_highlight/languages/all.dart' as languages;
import 'package:re_highlight/re_highlight.dart';

void main() {
  test('the core takes every language that ships', () {
    final Map<String, String> refused = <String, String>{};
    for (final MapEntry<String, Mode> entry in languages.builtinAllLanguages.entries) {
      if (nativeGrammarJson(entry.value) == null) {
        refused[entry.key] = nativeGrammarRefusal(entry.value) ?? 'refused';
      }
    }

    final int total = languages.builtinAllLanguages.length;
    // ignore: avoid_print
    print('transcribable: ${total - refused.length} of $total');
    for (final MapEntry<String, String> entry in refused.entries) {
      // ignore: avoid_print
      print('  ${entry.key}: ${entry.value}');
    }

    expect(
      refused,
      isEmpty,
      reason: 'the core no longer takes every language; whichever one is '
          'refused above is the reason, and it belongs in the refusal rather '
          'than here',
    );
  });
}
