/// The grammar JSON the Rust core reads, built from a `re_highlight` language.
///
/// The Rust side parses the same field names `re_highlight` uses, so this is
/// mostly a transcription — but not quite, and the differences are the whole
/// reason this file exists:
///
/// * `className` is the name `scope` had before highlight.js renamed it, and
///   the Rust side knows only the new one.
/// * A mode that refers to itself is written `self` there and
///   `selfReferential` here.
/// * A callback is a Dart function there and a name here, so one has to be
///   recognised from the other.
///
/// Values are copied as they are otherwise, including the ones the Rust side
/// reads without changing, so a grammar can be diffed against its source in
/// `re_highlight` by reading the two side by side.
library;

import 'package:re_highlight/languages/lib/common.dart' as common;
import 'package:re_highlight/languages/lib/javascript.dart' as javascript;
import 'package:re_highlight/languages/lib/mathematica.dart' as mathematica;
import 'package:re_highlight/languages/lib/php.dart' as php;
import 'package:re_highlight/re_highlight.dart';

/// Builds the JSON for [language], or returns `null` when the Rust core cannot
/// be trusted with it.
///
/// `null` is not a failure to report: it means "highlight this one with the
/// Dart implementation", which is what every other part of the native seam does
/// when it cannot answer. A language is refused when transcribing it would not
/// be exact, because the alternative is an editor whose colours depend on which
/// implementation happened to load.
///
/// **Call this before the Dart highlighter has used the language.** `re_highlight`
/// compiles a language by rewriting it in place — following `ref`s, turning
/// `match` into `begin`, marking modes compiled — so once it has run, the mode
/// graph no longer says what the grammar said, and a mode that has been compiled
/// is refused rather than guessed at.
Map<String, dynamic>? nativeGrammarJson(Mode language) {
  try {
    return _modeJson(language);
  } on _Unsupported {
    return null;
  }
}

/// Why [language] cannot be transcribed, or `null` when it can.
///
/// The same question [`nativeGrammarJson`] answers by returning `null`, asked
/// in a way that can be logged and asserted on. A language falls back to the
/// Dart highlighter because of one field, and finding out which one by
/// bisecting the grammar is not a thing to ask of whoever reads the log.
String? nativeGrammarRefusal(Mode language) {
  try {
    _modeJson(language);
    return null;
  } on _Unsupported catch (error) {
    return error.reason;
  }
}

/// The grammars [json] reaches through `subLanguage`, by name.
///
/// A grammar does not carry the languages it embeds — a rule names one, and the
/// engine looks it up — so a caller compiling [json] has to know which others to
/// send with it. Every name mentioned is reported, including the alternatives a
/// mode offers, since the engine picks whichever is there.
Set<String> nativeGrammarSubLanguages(Map<String, dynamic> json) {
  final Set<String> names = <String>{};
  void walk(Object? value) {
    if (value is Map) {
      value.forEach((Object? key, Object? entry) {
        if (key == 'subLanguage') {
          if (entry is String) {
            names.add(entry);
          } else if (entry is List) {
            names.addAll(entry.whereType<String>());
          }
        }
        walk(entry);
      });
    } else if (value is List) {
      value.forEach(walk);
    }
  }

  walk(json);
  return names;
}

/// Names a mode in a refusal, by whatever it calls itself.
String _describe(Mode mode) {
  final String? name = mode.label ?? mode.name;
  if (name != null && name.isNotEmpty) {
    return name;
  }
  final Object? begin = mode.begin;
  return begin is String ? 'begin: $begin' : 'unnamed';
}

/// Raised where a value has no faithful transcription, naming it.
///
/// Carried out of the walk rather than returned, because every helper below
/// would otherwise have to tell "absent" and "cannot be said" apart, and only
/// the second one is worth failing over.
class _Unsupported implements Exception {
  const _Unsupported(this.reason);

  /// What could not be transcribed, for whoever has to read the log line that
  /// says this language is falling back to the Dart implementation.
  final String reason;
}

Map<String, dynamic> _modeJson(Mode mode) {
  if (mode.isCompiled == true) {
    throw _Unsupported(
      'the "${_describe(mode)}" mode has already been compiled by the Dart '
      'highlighter, which rewrites a grammar in place — and languages share '
      'sub-modes, so highlighting one language can compile a mode another needs',
    );
  }
  final Map<String, dynamic> json = <String, dynamic>{};

  void put(String key, Object? value) {
    if (value != null) {
      json[key] = value;
    }
  }

  put('name', mode.name);
  put('caseInsensitive', mode.caseInsensitive);
  // Read from the language rather than from the mode it is written on, on both
  // sides: `re_highlight` reads the root's flag and ignores a nested one, and
  // so does the Rust engine.
  put('unicodeRegex', mode.unicodeRegex);
  put('disableAutodetect', mode.disableAutodetect);
  put('aliases', mode.aliases);
  put('classNameAliases', mode.classNameAliases);
  put('supersetOf', mode.supersetOf);
  put('label', mode.label);
  put('relevance', mode.relevance);
  put('lexemes', mode.lexemes);
  put('beginKeywords', mode.beginKeywords);
  put('beforeMatch', mode.beforeMatch);
  put('ref', mode.ref);

  put('begin', _patterns(mode.begin, 'begin'));
  put('end', _patterns(mode.end, 'end'));
  put('match', _patterns(mode.match, 'match'));
  put('illegal', _illegal(mode.illegal, 'illegal'));

  // `className` is what a grammar written before the rename says, and either
  // name ends up as `scope` on the other side. The field is deprecated for
  // *writing* grammars; reading it is the only way to hold up the old ones.
  // ignore: deprecated_member_use
  put('scope', _scope(mode.scope ?? mode.className, 'scope'));
  put('beginScope', _scope(mode.beginScope, 'beginScope'));
  put('endScope', _scope(mode.endScope, 'endScope'));

  put('contains', _modeList(mode.contains, 'contains'));
  put('variants', _modeList(mode.variants, 'variants'));
  put('starts', mode.starts == null ? null : _modeJson(mode.starts!));

  put('endsParent', mode.endsParent);
  put('endsWithParent', mode.endsWithParent);
  put('endSameAsBegin', mode.endSameAsBegin);
  put('excludeBegin', mode.excludeBegin);
  put('excludeEnd', mode.excludeEnd);
  put('returnBegin', mode.returnBegin);
  put('returnEnd', mode.returnEnd);
  put('skip', mode.skip);
  put('selfReferential', mode.self);

  put('keywords', _keywords(mode.keywords, 'keywords'));
  put('subLanguage', _subLanguage(mode.subLanguage, 'subLanguage'));

  put('onBegin', _callback(mode.onBegin, 'onBegin'));
  put('onEnd', _callback(mode.onEnd, 'onEnd'));
  put('beforeBegin', _callback(mode.beforeBegin, 'beforeBegin'));

  // On the language itself, `refs` holds the modes its `ref` fields point at.
  // A language written without any is the usual case.
  if (mode.refs != null) {
    final Map<String, dynamic> refs = <String, dynamic>{};
    mode.refs!.forEach((String name, dynamic ref) {
      if (ref is! Mode) {
        throw const _Unsupported('a ref that is not a mode');
      }
      refs[name] = _modeJson(ref);
    });
    json['refs'] = refs;
  }

  return json;
}

/// A pattern: one, or the several parts of a multi-part one.
///
/// The Dart side writes these as strings, but its own grammars are generated
/// and a hand-written language may use a `RegExp` — which says the same thing,
/// and means the same thing to the Rust engine, which is ECMAScript's dialect
/// as well.
Object? _patterns(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  if (value is RegExp) {
    return value.pattern;
  }
  if (value is List) {
    return value.map<String>((Object? part) {
      if (part is String) {
        return part;
      }
      if (part is RegExp) {
        return part.pattern;
      }
      throw _Unsupported(field);
    }).toList();
  }
  throw _Unsupported(field);
}

/// `illegal`, which is a pattern, several, or `true` for "nothing is legal".
Object? _illegal(Object? value, String field) {
  if (value == true) {
    return true;
  }
  return _patterns(value, field);
}

/// One scope for the whole match, or one per match group.
///
/// A per-group scope is keyed by group number on the Dart side and has to be
/// keyed by the same number as a string here, because that is what JSON object
/// keys are — and the Rust side reads them back as numbers.
Object? _scope(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  if (value is Map) {
    final Map<String, Object?> scopes = <String, Object?>{};
    value.forEach((Object? group, Object? scope) {
      if (scope is! String) {
        throw _Unsupported(field);
      }
      scopes['$group'] = scope;
    });
    return scopes;
  }
  // A scope that has already been through `re_highlight`'s compiler is a
  // compiled scope object rather than a name or a map, and says nothing this
  // side could transcribe.
  throw _Unsupported(field);
}

/// `contains` and `variants`, which a grammar may write as one mode rather than
/// a list of one.
List<Map<String, dynamic>>? _modeList(Object? value, String field) {
  if (value == null) {
    return null;
  }
  final List<Object?> modes = value is List ? value : <Object?>[value];
  return modes.map<Map<String, dynamic>>((Object? entry) {
    if (entry is! Mode) {
      throw _Unsupported(field);
    }
    return _modeJson(entry);
  }).toList();
}

/// The words a mode colours, and the pattern they are found with.
///
/// A grammar writes them as a string, a list, or a map of scope to words —
/// nested to any depth — with `$pattern` naming the pattern the words are
/// matched with rather than a scope to colour. All of that is passed through as
/// written, because the Rust compiler reads the same shape, including that key.
Object? _keywords(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  if (value is RegExp) {
    return value.pattern;
  }
  if (value is List) {
    return value.map<String>((Object? word) {
      if (word is String) {
        return word;
      }
      if (word is RegExp) {
        return word.pattern;
      }
      throw _Unsupported(field);
    }).toList();
  }
  if (value is Map) {
    final Map<String, Object?> keywords = <String, Object?>{};
    value.forEach((Object? scope, Object? words) {
      if (scope is! String) {
        throw _Unsupported(field);
      }
      keywords[scope] = _keywords(words, scope);
    });
    return keywords;
  }
  throw _Unsupported(field);
}

/// The language a mode's contents are highlighted as, once it ends.
Object? _subLanguage(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  if (value is List) {
    return value.map<String>((Object? name) {
      if (name is! String) {
        throw _Unsupported(field);
      }
      return name;
    }).toList();
  }
  // Older grammars name a sub-language and its options in a map; the Rust side
  // models a name, or several candidate names.
  throw _Unsupported(field);
}

/// The name the Rust side knows a callback by.
///
/// The candidates are the callbacks that ship with `re_highlight`, recognised by
/// identity. A grammar's own closure is not one of them and is refused rather
/// than guessed at: its behaviour is Dart code the core cannot read, and a
/// grammar highlighted without it is a grammar with different colours.
String? _callback(ModeCallback? callback, String field) {
  if (callback == null) {
    return null;
  }
  if (callback == common.callbackOnBegin1) {
    return 'SAME_AS_BEGIN';
  }
  if (callback == common.callbackOnEnd1) {
    return 'SAME_AS_END';
  }
  if (callback == common.callbackOnBegin2) {
    return 'SHEBANG';
  }
  // PHP's heredoc: the marker is the first group, or the second when the first
  // did not match, and the end is checked by the same `SAME_AS_END`.
  if (callback == php.callbackOnBegin) {
    return 'SAME_AS_BEGIN_SECOND';
  }
  if (callback == php.callbackOnEnd) {
    return 'SAME_AS_END';
  }
  // JavaScript's `<` rule: whether what follows is a type parameter list rather
  // than a tag. TypeScript re-exports the same closure, so it lands here too.
  if (callback == javascript.callbackOnBegin) {
    return 'JSX_OR_GENERIC';
  }
  // Mathematica's: reject unless the text is a system symbol. The table itself
  // is in the core, next to the callback that reads it.
  if (callback == mathematica.callbackOnBegin) {
    return 'MATHEMATICA_SYMBOL';
  }
  throw _Unsupported(field);
}
