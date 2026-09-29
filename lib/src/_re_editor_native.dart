part of re_editor;

/// Set with `--dart-define=RE_EDITOR_FORCE_DART=true`.
///
/// A compile-time constant rather than an environment variable, because
/// `dart:io` is not available on the web and this file is compiled everywhere.
/// Its purpose is to let the test suite exercise the fallback path on a machine
/// where the native library *is* present — otherwise the Dart implementation
/// would only ever run on the web, and rot unnoticed.
const bool _kForcePureDart = bool.fromEnvironment('RE_EDITOR_FORCE_DART');

/// Access to the Rust core, when this build has one.
///
/// Every hot path in the editor asks here first and falls back to its Dart
/// implementation when the answer is no. Nothing else in the package imports
/// `dart:ffi`, and nothing else needs a platform check.
///
/// The native library is optional by design, for three separate reasons:
/// a consumer may not have a Rust toolchain, the web has no native code at all,
/// and a stale bundled library must degrade rather than misread. Probing once
/// and caching keeps all three to a single branch at the call site.
abstract final class ReEditorNative {
  static ReEditorNativeApi? _api;
  static NativeAbiInfo? _abiInfo;
  static Future<void>? _probing;
  static bool _settled = false;

  /// Whether this platform can host the native core at all.
  ///
  /// `false` only where there is neither `dart:ffi` nor `dart:js_interop`.
  /// Distinct from [isAvailable], which is about whether a usable core was
  /// actually found here and now.
  static bool get isPlatformSupported => nativePlatformSupported;

  /// Looks for the core and waits for the answer.
  ///
  /// Everything else here is synchronous and answers about the core as it
  /// stands at the moment it is asked, which is what lets an editor fall back
  /// without awaiting anything in a build method. On the web that means the
  /// first frames can find nothing: the core is a module that has to be fetched
  /// and instantiated, and there is no synchronous way to wait for that.
  ///
  /// So a caller that wants the core — a test, an application's `main` — asks
  /// for it here, once, before the work that wants it starts.
  static Future<void> prepare() {
    _ensureProbed();
    return _probing ?? Future<void>.value();
  }

  /// Whether the core is still being looked for.
  ///
  /// [isAvailable] cannot tell "not yet" from "never", and anything that caches
  /// its answer needs the difference: a document opened in the first frames on
  /// the web would otherwise keep the Dart implementation for its whole life
  /// over a race it lost.
  static bool get isLoading {
    _ensureProbed();
    return !_settled;
  }

  /// Whether the native core is loaded and usable.
  ///
  /// Probing is deferred to the first call so that importing the editor never
  /// does native work, and the result is cached — a `try`/`catch` around a
  /// symbol lookup is not something to repeat per keystroke.
  static bool get isAvailable {
    _ensureProbed();
    return _api != null;
  }

  /// Identity of the loaded library, or `null` when there is none.
  static NativeAbiInfo? get abiInfo {
    _ensureProbed();
    return _abiInfo;
  }

  /// A one-line description of which implementation is live, for logs and
  /// diagnostics. Cheap enough to call from a debug overlay.
  static String get backendDescription {
    if (!isAvailable) {
      if (_kForcePureDart) {
        return 'dart (native backend forced off by RE_EDITOR_FORCE_DART)';
      }
      // "Not yet" is worth saying beside "never". On the web the core is a
      // module that has to be fetched, so the first frames are honestly neither
      // — and a diagnostic that called that "the native library was not found"
      // would send someone looking for a file that is on its way.
      if (isLoading) {
        return 'dart (still looking for the native core)';
      }
      return isPlatformSupported ? 'dart (native library not found)' : 'dart (platform has no native code)';
    }
    final NativeAbiInfo? info = _abiInfo;
    return 'rust ${info?.coreVersion} (abi ${info?.abiVersion})';
  }

  static void _ensureProbed() {
    if (_probing != null) {
      return;
    }
    _probing = _probe();
  }

  static Future<void> _probe() async {
    try {
      if (_kForcePureDart) {
        return;
      }
      // Asked synchronously first, and on every platform but one that is the
      // whole of it: a linked library is there or it is not. This runs before
      // the first `await` below, so even though this method is asynchronous the
      // answer is in place by the time `_ensureProbed` returns — which is what
      // keeps `isAvailable` honest to a caller that asks in the next line.
      ReEditorNativeApi? api = createReEditorNativeApi();
      if (api == null) {
        // The web, where the core is a module that has to be fetched before
        // anything can be said about it.
        try {
          api = await loadReEditorNativeApi();
        } catch (error) {
          debugPrint('re_editor: the core could not be loaded: $error');
          return;
        }
        if (api == null) {
          return;
        }
      }
      // Reading the identity also validates that the wire format is readable at
      // all — a core that answers the version probe but cannot decode a
      // FlatBuffer is not one we want to route work through.
      final NativeAbiInfo info;
      try {
        info = api.readAbiInfo();
      } catch (error) {
        debugPrint('re_editor: the core answered the probe but not for itself: $error');
        return;
      }
      _abiInfo = info;
      _api = api;
    } finally {
      // Set whatever happened, so [isLoading] can stop saying yes.
      _settled = true;
    }
  }

  /// The loaded API, or `null`. Callers must have checked [isAvailable]; this
  /// exists so the branches below can be terse.
  static ReEditorNativeApi? get api {
    _ensureProbed();
    return _api;
  }

  /// Takes a native copy of a document, or `null` to say the caller should use
  /// its own implementation.
  ///
  /// Every failure mode collapses to `null` here — not loaded, would not take
  /// the lines, or threw. This runs while someone is typing, and none of those
  /// are worth interrupting an edit for; a caller that cannot tell them apart
  /// does not need to, because the response is the same in all three cases.
  static NativeDocument? openDocument(List<NativeLine> lines) {
    final ReEditorNativeApi? api = ReEditorNative.api;
    if (api == null) {
      return null;
    }
    try {
      return api.openDocument(lines);
    } catch (_) {
      return null;
    }
  }

  /// Takes a document to highlight in pieces, or `null` to say the caller
  /// should keep highlighting with its own implementation.
  ///
  /// As with [openDocument] and [compileGrammar], every way of failing is one
  /// answer: not loaded, a grammar this side will not highlight a line at a
  /// time, threw.
  static NativeHighlighter? openHighlighter(
    String json, {
    Map<String, String> subLanguages = const <String, String>{},
    required String text,
  }) {
    final ReEditorNativeApi? api = ReEditorNative.api;
    if (api == null) {
      return null;
    }
    try {
      return api.openHighlighter(json: json, subLanguages: subLanguages, text: text);
    } catch (_) {
      return null;
    }
  }

  /// Compiles a grammar for the native highlighter, or `null` to say the caller
  /// should keep highlighting with its own implementation.
  ///
  /// [json] is a language transcribed by `nativeGrammarJson`, and
  /// [subLanguages] holds the grammars its `subLanguage` rules reach, by name.
  ///
  /// As with [openDocument], every way of failing is one answer: not loaded,
  /// not a language this side can compile, threw. Nothing above has a different
  /// response to any of them, and the one that matters — the editor falling
  /// back to Dart — is the same in all three cases.
  static NativeGrammar? compileGrammar(
    String json, {
    Map<String, String> subLanguages = const <String, String>{},
  }) {
    final ReEditorNativeApi? api = ReEditorNative.api;
    if (api == null) {
      return null;
    }
    try {
      return api.compileGrammar(json: json, subLanguages: subLanguages);
    } catch (_) {
      return null;
    }
  }
}

/// A native copy of a document, kept in step with the Dart model.
///
/// The two are brought back together by sending only the span that differs,
/// which is the whole reason this exists: the document used to cross the
/// boundary in full on every keystroke, and encoding it cost more than the
/// analysis it was sent for.
class _NativeDocumentMirror {
  _NativeDocumentMirror._(this._document, this._lines);

  /// Mirrors `codeLines`, or returns `null` if there is nothing to mirror onto.
  static _NativeDocumentMirror? open(CodeLines codeLines) {
    final List<CodeLine> lines = codeLines.toList();
    final NativeDocument? document =
        ReEditorNative.openDocument(lines.map(_nativeLine).toList());
    if (document == null) {
      return null;
    }
    return _NativeDocumentMirror._(document, lines);
  }

  final NativeDocument _document;

  /// The lines the native document was last brought up to date with.
  ///
  /// Held on to so the next sync has something to compare against. These are
  /// the same `CodeLine` objects the model holds, so this keeps one generation
  /// of them alive rather than copying anything.
  List<CodeLine> _lines;

  /// Brings the native document in line with [codeLines].
  ///
  /// Throws if the native side refuses the edit, which means the two have
  /// diverged — the caller is expected to stop using this mirror.
  void sync(CodeLines codeLines) {
    final List<CodeLine> current = codeLines.toList();

    // The one span that differs. Lines are immutable and shared between
    // documents — an edit replaces the lines it touches and leaves the rest as
    // the very same objects — so `identical` is the entire comparison, and the
    // scan costs O(prefix + suffix) rather than O(document).
    //
    // It errs in the safe direction: a line rebuilt with unchanged text is
    // reported as changed, and the native side compares the text itself and
    // decides. The reverse — reporting no change when there was one — is what
    // this must never do, and identity cannot say "equal" about two different
    // immutable objects.
    int start = 0;
    final int shared = min(_lines.length, current.length);
    while (start < shared && identical(_lines[start], current[start])) {
      start++;
    }
    int before = _lines.length;
    int after = current.length;
    while (before > start &&
        after > start &&
        identical(_lines[before - 1], current[after - 1])) {
      before--;
      after--;
    }

    // Sent even when nothing appears to have changed: an empty splice is a
    // cheap no-op on the native side, and skipping it here would be one more
    // way for the two to drift apart.
    _document.splice(
      start: start,
      removed: before - start,
      added: current
          .sublist(start, after)
          .map(_nativeLine)
          .toList(),
    );
    _lines = current;
  }

  /// Finds the collapsible regions, in the collapsed view.
  NativeChunkAnalysis analyzeChunks() => _document.analyzeChunks();

  /// Finds [pattern], in the flattened view.
  ///
  /// The two views differ on purpose: a folded region must stay folded for
  /// bracket analysis, and must stay findable for search.
  Future<NativeFindResult?> find({
    required String pattern,
    required bool caseSensitive,
    required bool regex,
  }) =>
      _document.find(pattern: pattern, caseSensitive: caseSensitive, regex: regex);

  /// The line as the native document wants it.
  ///
  /// `flat()` is the line followed by everything it hides, so dropping the
  /// first entry leaves exactly the hidden lines. Guarded by `chunkParent`
  /// because `flat()` allocates, and it would do so for every line of every
  /// edit to return what is almost always an empty list.
  static NativeLine _nativeLine(CodeLine line) {
    if (!line.chunkParent) {
      return NativeLine(line.text);
    }
    return NativeLine(line.text, line.flat().skip(1).toList());
  }

  void dispose() => _document.dispose();
}
