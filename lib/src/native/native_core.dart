/// The native layer, written once, over whatever [NativeTransport] reaches the
/// core.
///
/// Everything that is not "how do these bytes get there" is here: what to send,
/// what the answer means, which of the core's refusals mean fall back and which
/// mean the caller has a bug, and when a handle is released. `native_ffi.dart`
/// and `native_wasm.dart` are two ways of reaching the core; neither of them
/// knows anything about documents.
///
/// The handles are `int`s the core issues, so a wrapper here holds a number and
/// a transport — never an address. Nothing on this side can be wrong about a
/// pointer because there is no pointer to be wrong about: an unknown handle is
/// answered by the core the same way a released one is.
library;

import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as flatbuffers;

import 'generated/abi_generated.dart' as abi;
import 'generated/chunk_generated.dart' as chunk;
import 'generated/document_generated.dart' as documentfb;
import 'generated/find_generated.dart' as findfb;
import 'generated/highlight_generated.dart' as highlightfb;
import 'native_api.dart';
import 'native_transport.dart';

/// The editor's view of the core, over [transport].
ReEditorNativeApi createNativeCore(NativeTransport transport) =>
    _CoreNativeApi(transport);

class _CoreNativeApi implements ReEditorNativeApi {
  _CoreNativeApi(this._transport);

  final NativeTransport _transport;

  @override
  int get abiVersion => _transport.abiVersion;

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

    final int handle = _transport.create(NativeKind.document, builder.buffer);
    if (handle == 0) {
      return null;
    }
    return _NativeDocument(_transport, handle);
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

    final int handle = _transport.create(NativeKind.grammar, bytes);
    if (handle == 0) {
      return null;
    }
    return _NativeGrammar(_transport, handle);
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

    final int handle = _transport.create(NativeKind.highlighter, bytes);
    if (handle == 0) {
      return null;
    }
    return _NativeHighlighter(_transport, handle);
  }

  @override
  NativeAbiInfo readAbiInfo() {
    final Uint8List? bytes = _transport.abiInfo();
    if (bytes == null) {
      throw StateError('the native core reported no identity');
    }
    // Read into plain Dart values before the buffer goes: `flat_buffers` hands
    // back lazy views over these bytes, so nothing that outlives this may still
    // be pointing at them.
    final abi.AbiInfo info = abi.AbiInfo(bytes);
    return NativeAbiInfo(
      abiVersion: info.abiVersion,
      coreVersion: info.coreVersion ?? '',
    );
  }
}

/// A handle, and the transport that can release it.
///
/// Carried by the finalizer rather than the handle alone, because the same
/// number means different values in different transports — and because the
/// finalizer is shared by all three kinds, so it has to be told which one.
class _Handle {
  const _Handle(this.transport, this.kind, this.handle);

  final NativeTransport transport;
  final NativeKind kind;
  final int handle;

  static void release(_Handle value) => value.transport.free(value.kind, value.handle);
}

/// Releases a handle whose Dart owner was collected without being disposed.
///
/// One finalizer for every document, grammar and highlighter on every platform:
/// the value it carries says which one and how to let it go. Disposing detaches,
/// so this never runs for a handle that was released properly.
final Finalizer<_Handle> _handles = Finalizer<_Handle>(_Handle.release);

class _NativeDocument implements NativeDocument {
  _NativeDocument(this._transport, this._handle) {
    _handles.attach(this, _Handle(_transport, NativeKind.document, _handle),
        detach: this);
  }

  final NativeTransport _transport;

  /// The handle the core issued.
  ///
  /// Held past `dispose` rather than zeroed. The core never issues a handle
  /// twice, so one that has been released names nothing, and a call that
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
    return _transport.revision(_handle);
  }

  @override
  int get lineCount {
    _checkAlive();
    return _transport.lineCount(_handle);
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

    final bool? changed = _transport.invoke(
      NativeOperation.splice,
      _handle,
      builder.buffer,
      _decodeSplice,
    );
    if (changed == null) {
      // The core refused the splice, which means the two sides disagree about
      // the document. Recovering would mean guessing which one is right;
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
    // No request: the core reads the document it already has. That is the whole
    // point of the handle.
    final NativeChunkAnalysis? analysis = _transport.invoke(
      NativeOperation.analyzeChunks,
      _handle,
      Uint8List(0),
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

    return _transport.findAsync(_handle, builder.buffer, _decodeMatches);
  }

  static NativeFindResult _decodeMatches(Uint8List bytes) {
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
    // Detached first, so a handle released here is not freed a second time when
    // Dart collects the wrapper.
    _handles.detach(this);
    _transport.free(NativeKind.document, _handle);
  }
}

class _NativeHighlighter implements NativeHighlighter {
  _NativeHighlighter(this._transport, this._handle) {
    _handles.attach(this, _Handle(_transport, NativeKind.highlighter, _handle),
        detach: this);
  }

  final NativeTransport _transport;
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
    final NativeHighlightChunk? chunk = _transport.invoke(
      NativeOperation.highlighterSpans,
      _handle,
      bytes,
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
    final NativeHighlightUpdate? update = _transport.invoke(
      NativeOperation.updateHighlighter,
      _handle,
      bytes,
      decodeUpdate,
    );
    if (update == null) {
      // Every edit that decodes is answered, so a null here is the core being
      // unable to carry on with this document. A caller cannot render that as
      // "nothing changed" — it would leave the lines that did change coloured
      // as they were.
      throw StateError(
        'The native highlighter refused an edit at line $start removing '
        '$removed and adding ${added.length}.',
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
    _handles.detach(this);
    _transport.free(NativeKind.highlighter, _handle);
  }
}

class _NativeGrammar implements NativeGrammar {
  _NativeGrammar(this._transport, this._handle) {
    _handles.attach(this, _Handle(_transport, NativeKind.grammar, _handle),
        detach: this);
  }

  final NativeTransport _transport;
  final int _handle;
  bool _disposed = false;

  @override
  NativeHighlightResult highlight(String code) {
    if (_disposed) {
      throw StateError('This grammar has been disposed.');
    }
    final Uint8List bytes =
        highlightfb.HighlightRequestObjectBuilder(code: code).toBytes();
    final NativeHighlightResult? nodes = _transport.invoke(
      NativeOperation.highlight,
      _handle,
      bytes,
      decodeResult,
    );
    if (nodes == null) {
      // Every request that decodes is answered, so a null here means the core
      // could not answer at all. A caller cannot render that as "nothing was
      // scoped" — it would lose the colours rather than report a problem.
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
    // Detached first, so a handle released here is not freed a second time when
    // Dart collects the wrapper.
    _handles.detach(this);
    _transport.free(NativeKind.grammar, _handle);
  }
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

/// Lines as the three fields they travel in.
///
/// Built the same way for opening a document and for editing one, because the
/// core has to end up with the same kind of line either way.
class _LineEncoding {
  const _LineEncoding({
    required this.text,
    required this.hidden,
    required this.counts,
    required this.size,
  });

  /// The lines' own text, joined with `\n`.
  final String text;

  /// Every line's hidden lines, in reading order, joined with `\n`.
  ///
  /// A vector of counts rather than a nested structure because FlatBuffers'
  /// Dart side has no vector-of-offsets builder, and because the counts are
  /// almost all zero: [hidden] stays one small string instead of a table per
  /// line.
  final String hidden;

  /// How many of [hidden]'s lines belong to each of [text]'s.
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
