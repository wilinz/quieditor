/// The shape of the Rust core, described without a single `dart:ffi` type.
///
/// `native_ffi.dart` implements this on platforms that have `dart:ffi`;
/// `native_stub.dart` supplies nothing on the ones that do not. Keeping the
/// interface in its own library is what lets every caller above it be written
/// once and compiled everywhere — including the web, where `dart:ffi` does not
/// exist at all.
library;

/// Identity of the native library that is actually loaded.
///
/// Worth checking rather than assuming: an app can easily end up running a
/// stale bundled library, in which case the symbols resolve, the calls succeed,
/// and only the table layout is wrong.
class NativeAbiInfo {
  const NativeAbiInfo({
    required this.abiVersion,
    required this.coreVersion,
  });

  /// The ABI the library was compiled against.
  final int abiVersion;

  /// The `re_editor_core` version, for diagnostics.
  final String coreVersion;

  @override
  String toString() => 'NativeAbiInfo(abiVersion: $abiVersion, coreVersion: $coreVersion)';
}

/// A collapsible region: the line that opens it and the line that closes it.
class NativeChunk {
  const NativeChunk({required this.index, required this.end});

  /// Line index of the opening bracket.
  final int index;

  /// Line index of the closing bracket.
  final int end;

  /// How many lines the region hides when collapsed.
  int get collapseSize => end - index - 1;

  /// Whether collapsing it would hide anything.
  bool get canCollapse => collapseSize > 0;

  @override
  bool operator ==(Object other) =>
      other is NativeChunk && other.index == index && other.end == end;

  @override
  int get hashCode => Object.hash(index, end);

  @override
  String toString() => 'NativeChunk($index, $end)';
}

/// A match found in the flattened view of a document.
///
/// [startLine] and [endLine] are indices into that view, which expands folded
/// regions — so they are *not* indices into the document the editor draws.
/// Offsets are UTF-16 code units within their line.
class NativeFindMatch {
  const NativeFindMatch({
    required this.startLine,
    required this.startOffset,
    required this.endLine,
    required this.endOffset,
  });

  final int startLine;
  final int startOffset;
  final int endLine;
  final int endOffset;

  @override
  String toString() => 'NativeFindMatch($startLine:$startOffset-$endLine:$endOffset)';
}

/// The matches a search found.
class NativeFindResult {
  const NativeFindResult({required this.matches, required this.revision});

  final List<NativeFindMatch> matches;

  /// The document revision this searched.
  final int revision;

  @override
  String toString() => 'NativeFindResult(${matches.length} matches, revision: $revision)';
}

/// The result of analyzing a document's collapsible regions.
class NativeChunkAnalysis {
  const NativeChunkAnalysis({required this.chunks, required this.revision});

  /// The regions found, in ascending order of opening line.
  final List<NativeChunk> chunks;

  /// The document revision this describes.
  final int revision;

  @override
  String toString() => 'NativeChunkAnalysis($chunks, revision: $revision)';
}

/// One scope over a span of highlighted code.
///
/// Spans are given the way [NativeFindMatch] gives a match — lines, and UTF-16
/// offsets within them — because lines are what the editor draws in. The end is
/// exclusive, and a span contains the spans of every node nested inside it.
class NativeHighlightNode {
  const NativeHighlightNode({
    required this.scope,
    required this.startLine,
    required this.startOffset,
    required this.endLine,
    required this.endOffset,
    required this.depth,
  });

  /// The class name a theme keys on, such as `string` or `keyword`.
  final String scope;

  final int startLine;
  final int startOffset;
  final int endLine;
  final int endOffset;

  /// How many nodes enclose this one. A top-level node has depth 0.
  ///
  /// This is what lets a caller nest a flat list without searching it. Nodes
  /// carrying no scope are not reported at all, so they do not appear in the
  /// count either.
  final int depth;

  @override
  bool operator ==(Object other) =>
      other is NativeHighlightNode &&
      other.scope == scope &&
      other.startLine == startLine &&
      other.startOffset == startOffset &&
      other.endLine == endLine &&
      other.endOffset == endOffset &&
      other.depth == depth;

  @override
  int get hashCode =>
      Object.hash(scope, startLine, startOffset, endLine, endOffset, depth);

  @override
  String toString() =>
      'NativeHighlightNode($scope, $startLine:$startOffset-$endLine:$endOffset, depth: $depth)';
}

/// What a grammar found in a piece of code.
class NativeHighlightResult {
  const NativeHighlightResult({required this.nodes, required this.relevance});

  /// Every scoped span, in reading order.
  final List<NativeHighlightNode> nodes;

  /// How much of the code looked like what this language is made of, on
  /// highlight.js's scale.
  ///
  /// This is the score `highlightAuto` compares between languages, and the only
  /// thing that decides which one a document is written in.
  final double relevance;

  @override
  String toString() =>
      'NativeHighlightResult(${nodes.length} nodes, relevance $relevance)';
}

/// A grammar compiled on the native side.
///
/// Compiling is the expensive half — a few hundred modes, each with a combined
/// regular expression to build — so it happens once per language and the handle
/// is reused for every call. That is the whole reason the grammar has a handle
/// rather than travelling with each request.
///
/// Not safe to use from more than one isolate, and not to be used after
/// [dispose].
abstract interface class NativeGrammar {
  /// Highlights [code] in full.
  ///
  /// A grammar's state carries from one line to the next, so the text from
  /// where the caller's state is known is what has to be sent: today the whole
  /// document, since the engine cannot yet be asked to resume part-way through
  /// one.
  ///
  /// An answer with no spans is a real one — the code matched nothing — and is
  /// not the same as a failure, which is why this answers rather than returning
  /// `null`.
  NativeHighlightResult highlight(String code);

  /// Releases the compiled grammar. Using it afterwards is undefined.
  void dispose();
}

/// What an edit changed, from a highlighter that has already seen the document.
///
/// [from] and [to] are the lines [nodes] cover, in the document as it is now;
/// [replaced] is how far the caller's own spans reached in the document as it
/// was. A caller replaces `from..replaced` of what it holds with the lines
/// `from..to` of [nodes] — see `spliceByLine`.
class NativeHighlightUpdate {
  const NativeHighlightUpdate({
    required this.from,
    required this.to,
    required this.replaced,
    required this.scannedTo,
    required this.nodes,
  });

  /// The first line whose spans are new.
  final int from;

  /// One past the last line whose spans are new. From here on, every line has
  /// the spans it had before the edit.
  final int to;

  /// One past the last line the caller's spans covered, in the document as it
  /// was.
  final int replaced;

  /// The spans for `from..to`, in reading order.
  final List<NativeHighlightNode> nodes;

  /// One past the last line the highlighter now has highlighted: the length the
  /// caller's lines should have after making the splice above.
  final int scannedTo;

  @override
  String toString() => 'NativeHighlightUpdate($from..$to, replaced $replaced, '
      'scanned to $scannedTo, ${nodes.length} nodes)';
}

/// The line past every line of every document a highlighter could be given.
///
/// Asking to be highlighted up to here is how a caller asks for all of it: the
/// native side clamps the request to the document it holds.
const int kAllHighlightLines = 0xFFFFFFFF;

/// What one forward scan added.
///
/// Highlighting a document happens a piece at a time and always from the top: a
/// grammar's state carries from one line to the next, so the lines a scan can
/// compute are the ones between where the last scan stopped and where this one
/// was asked to reach. That is why [from] is an answer rather than a request.
class NativeHighlightChunk {
  const NativeHighlightChunk({
    required this.from,
    required this.to,
    required this.nodes,
  });

  /// One past the last line the caller already had. A caller whose own lines do
  /// not reach this far has lost step with the document and has to start again
  /// from nothing.
  final int from;

  /// One past the last line this covers — the length the caller's lines now
  /// have. Not the line that was asked for: a rule match cannot be cut in two,
  /// so a scan stops at a line start at or past its target.
  final int to;

  /// The spans for [from]..[to], in reading order.
  final List<NativeHighlightNode> nodes;
}

/// A document the native side highlights in pieces.
///
/// The document and the states between its lines live on the native side, which
/// is what makes an edit cost the lines it touched: one line for a keystroke
/// inside a comment, and as many lines as a brace encloses for one that opens a
/// brace. Without this, every keystroke highlights the whole document — 871 ms
/// over the package's own sources at 181,000 lines.
///
/// Not safe to use from more than one isolate, and not to be used after
/// [dispose].
abstract interface class NativeHighlighter {
  /// Highlights everything up to [toLine], carrying on from where the last call
  /// stopped, and answers with the lines that added.
  ///
  /// Asking for a line already covered adds nothing and costs nothing.
  NativeHighlightChunk scan(int toLine);

  /// Every span in the document.
  ///
  /// For a caller that has just built one, or whose own cache has been thrown
  /// away. The same call as [scan] with the whole document as the range.
  List<NativeHighlightNode> spans();

  /// Replaces [removed] lines at [start] with [added] and answers with what that
  /// changed.
  ///
  /// The lines are whole, without their line breaks, which is how the editor
  /// holds them.
  NativeHighlightUpdate splice({
    required int start,
    required int removed,
    required List<String> added,
  });

  /// Releases the highlighter. Using it afterwards is undefined.
  void dispose();
}

/// A line being sent to the native document.
///
/// The native side keeps two views of the document — the lines as the user sees
/// them, and those lines with folded regions expanded, which is what search
/// reads. [hidden] is what tells them apart, and it is empty for almost every
/// line: a line only hides anything once something on it has been folded.
class NativeLine {
  const NativeLine(this.text, [this.hidden = const <String>[]]);

  /// The line's own text.
  final String text;

  /// The lines this one hides, already flattened into reading order.
  final List<String> hidden;

  @override
  String toString() => hidden.isEmpty ? text : '$text (hiding ${hidden.length})';
}

/// A document held on the native side.
///
/// The editor's document used to cross the boundary in full on every keystroke,
/// which cost more than the work it was sent for. It lives here instead, and
/// the Dart side sends only what changed.
///
/// Not safe to use from more than one isolate, and not to be used after
/// [dispose].
abstract interface class NativeDocument {
  /// The revision the native side last assigned.
  int get revision;

  /// How many lines this document holds.
  ///
  /// Read only to report a refused splice: the refusal already carries what the
  /// caller asked for, and this is the other side of the disagreement.
  int get lineCount;

  /// Replaces [removed] lines at [start] with [added].
  ///
  /// Returns whether the document changed — replacing a line with an identical
  /// one is not a change, and no revision is spent on it.
  ///
  /// Throws [StateError] when the splice does not fit, which means the caller's
  /// idea of the document has diverged from this one. That is a bug in the
  /// caller, not a condition to recover from, and the document is left alone.
  bool splice({required int start, required int removed, required List<NativeLine> added});

  /// Finds the collapsible regions.
  NativeChunkAnalysis analyzeChunks();

  /// Finds every occurrence of [pattern] in the flattened view.
  ///
  /// That view expands folded regions, so text the user has hidden is still
  /// found — the same document the find panel has always searched.
  ///
  /// The search runs on a worker thread. On a document of any size it takes
  /// milliseconds, and that is time the thread drawing the editor cannot spend:
  /// measured at around 7 ms on 100,000 lines, against the 3 ms the isolate it
  /// replaced charged for handing the work over. Doing it here would be a
  /// slower editor, however much faster the search itself is.
  ///
  /// Returns `null` when [pattern] is not a valid regular expression, which the
  /// caller reports the way it always has: as no result at all. An empty match
  /// list is a real answer and means the opposite.
  Future<NativeFindResult?> find({
    required String pattern,
    required bool caseSensitive,
    required bool regex,
  });

  /// Releases the native document. Using it afterwards is undefined.
  void dispose();
}

/// The subset of native operations the editor uses.
abstract interface class ReEditorNativeApi {
  /// The ABI version the loaded library was built against.
  int get abiVersion;

  /// Reads the library's identity.
  NativeAbiInfo readAbiInfo();

  /// Takes a copy of a document, or returns `null` if it cannot be built.
  ///
  /// [lines] is the caller's document — every line, with whatever it hides.
  /// The hidden content has to be here and not only on later edits: a document
  /// that opened without it and then received an edit carrying it would hold
  /// two kinds of line, and the difference would show up as a search that
  /// misses what is folded away.
  ///
  /// Returns `null` when the lines cannot be encoded faithfully — a line
  /// containing a newline of its own would put every line index out of step
  /// with the caller's model, so this refuses rather than guess.
  NativeDocument? openDocument(List<NativeLine> lines);

  /// Compiles a grammar, or returns `null` when it cannot be compiled.
  ///
  /// [json] is a language in the shape `re_highlight` names its `Mode` fields
  /// in, and [subLanguages] holds the grammars its `subLanguage` rules reach,
  /// by name.
  ///
  /// `null` is the signal to keep highlighting with the Dart implementation,
  /// not to show plain text: it means this grammar — or one of its
  /// sub-languages — is not something the native side can reproduce, and a
  /// grammar that is silently left uncompiled would be a different set of
  /// colours rather than an error.
  NativeGrammar? compileGrammar({
    required String json,
    Map<String, String> subLanguages,
  });

  /// Takes a document to highlight in pieces, or returns `null` when it cannot
  /// be highlighted natively.
  ///
  /// [json] and [subLanguages] are as [`compileGrammar`] takes them, and [text]
  /// is the document with its lines joined by `\n`.
  ///
  /// `null` is the signal to highlight with the Dart implementation. It is also
  /// the answer for a grammar that cannot be highlighted a line at a time: one
  /// whose modes embed another language, because the embedded language's own
  /// state carries across the lines it spans, and this highlighter would restart
  /// it at each one.
  NativeHighlighter? openHighlighter({
    required String json,
    Map<String, String> subLanguages,
    required String text,
  });
}
