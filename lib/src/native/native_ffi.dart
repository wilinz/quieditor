/// The `dart:ffi` arm of the conditional import in `native.dart`.
///
/// What is here is only the crossing: the symbols to resolve, the buffers to
/// allocate on this side of them, and the worker thread a search runs on.
/// Everything that knows what a document is lives in `native_core.dart`, over
/// the [NativeTransport] this file implements.
///
/// This is the only library in the package that imports `dart:ffi`, and the
/// only one that names a native symbol.
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

import 'native_api.dart';
import 'native_core.dart';
import 'native_transport.dart';

/// True on every platform that reaches this library.
const bool nativePlatformSupported = true;

/// The ABI this Dart code was written against.
///
/// Must match `quieditor_engine::ABI_VERSION`. A mismatch means the bundled
/// library is older than the Dart calling it, and the safe move is to use the
/// Dart implementation rather than interpret the bytes wrongly.
const int _expectedAbiVersion = 5;

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
/// The last argument is handed back to [FindCallbackNative] unchanged, and is
/// the only thing that connects an answer to the call waiting for it. An
/// integer rather than a pointer, so there is nothing to allocate and nothing
/// to keep alive.
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

/// A search that has been handed to a worker and not yet answered.
///
/// The decode is kept alongside the completer because the callback arrives with
/// nothing but a search number: the worker has no idea which search it ran, and
/// this is what says what to make of the bytes it brings.
class _PendingSearch {
  const _PendingSearch(this.completer, this.decode);

  /// `Object?` rather than a type parameter: one map serves every search, and
  /// there is only ever one kind of them. The cast at [NativeTransport.findAsync]
  /// is where that is asserted.
  final Completer<Object?> completer;
  final Object? Function(Uint8List) decode;
}

/// Searches that have been handed to a worker and not yet answered.
///
/// Keyed by the search number Rust is given and hands back, which is how a
/// result finds the call that asked for it.
final Map<int, _PendingSearch> _searchesInFlight = <int, _PendingSearch>{};
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
  final _PendingSearch? pending = _searchesInFlight.remove(search);
  if (pending == null) {
    // The document went away first, or the search was already written off.
    if (response != nullptr) {
      _free(response, length);
    }
    return;
  }
  if (response == nullptr) {
    // The pattern could not be compiled. Same answer as the synchronous call
    // gives for the same reason: no result at all.
    pending.completer.complete(null);
    return;
  }
  try {
    // Decoded before the buffer is released — the generated readers are lazy
    // views over these bytes.
    pending.completer.complete(pending.decode(response.asTypedList(length)));
  } finally {
    _free(response, length);
  }
}

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
  return createNativeCore(_FfiTransport(version));
}

/// Nothing to wait for here: a linked library is there or it is not, and the
/// probe above already said which. The web is the platform that needs the other
/// entry point — see `native_wasm.dart`.
Future<ReEditorNativeApi?> loadReEditorNativeApi() async =>
    createReEditorNativeApi();

/// The library, reached through `dart:ffi`.
class _FfiTransport implements NativeTransport {
  const _FfiTransport(this.abiVersion);

  @override
  final int abiVersion;

  @override
  Uint8List? abiInfo() {
    final Pointer<Size> outLen = calloc<Size>();
    Pointer<Uint8> buffer = nullptr;
    int length = 0;
    try {
      buffer = _abiInfo(outLen);
      length = outLen.value;
      if (buffer == nullptr || length == 0) {
        return null;
      }
      // Copied, unlike every other response. The readers are lazy views over
      // these bytes and the caller decodes after this returns, so the copy is
      // what lets the buffer go; an identity is a few dozen bytes, which is the
      // only reason that is not the wrong trade here.
      return Uint8List.fromList(buffer.asTypedList(length));
    } finally {
      if (buffer != nullptr) {
        _free(buffer, length);
      }
      calloc.free(outLen);
    }
  }

  @override
  int create(NativeKind kind, Uint8List request) {
    final Pointer<Uint8> requestPtr = request.isEmpty ? nullptr : malloc<Uint8>(request.length);
    try {
      if (requestPtr != nullptr) {
        requestPtr.asTypedList(request.length).setAll(0, request);
      }
      return switch (kind) {
        NativeKind.document => _docCreate(requestPtr, request.length),
        NativeKind.grammar => _grammarCreate(requestPtr, request.length),
        NativeKind.highlighter => _highlighterCreate(requestPtr, request.length),
      };
    } finally {
      if (requestPtr != nullptr) {
        malloc.free(requestPtr);
      }
    }
  }

  @override
  void free(NativeKind kind, int handle) {
    switch (kind) {
      case NativeKind.document:
        _docFree(handle);
      case NativeKind.grammar:
        _grammarFree(handle);
      case NativeKind.highlighter:
        _highlighterFree(handle);
    }
  }

  @override
  int revision(int document) => _docRevision(document);

  @override
  int lineCount(int document) => _docLineCount(document);

  @override
  T? invoke<T>(
    NativeOperation operation,
    int handle,
    Uint8List request,
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
      responsePtr = switch (operation) {
        NativeOperation.splice =>
          _docSplice(handle, requestPtr, request.length, outLen),
        // No request, and no pointer for one: the core reads the document it
        // already holds.
        NativeOperation.analyzeChunks => _docChunkAnalyze(handle, outLen),
        NativeOperation.find =>
          _docFind(handle, requestPtr, request.length, outLen),
        NativeOperation.highlight =>
          _highlight(handle, requestPtr, request.length, outLen),
        NativeOperation.updateHighlighter =>
          _highlighterUpdate(handle, requestPtr, request.length, outLen),
        NativeOperation.highlighterSpans =>
          _highlighterSpans(handle, requestPtr, request.length, outLen),
      };
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

  @override
  Future<T?> findAsync<T>(
    int document,
    Uint8List request,
    T Function(Uint8List) decode,
  ) async {
    final Pointer<Uint8> requestPtr = malloc<Uint8>(request.length);
    // Registered before the call rather than after it: the worker has no idea
    // when this frame ends, and the callback arrives with nothing but the
    // number to find it by.
    final int search = ++_nextSearchId;
    final Completer<Object?> completer = Completer<Object?>();
    _searchesInFlight[search] = _PendingSearch(completer, decode);
    try {
      requestPtr.asTypedList(request.length).setAll(0, request);
      final int handedOff = _docFindAsync(
        document,
        requestPtr,
        request.length,
        _searchCallback.nativeFunction,
        search,
      );
      if (handedOff != 0) {
        // No worker was started, so nothing is going to call back. Doing the
        // search here is slower than the caller was promised, but it is still
        // an answer rather than a failure — and on a platform with no threads
        // at all it is the only way it will ever be answered.
        _searchesInFlight.remove(search);
        return invoke(NativeOperation.find, document, request, decode);
      }
      return await completer.future as T?;
    } finally {
      malloc.free(requestPtr);
    }
  }
}
