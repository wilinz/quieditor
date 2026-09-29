/// The `dart:ffi` arm of the conditional import in `native.dart`.
///
/// This is the only library in the package that imports `dart:ffi`, and the
/// only one that names a native symbol. Everything above it goes through
/// [ReEditorNativeApi].
///
/// The `@Native` declarations live *here* rather than in a helper, and that is
/// load-bearing: an annotation with no explicit `assetId` resolves symbols
/// against the URI of the library that declares them. The asset id is therefore
/// `package:re_editor/src/native/native_ffi.dart`, which is exactly what
/// `hook/build.dart` registers (see `_bindingsLibrary` there). Splitting these
/// into another file would silently break symbol resolution.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flat_buffers/flat_buffers.dart' as flatbuffers;

import 'generated/abi_generated.dart' as abi;
import 'generated/chunk_generated.dart' as chunk;
import 'generated/document_generated.dart' as documentfb;
import 'generated/find_generated.dart' as findfb;
import 'generated/highlight_generated.dart' as highlightfb;
import 'native_api.dart';

/// True on every platform that reaches this library.
const bool nativePlatformSupported = true;

/// The ABI this Dart code was written against.
///
/// Must match `re_editor_core::ABI_VERSION`. A mismatch means the bundled
/// library is older than the Dart calling it, and the safe move is to use the
/// Dart implementation rather than interpret the bytes wrongly.
const int _expectedAbiVersion = 4;

// --- Native symbols ---------------------------------------------------------
//
// Each declares `symbol:` rather than relying on the Dart name, so the Rust
// side keeps its `re_editor_` prefix and stays greppable.
//
// A handle is a `Size` — an opaque integer the same width as a pointer, which
// is what it replaced — and zero means there is no handle, the way `nullptr`
// used to. Nothing here dereferences one, so the worst a stale handle can do is
// come back as a refusal from the other side.

/// The ABI version compiled into the loaded library.
@Native<Uint32 Function()>(symbol: 're_editor_abi_version')
external int _abiVersion();

/// Writes the length of the returned buffer through `outLen`.
@Native<Pointer<Uint8> Function(Pointer<Size>)>(symbol: 're_editor_abi_info')
external Pointer<Uint8> _abiInfo(Pointer<Size> outLen);

/// Takes a copy of a document. Zero when the request cannot be decoded.
@Native<Size Function(Pointer<Uint8>, Size)>(symbol: 're_editor_doc_create')
external int _docCreate(Pointer<Uint8> request, int requestLen);

@Native<Void Function(Size)>(symbol: 're_editor_doc_free')
external void _docFree(int doc);

@Native<Uint64 Function(Size)>(symbol: 're_editor_doc_revision')
external int _docRevision(int doc);

@Native<Uint32 Function(Size)>(symbol: 're_editor_doc_line_count')
external int _docLineCount(int doc);

@Native<Pointer<Uint8> Function(Size, Pointer<Uint8>, Size, Pointer<Size>)>(
    symbol: 're_editor_doc_splice')
external Pointer<Uint8> _docSplice(
    int doc, Pointer<Uint8> request, int requestLen, Pointer<Size> outLen);

@Native<Pointer<Uint8> Function(Size, Pointer<Size>)>(symbol: 're_editor_doc_chunk_analyze')
external Pointer<Uint8> _docChunkAnalyze(int doc, Pointer<Size> outLen);

/// Finds text. Returns null when the pattern is not a valid regular expression.
@Native<Pointer<Uint8> Function(Size, Pointer<Uint8>, Size, Pointer<Size>)>(
    symbol: 're_editor_doc_find')
external Pointer<Uint8> _docFind(
    int doc, Pointer<Uint8> request, int requestLen, Pointer<Size> outLen);

/// Runs a search on a worker thread. Returns 0 when it was handed off.
///
/// The last argument is handed back to [callback] unchanged, and is the only
/// thing that connects an answer to the call waiting for it. An integer rather
/// than a pointer, so there is nothing to allocate and nothing to keep alive.
@Native<Int32 Function(Size, Pointer<Uint8>, Size, Pointer<NativeFunction<FindCallbackNative>>, Size)>(
    symbol: 're_editor_doc_find_async')
external int _docFindAsync(
  int doc,
  Pointer<Uint8> request,
  int requestLen,
  Pointer<NativeFunction<FindCallbackNative>> callback,
  int search,
);

/// Compiles a grammar. Zero when the request cannot be compiled.
@Native<Size Function(Pointer<Uint8>, Size)>(symbol: 're_editor_grammar_create')
external int _grammarCreate(Pointer<Uint8> request, int requestLen);

@Native<Void Function(Size)>(symbol: 're_editor_grammar_free')
external void _grammarFree(int grammar);

/// Highlights code with a compiled grammar.
@Native<Pointer<Uint8> Function(Size, Pointer<Uint8>, Size, Pointer<Size>)>(
    symbol: 're_editor_highlight')
external Pointer<Uint8> _highlight(
    int grammar, Pointer<Uint8> request, int requestLen, Pointer<Size> outLen);

/// Takes a document to highlight in pieces. Zero when it cannot be taken.
@Native<Size Function(Pointer<Uint8>, Size)>(symbol: 're_editor_highlighter_create')
external int _highlighterCreate(Pointer<Uint8> request, int requestLen);

@Native<Void Function(Size)>(symbol: 're_editor_highlighter_free')
external void _highlighterFree(int highlighter);

/// Applies an edit to a highlighted document.
@Native<Pointer<Uint8> Function(Size, Pointer<Uint8>, Size, Pointer<Size>)>(
    symbol: 're_editor_highlighter_update')
external Pointer<Uint8> _highlighterUpdate(
    int highlighter, Pointer<Uint8> request, int requestLen, Pointer<Size> outLen);

/// The spans of a range of lines in a highlighted document.
@Native<Pointer<Uint8> Function(Size, Pointer<Uint8>, Size, Pointer<Size>)>(
    symbol: 're_editor_highlighter_spans')
external Pointer<Uint8> _highlighterSpans(
    int highlighter, Pointer<Uint8> request, int requestLen, Pointer<Size> outLen);

/// Releases a buffer this library handed out.
@Native<Void Function(Pointer<Uint8>, Size)>(symbol: 're_editor_free')
external void _free(Pointer<Uint8> ptr, int len);

// --- Loading ----------------------------------------------------------------

/// The signature of the callback a finished search arrives on.
///
/// The last argument is the search number the call passed, handed back
/// unchanged.
typedef FindCallbackNative = Void Function(Pointer<Uint8>, Size, Size);

/// Searches that have been handed to a worker and not yet answered.
///
/// Keyed by the search number Rust is given and hands back, which is how a
/// result finds the call that asked for it. Nothing else correlates them: the
/// worker thread has no idea which search it is running.
final Map<int, Completer<NativeFindResult?>> _searchesInFlight =
    <int, Completer<NativeFindResult?>>{};
int _nextSearchId = 0;

/// Receives finished searches. Runs on *this* isolate, posted here by the
/// runtime from whichever worker thread finished.
///
/// A listener rather than a plain callback because the thread that invokes it
/// is not this isolate's, and touching Dart state from it directly would be
/// undefined. A listener asks the runtime to deliver the call properly instead.
final NativeCallable<FindCallbackNative> _searchCallback =
    NativeCallable<FindCallbackNative>.listener(_onSearchFinished);

void _onSearchFinished(Pointer<Uint8> response, int length, int search) {
  final Completer<NativeFindResult?>? completer = _searchesInFlight.remove(search);
  if (completer == null) {
    // The document went away first, or the search was already written off.
    if (response != nullptr) {
      _free(response, length);
    }
    return;
  }
  if (response == nullptr) {
    // The pattern could not be compiled. Same answer as the synchronous call
    // gives for the same reason: no result at all.
    completer.complete(null);
    return;
  }
  try {
    // Decoded before the buffer is released — the generated readers are lazy
    // views over these bytes.
    completer.complete(_FfiNativeDocument.decodeMatches(response.asTypedList(length)));
  } finally {
    _free(response, length);
  }
}

/// Releases documents Dart dropped without disposing.
///
/// One finalizer for every document: the value it carries is the handle itself,
/// so a single instance serves all of them. Disposing detaches, so this never
/// runs for a document that was released properly.
///
/// A handle that has already been released is nothing to worry about here,
/// which is what makes this safe to leave to the garbage collector: releasing
/// one twice costs a lookup and does nothing.
final Finalizer<int> _documents = Finalizer<int>(_docFree);

/// The same, for grammars.
final Finalizer<int> _grammars = Finalizer<int>(_grammarFree);

/// And for highlighters.
final Finalizer<int> _highlighters = Finalizer<int>(_highlighterFree);

/// Probes for the native core, or returns `null` when it is not usable.
///
/// Called once, lazily; the caller caches the answer. It probes by *calling*
/// rather than by checking, because that is the only way to find out: on a
/// build where the hook produced no code asset the symbols do not resolve, and
/// the call is what throws.
///
/// A library whose ABI does not match is reported as absent rather than used.
/// That is not hypothetical — a stale `.dylib` in a build directory is the most
/// likely way to end up in that state, and the symptom would otherwise be a
/// mysterious misread rather than a clean fallback.
ReEditorNativeApi? createReEditorNativeApi() {
  final int version;
  try {
    version = _abiVersion();
  } catch (_) {
    return null;
  }
  if (version != _expectedAbiVersion) {
    return null;
  }
  return _FfiNativeApi();
}

/// The spans in a decoded response, as plain Dart values.
///
/// Called while the buffer is still alive: the generated readers are lazy views
/// over those bytes, and what comes out holds no reference to them.
List<NativeHighlightNode> _nodesOf(List<highlightfb.HighlightNode>? nodes) {
  if (nodes == null) {
    return const <NativeHighlightNode>[];
  }
  return nodes
      .map((highlightfb.HighlightNode node) => NativeHighlightNode(
            scope: node.scope ?? '',
            startLine: node.startLine,
            startOffset: node.startOffset,
            endLine: node.endLine,
            endOffset: node.endOffset,
            depth: node.depth,
          ))
      .toList();
}

/// Runs a native operation whose request is a FlatBuffer.
///
/// [decode] runs while the response buffer is still alive, because the generated
/// readers are lazy views over those bytes. Anything that needs to outlive this
/// call has to become a plain Dart value inside [decode].
///
/// An empty [request] is passed as a null pointer, which the native side reads
/// as "no request" — that is how the operations that take only a handle are
/// spelled.
///
/// Returns `null` when the native side declined, which is not the same as an
/// empty answer: it only returns null when it could not answer at all.
T? _invoke<T>(
  Uint8List request,
  Pointer<Uint8> Function(Pointer<Uint8>, int, Pointer<Size>) call,
  T Function(Uint8List) decode,
) {
  final Pointer<Size> outLen = calloc<Size>();
  final Pointer<Uint8> requestPtr =
      request.isEmpty ? nullptr : malloc<Uint8>(request.length);
  Pointer<Uint8> responsePtr = nullptr;
  int responseLen = 0;
  try {
    if (requestPtr != nullptr) {
      requestPtr.asTypedList(request.length).setAll(0, request);
    }
    responsePtr = call(requestPtr, request.length, outLen);
    responseLen = outLen.value;
    if (responsePtr == nullptr) {
      return null;
    }
    return decode(responsePtr.asTypedList(responseLen));
  } finally {
    if (responsePtr != nullptr) {
      _free(responsePtr, responseLen);
    }
    if (requestPtr != nullptr) {
      malloc.free(requestPtr);
    }
    calloc.free(outLen);
  }
}

class _FfiNativeApi implements ReEditorNativeApi {
  @override
  int get abiVersion => _expectedAbiVersion;

  @override
  NativeDocument? openDocument(List<NativeLine> lines) {
    final _LineEncoding encoded = _encodeLines(lines);
    final flatbuffers.Builder builder =
        flatbuffers.Builder(initialSize: encoded.size + 64);
    // Written before the table starts: FlatBuffers builds back to front, so
    // strings and vectors have to be laid down first.
    final int textOffset = builder.writeString(encoded.text);
    final int hiddenOffset = builder.writeString(encoded.hidden);
    final int countsOffset = builder.writeListUint32(encoded.counts);
    final documentfb.CreateRequestBuilder request =
        documentfb.CreateRequestBuilder(builder);
    request.begin();
    request.addTextOffset(textOffset);
    request.addLines(lines.length);
    request.addHiddenOffset(hiddenOffset);
    request.addHiddenCountsOffset(countsOffset);
    builder.finish(request.finish());

    final Uint8List bytes = builder.buffer;
    final Pointer<Uint8> requestPtr = malloc<Uint8>(bytes.length);
    try {
      requestPtr.asTypedList(bytes.length).setAll(0, bytes);
      final int handle = _docCreate(requestPtr, bytes.length);
      if (handle == 0) {
        return null;
      }
      return _FfiNativeDocument(handle);
    } finally {
      malloc.free(requestPtr);
    }
  }

  @override
  NativeGrammar? compileGrammar({
    required String json,
    Map<String, String> subLanguages = const <String, String>{},
  }) {
    // Built with the generated object builders rather than by hand: a request
    // holding a list of tables is the one shape where writing the offsets
    // yourself has something to get wrong, and flatc already wrote it.
    final Uint8List bytes = highlightfb.GrammarRequestObjectBuilder(
      json: json,
      subLanguages: subLanguages.entries
          .map((MapEntry<String, String> entry) =>
              highlightfb.SubGrammarObjectBuilder(name: entry.key, json: entry.value))
          .toList(),
    ).toBytes();

    final Pointer<Uint8> requestPtr = malloc<Uint8>(bytes.length);
    try {
      requestPtr.asTypedList(bytes.length).setAll(0, bytes);
      final int handle = _grammarCreate(requestPtr, bytes.length);
      if (handle == 0) {
        return null;
      }
      return _FfiNativeGrammar(handle);
    } finally {
      malloc.free(requestPtr);
    }
  }

  @override
  NativeHighlighter? openHighlighter({
    required String json,
    Map<String, String> subLanguages = const <String, String>{},
    required String text,
  }) {
    final Uint8List bytes = highlightfb.HighlighterRequestObjectBuilder(
      json: json,
      subLanguages: subLanguages.entries
          .map((MapEntry<String, String> entry) =>
              highlightfb.SubGrammarObjectBuilder(name: entry.key, json: entry.value))
          .toList(),
      text: text,
    ).toBytes();

    final Pointer<Uint8> requestPtr = malloc<Uint8>(bytes.length);
    try {
      requestPtr.asTypedList(bytes.length).setAll(0, bytes);
      final int handle = _highlighterCreate(requestPtr, bytes.length);
      if (handle == 0) {
        return null;
      }
      return _FfiNativeHighlighter(handle);
    } finally {
      malloc.free(requestPtr);
    }
  }

  @override
  NativeAbiInfo readAbiInfo() {
    final Pointer<Size> outLen = calloc<Size>();
    Pointer<Uint8> buffer = nullptr;
    int length = 0;
    try {
      buffer = _abiInfo(outLen);
      length = outLen.value;
      if (buffer == nullptr || length == 0) {
        throw StateError('re_editor_abi_info returned no data');
      }
      // Everything is read out before the buffer is released. `flat_buffers`
      // hands back lazy views over these bytes, so nothing that outlives this
      // block may still be pointing at them — which is why the values are
      // pulled into plain Dart types here rather than returned as a reader.
      final abi.AbiInfo info = abi.AbiInfo(buffer.asTypedList(length));
      return NativeAbiInfo(
        abiVersion: info.abiVersion,
        coreVersion: info.coreVersion ?? '',
      );
    } finally {
      if (buffer != nullptr) {
        _free(buffer, length);
      }
      calloc.free(outLen);
    }
  }
}

/// Lines as the three fields they travel in.
///
/// Built the same way for opening a document and for editing one, because the
/// native side has to end up with the same kind of line either way.
class _LineEncoding {
  const _LineEncoding({
    required this.text,
    required this.hidden,
    required this.counts,
    required this.size,
  });

  /// The lines' own text, joined with `\n`.
  final String text;

  /// Every hidden line, concatenated in order and joined with `\n`.
  ///
  /// Empty for a document with nothing folded, which is the usual case: the
  /// editor reads the collapsed view on every keystroke and only needs the
  /// hidden lines to answer a search.
  final String hidden;

  /// How many of [hidden]'s lines belong to each of [text]'s.
  ///
  /// A vector of counts rather than a nested structure because FlatBuffers'
  /// Dart side has no vector-of-offsets builder, and because the counts are
  /// almost all zero: [hidden] stays one small string instead of a table per
  /// line.
  final List<int> counts;

  /// Roughly how much room the FlatBuffer needs.
  final int size;
}

_LineEncoding _encodeLines(List<NativeLine> lines) {
  final String text = lines.map((NativeLine line) => line.text).join('\n');
  final String hidden = lines.expand((NativeLine line) => line.hidden).join('\n');
  return _LineEncoding(
    text: text,
    hidden: hidden,
    counts: lines.map((NativeLine line) => line.hidden.length).toList(),
    size: text.length + hidden.length,
  );
}

class _FfiNativeDocument implements NativeDocument {
  _FfiNativeDocument(this._handle) {
    _documents.attach(this, _handle, detach: this);
  }

  /// The handle the native side issued.
  ///
  /// Held past `dispose` rather than zeroed: the native side never issues a
  /// handle twice, so one that has been released names nothing, and a call that
  /// somehow got past `_checkAlive` would be answered rather than obeyed.
  final int _handle;
  bool _disposed = false;

  void _checkAlive() {
    if (_disposed) {
      throw StateError('This document has been disposed.');
    }
  }

  @override
  int get revision {
    _checkAlive();
    return _docRevision(_handle);
  }

  @override
  int get lineCount {
    _checkAlive();
    return _docLineCount(_handle);
  }

  @override
  bool splice({required int start, required int removed, required List<NativeLine> added}) {
    _checkAlive();
    final _LineEncoding encoded = _encodeLines(added);
    final flatbuffers.Builder builder =
        flatbuffers.Builder(initialSize: encoded.size + 64);
    // Written before the table starts: FlatBuffers builds back to front, so
    // strings and vectors have to be laid down first.
    final int textOffset = builder.writeString(encoded.text);
    final int hiddenOffset = builder.writeString(encoded.hidden);
    final int countsOffset = builder.writeListUint32(encoded.counts);
    final documentfb.SpliceRequestBuilder request =
        documentfb.SpliceRequestBuilder(builder);
    request.begin();
    request.addStart(start);
    request.addRemoved(removed);
    request.addAdded(added.length);
    request.addTextOffset(textOffset);
    request.addHiddenOffset(hiddenOffset);
    request.addHiddenCountsOffset(countsOffset);
    builder.finish(request.finish());

    final bool? changed = _invoke(
      builder.buffer,
      (Pointer<Uint8> request, int length, Pointer<Size> outLen) =>
          _docSplice(_handle, request, length, outLen),
      _decodeSplice,
    );
    if (changed == null) {
      // The native side refused the splice, which means the two sides disagree
      // about the document. Recovering would mean guessing which one is right;
      // throwing makes the divergence visible where it happened.
      //
      // The count is read after the refusal rather than before, and is safe to:
      // a refused splice leaves the document alone. Without it the message only
      // repeats what the caller passed in — the side that is already known —
      // and leaves out the one fact that says how far apart the two are.
      throw StateError(
        'The native document refused a splice at line $start removing $removed '
        'and adding ${added.length}, against its $lineCount lines. '
        'The two sides have diverged.',
      );
    }
    return changed;
  }

  static bool _decodeSplice(Uint8List bytes) =>
      documentfb.SpliceResponse(bytes).changed;

  @override
  NativeChunkAnalysis analyzeChunks() {
    _checkAlive();
    // No request: the native side reads the document it already has. That is
    // the whole point of the handle.
    final NativeChunkAnalysis? analysis = _invoke(
      Uint8List(0),
      (Pointer<Uint8> _, int __, Pointer<Size> outLen) =>
          _docChunkAnalyze(_handle, outLen),
      _decodeChunks,
    );
    if (analysis == null) {
      throw StateError('The native document could not be analyzed.');
    }
    return analysis;
  }

  @override
  Future<NativeFindResult?> find({
    required String pattern,
    required bool caseSensitive,
    required bool regex,
  }) async {
    _checkAlive();
    final flatbuffers.Builder builder =
        flatbuffers.Builder(initialSize: pattern.length + 64);
    // Written before the table starts: FlatBuffers builds back to front, so
    // strings have to be laid down first.
    final int patternOffset = builder.writeString(pattern);
    final findfb.FindRequestBuilder request = findfb.FindRequestBuilder(builder);
    request.begin();
    request.addPatternOffset(patternOffset);
    request.addCaseSensitive(caseSensitive);
    request.addRegex(regex);
    builder.finish(request.finish());

    final Uint8List encoded = builder.buffer;
    final Pointer<Uint8> requestPtr = malloc<Uint8>(encoded.length);
    // The native side copies the request before it spawns the worker, so the
    // buffer only has to outlive this call.
    //
    // The search number is registered before the call rather than after it:
    // the worker has no idea when this frame ends, and the callback arrives
    // with nothing but the number to find this completer by.
    final int search = ++_nextSearchId;
    final Completer<NativeFindResult?> completer = Completer<NativeFindResult?>();
    _searchesInFlight[search] = completer;
    try {
      requestPtr.asTypedList(encoded.length).setAll(0, encoded);
      final int handedOff = _docFindAsync(
        _handle,
        requestPtr,
        encoded.length,
        _searchCallback.nativeFunction,
        search,
      );
      if (handedOff != 0) {
        // No worker was started, so nothing is going to call back. Doing the
        // search here is slower than the caller was promised, but it is still
        // an answer rather than a failure.
        _searchesInFlight.remove(search);
        return _findHere(requestPtr, encoded.length);
      }
      return await completer.future;
    } finally {
      malloc.free(requestPtr);
    }
  }

  /// The search, run on this thread. Only reached when no worker could be
  /// started.
  NativeFindResult? _findHere(Pointer<Uint8> request, int length) {
    final Pointer<Size> outLen = calloc<Size>();
    Pointer<Uint8> response = nullptr;
    int responseLen = 0;
    try {
      response = _docFind(_handle, request, length, outLen);
      responseLen = outLen.value;
      if (response == nullptr) {
        return null;
      }
      return decodeMatches(response.asTypedList(responseLen));
    } finally {
      if (response != nullptr) {
        _free(response, responseLen);
      }
      calloc.free(outLen);
    }
  }

  /// Turns a response buffer into plain Dart values.
  ///
  /// Called while the buffer is still alive, because the generated readers are
  /// lazy views over it; what comes out holds no reference to the bytes.
  static NativeFindResult decodeMatches(Uint8List bytes) {
    final findfb.FindResponse response = findfb.FindResponse(bytes);
    final List<findfb.FindMatch>? matches = response.matches;
    return NativeFindResult(
      // Materialised here, not lazily: these readers point into the response
      // buffer, which is released as soon as this returns.
      matches: matches == null
          ? const <NativeFindMatch>[]
          : matches
              .map((findfb.FindMatch match) => NativeFindMatch(
                    startLine: match.startLine,
                    startOffset: match.startOffset,
                    endLine: match.endLine,
                    endOffset: match.endOffset,
                  ))
              .toList(),
      revision: response.revision,
    );
  }

  static NativeChunkAnalysis _decodeChunks(Uint8List bytes) {
    final chunk.ChunkAnalyzeResponse response = chunk.ChunkAnalyzeResponse(bytes);
    final List<chunk.Chunk>? chunks = response.chunks;
    return NativeChunkAnalysis(
      // Materialised here, not lazily: these readers point into the response
      // buffer, which is released as soon as this returns.
      chunks: chunks == null
          ? const <NativeChunk>[]
          : chunks
              .map((chunk.Chunk entry) => NativeChunk(index: entry.index, end: entry.end))
              .toList(),
      revision: response.revision,
    );
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    // Detached first, so a document released here is not freed a second time
    // when Dart collects it.
    _documents.detach(this);
    _docFree(_handle);
  }
}

class _FfiNativeHighlighter implements NativeHighlighter {
  _FfiNativeHighlighter(this._handle) {
    _highlighters.attach(this, _handle, detach: this);
  }

  final int _handle;
  bool _disposed = false;

  void _checkAlive() {
    if (_disposed) {
      throw StateError('This highlighter has been disposed.');
    }
  }

  @override
  NativeHighlightChunk scan(int toLine) {
    _checkAlive();
    final Uint8List bytes = highlightfb.HighlighterSpansRequestObjectBuilder(
      to: toLine,
    ).toBytes();
    final NativeHighlightChunk? chunk = _invoke(
      bytes,
      (Pointer<Uint8> request, int length, Pointer<Size> outLen) =>
          _highlighterSpans(_handle, request, length, outLen),
      decodeChunk,
    );
    if (chunk == null) {
      throw StateError('The native highlighter could not highlight to $toLine.');
    }
    return chunk;
  }

  @override
  List<NativeHighlightNode> spans() {
    // Past the end of any document, which the native side clamps: asking for
    // everything is a range like any other.
    return scan(kAllHighlightLines).nodes;
  }

  @override
  NativeHighlightUpdate splice({
    required int start,
    required int removed,
    required List<String> added,
  }) {
    _checkAlive();
    final Uint8List bytes = highlightfb.HighlighterSpliceRequestObjectBuilder(
      start: start,
      removed: removed,
      added: added,
    ).toBytes();
    final NativeHighlightUpdate? update = _invoke(
      bytes,
      (Pointer<Uint8> request, int length, Pointer<Size> outLen) =>
          _highlighterUpdate(_handle, request, length, outLen),
      decodeUpdate,
    );
    if (update == null) {
      // Every edit that decodes is answered, so a null here is the native side
      // being unable to carry on with this document. A caller cannot render
      // that as "nothing changed" — it would leave the lines that did change
      // coloured as they were.
      throw StateError(
        'The native highlighter refused an edit at line $start removing $removed '
        'and adding ${added.length}.',
      );
    }
    return update;
  }

  /// Turns a response buffer into plain Dart values, while it is still alive:
  /// the generated readers are lazy views over those bytes.
  static NativeHighlightUpdate decodeUpdate(Uint8List bytes) {
    final highlightfb.HighlighterUpdateResponse response =
        highlightfb.HighlighterUpdateResponse(bytes);
    return NativeHighlightUpdate(
      from: response.from,
      to: response.to,
      replaced: response.replaced,
      scannedTo: response.scannedTo,
      nodes: _nodesOf(response.nodes),
    );
  }

  static NativeHighlightChunk decodeChunk(Uint8List bytes) {
    final highlightfb.HighlighterSpansResponse response =
        highlightfb.HighlighterSpansResponse(bytes);
    return NativeHighlightChunk(
      from: response.from,
      to: response.to,
      nodes: _nodesOf(response.nodes),
    );
  }


  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _highlighters.detach(this);
    _highlighterFree(_handle);
  }
}

class _FfiNativeGrammar implements NativeGrammar {
  _FfiNativeGrammar(this._handle) {
    _grammars.attach(this, _handle, detach: this);
  }

  final int _handle;
  bool _disposed = false;

  @override
  NativeHighlightResult highlight(String code) {
    if (_disposed) {
      throw StateError('This grammar has been disposed.');
    }
    final Uint8List bytes =
        highlightfb.HighlightRequestObjectBuilder(code: code).toBytes();
    final NativeHighlightResult? nodes = _invoke(
      bytes,
      (Pointer<Uint8> request, int length, Pointer<Size> outLen) =>
          _highlight(_handle, request, length, outLen),
      decodeResult,
    );
    if (nodes == null) {
      // Every request that decodes is answered, so a null here means the native
      // side could not answer at all. A caller cannot render that as "nothing
      // was scoped" — it would lose the colours rather than report a problem.
      throw StateError(
        'The native grammar refused to highlight ${code.length} characters.',
      );
    }
    return nodes;
  }

  /// Turns a response buffer into plain Dart values.
  ///
  /// Called while the buffer is still alive, because the generated readers are
  /// lazy views over it; what comes out holds no reference to the bytes.
  static NativeHighlightResult decodeResult(Uint8List bytes) {
    final highlightfb.HighlightResponse response =
        highlightfb.HighlightResponse(bytes);
    return NativeHighlightResult(
      nodes: _nodesOf(response.nodes),
      relevance: response.relevance,
    );
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    // Detached first, so a grammar released here is not freed a second time
    // when Dart collects it.
    _grammars.detach(this);
    _grammarFree(_handle);
  }
}
