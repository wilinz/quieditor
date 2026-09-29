/// The WebAssembly arm of the conditional import in `native.dart`.
///
/// The core is a module rather than a library linked into the process, so
/// almost nothing about reaching it is the same. There are no symbols to
/// resolve, the memory is the module's own rather than this side's, and the
/// room for a request has to be asked for instead of allocated — the ABI grew
/// `re_editor_alloc` for exactly this caller. All of that is [_WasmTransport];
/// what a document is, and what to do when the core declines, is in
/// `native_core.dart` and is shared with every other platform.
///
/// The module is not in this package. `dart run re_editor:fetch_web` puts it
/// where this looks — see `doc/web_build.md`.
library;

import 'dart:async';
import 'dart:js_interop';

// Only for `debugPrint`. This file is compiled into Flutter web builds and
// nowhere else, so it costs the other arms nothing.
import 'package:flutter/foundation.dart';

import 'native_api.dart';
import 'native_core.dart';
import 'native_transport.dart';

/// True on the web: this platform can host the core, given the module.
///
/// Which is not the same as the module being there. [ReEditorNative] answers
/// that separately, by looking.
const bool nativePlatformSupported = true;

/// The ABI this Dart code was written against.
///
/// Must match `quieditor_engine::ABI_VERSION`, as on every other platform: the
/// module is built from the same source and reports the same number.
const int _expectedAbiVersion = 5;

/// Where the module is served from.
///
/// Relative, so it follows whatever the application is mounted under. A Flutter
/// web build serves everything in `web/` from the root, which is where
/// `fetch_web` puts it.
const String _defaultModuleUrl = 'quieditor/quieditor_wasm.wasm';

String _moduleUrl = _defaultModuleUrl;

/// Says where the module is, for an application that serves it elsewhere.
void configureReEditorWeb({required String moduleUrl}) => _moduleUrl = moduleUrl;

// --- The browser's own API --------------------------------------------------
//
// `WebAssembly` is a namespace object rather than a constructor, so it is
// reached as one and its methods are called off it.

@JS('WebAssembly')
external _WebAssembly get _webAssembly;

extension type _WebAssembly._(JSObject _) implements JSObject {
  /// Compiles and instantiates in one step.
  ///
  /// The synchronous `new WebAssembly.Instance(module)` is deliberately not
  /// used: compiling a megabyte of module on the main thread is what the
  /// asynchronous form exists to avoid, and the editor is on the main thread.
  external JSPromise<_InstantiatedSource> instantiate(JSArrayBuffer bytes);
}

extension type _InstantiatedSource._(JSObject _) implements JSObject {
  external _Instance get instance;
}

extension type _Instance._(JSObject _) implements JSObject {
  external _Exports get exports;
}

@JS('fetch')
external JSPromise<_Response> _fetch(String url);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _Memory._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}

/// The module's exports, named as the ABI names them.
///
/// `re_editor_doc_find_async` is not here. Wasm has no threads, so the module's
/// own answer is that it could not start a worker, and the editor's answer to
/// that — search here instead — is what this does directly. Declaring a symbol
/// only to receive a refusal would be worse than not calling it.
extension type _Exports._(JSObject _) implements JSObject {
  external _Memory get memory;

  @JS('re_editor_abi_version')
  external JSFunction get abiVersion;

  @JS('re_editor_abi_info')
  external JSFunction get abiInfo;

  @JS('re_editor_alloc')
  external JSFunction get alloc;

  @JS('re_editor_free')
  external JSFunction get free;

  @JS('re_editor_doc_create')
  external JSFunction get docCreate;

  @JS('re_editor_doc_free')
  external JSFunction get docFree;

  @JS('re_editor_doc_revision')
  external JSFunction get docRevision;

  @JS('re_editor_doc_line_count')
  external JSFunction get docLineCount;

  @JS('re_editor_doc_splice')
  external JSFunction get docSplice;

  @JS('re_editor_doc_chunk_analyze')
  external JSFunction get docChunkAnalyze;

  @JS('re_editor_doc_find')
  external JSFunction get docFind;

  @JS('re_editor_grammar_create')
  external JSFunction get grammarCreate;

  @JS('re_editor_grammar_free')
  external JSFunction get grammarFree;

  @JS('re_editor_highlight')
  external JSFunction get highlight;

  @JS('re_editor_highlighter_create')
  external JSFunction get highlighterCreate;

  @JS('re_editor_highlighter_free')
  external JSFunction get highlighterFree;

  @JS('re_editor_highlighter_update')
  external JSFunction get highlighterUpdate;

  @JS('re_editor_highlighter_spans')
  external JSFunction get highlighterSpans;
}

// --- Calling a wasm export --------------------------------------------------
//
// Every entry point takes at most four `i32`s. Handles are `usize`, which is
// four bytes on wasm32, so they fit a JS number exactly — which is the whole
// reason the ABI was written in terms of `usize` rather than a fixed width.
//
// The four `*_free` entry points answer nothing, and that is not the same as
// answering zero: JavaScript gets `undefined`, and reading it as a number is an
// error rather than a wrong value. They get their own helpers, which is the
// only place the distinction has to be made.

int _i32(JSAny? value) => (value! as JSNumber).toDartInt;

/// JavaScript's `Number`, called as a function.
///
/// This is how a `BigInt` becomes an ordinary number. `dart:js_interop` has no
/// conversion of its own — a `JSBigInt` carries no way out into Dart — and the
/// alternative, going through its decimal string, is slower and no more exact.
@JS('Number')
external int _number(JSAny value);

/// For `re_editor_doc_revision`, which answers a `u64`.
///
/// A `u64` crossing into JavaScript is a `BigInt`, because a JS number cannot
/// hold 64 bits and the wasm JS API has no other way to carry one. So this is
/// the one entry point here that does not hand back a plain number.
///
/// It is also the reason the ABI spells its handles `usize` rather than a fixed
/// width: a `u64` handle would arrive as a `BigInt` too, and every call site
/// would have to know that. A revision is polled rather than stored — it is
/// compared against the last one to decide whether work in flight is still
/// worth applying — so losing the top bits of a value that would need 2^53
/// revisions to reach is not a loss worth a `BigInt` at every call.
int _u64(JSAny? value) =>
    value.isA<JSBigInt>() ? _number(value!) : _i32(value);

int _call0(JSFunction f) => _i32(f.callAsFunction(null));

int _call1(JSFunction f, int a) => _i32(f.callAsFunction(null, a.toJS));

int _call2(JSFunction f, int a, int b) =>
    _i32(f.callAsFunction(null, a.toJS, b.toJS));

int _call4(JSFunction f, int a, int b, int c, int d) =>
    _i32(f.callAsFunction(null, a.toJS, b.toJS, c.toJS, d.toJS));

/// For the entry points that answer nothing.
void _callVoid1(JSFunction f, int a) => f.callAsFunction(null, a.toJS);

void _callVoid2(JSFunction f, int a, int b) =>
    f.callAsFunction(null, a.toJS, b.toJS);

/// The module, compiled and instantiated once.
///
/// Kept only once it works. A module that failed to arrive — a server
/// mid-deploy, a page loaded before `fetch_web` was ever run — is worth asking
/// for again, and a cache that remembered the failure would make the first
/// seconds of a page's life permanent.
Future<_Exports>? _loading;

Future<_Exports> _loadOnce() {
  _loading ??= _load().then(
    (exports) => exports,
    onError: (Object error) {
      _loading = null;
      throw error;
    },
  );
  return _loading!;
}

Future<_Exports> _load() async {
  final _Response response = await _fetch(_moduleUrl).toDart;
  if (!response.ok) {
    throw StateError(
      're_editor: $_moduleUrl answered ${response.status}. Run '
      '`dart run re_editor:fetch_web` in the application once the server is '
      'serving what it built.',
    );
  }
  final JSArrayBuffer bytes = await response.arrayBuffer().toDart;
  final _InstantiatedSource source = await _webAssembly.instantiate(bytes).toDart;
  return source.instance.exports;
}

/// Answers `null`, and means "ask again later" rather than "there is none".
///
/// This is the platform the two entry points exist for. Nothing can be known
/// about the core here until a module has been fetched and compiled, and a
/// browser has no way to wait for that from a synchronous call — so the answer
/// that means "not yet" and the answer that means "never" cannot be told apart
/// from here. [loadReEditorNativeApi] is the one that can tell them apart, and
/// `ReEditorNative` asks it whenever this says nothing.
ReEditorNativeApi? createReEditorNativeApi() => null;

/// Loads the core, or answers `null` when there is not one to be had.
///
/// Everything above this that wants the core asks through
/// `ReEditorNative.prepare()`, once, before the work that wants it. Until then
/// the editor runs on its Dart implementation, which is a document that will
/// keep doing so — see the note in `_code_line.dart` about why a miss during
/// loading is not recorded as never.
Future<ReEditorNativeApi?> loadReEditorNativeApi() async {
  final _Exports exports;
  try {
    exports = await _loadOnce();
  } catch (error) {
    // Said out loud, once, and then the editor falls back like any other
    // refusal. The alternative — the same silence every other failure gets —
    // leaves "dart (native library not found)" in the console with no way to
    // tell a missing module from a typo in its URL from a browser that would
    // not run it, which is exactly the hour this message saves.
    debugPrint('re_editor: the core module could not be loaded: $error');
    return null;
  }
  final int version = _call0(exports.abiVersion);
  if (version != _expectedAbiVersion) {
    // A module that is not the one this Dart was written for is reported as
    // absent rather than used, the same as a stale library on any other
    // platform.
    return null;
  }
  return createNativeCore(_WasmTransport(exports, version));
}

/// The core, reached through the module's exports.
class _WasmTransport implements NativeTransport {
  _WasmTransport(this._exports, this.abiVersion);

  final _Exports _exports;

  @override
  final int abiVersion;

  /// The module's memory, as it stands right now.
  ///
  /// Read fresh every time rather than held. A wasm allocator grows the memory
  /// when it needs room, and growing *detaches* the buffer that was there: a
  /// view taken before an allocation is a view over nothing afterwards, and
  /// using one is how a module that works turns into a crash with no
  /// explanation in it.
  Uint8List get _memory => _exports.memory.buffer.toDart.asUint8List();

  /// A `usize` the module wrote — four bytes, little-endian, on wasm32.
  ///
  /// Read a byte at a time rather than through a typed view: the slot is
  /// wherever the allocator put it, and nothing guarantees it is aligned.
  int _usizeAt(int pointer) {
    final Uint8List memory = _memory;
    return memory[pointer] |
        (memory[pointer + 1] << 8) |
        (memory[pointer + 2] << 16) |
        (memory[pointer + 3] << 24);
  }

  /// Copies [bytes] into the module's memory, and answers where they landed —
  /// or zero, which is what the module reads as "no request".
  int _write(Uint8List bytes) {
    if (bytes.isEmpty) {
      return 0;
    }
    final int pointer = _call1(_exports.alloc, bytes.length);
    if (pointer == 0) {
      return 0;
    }
    _memory.setRange(pointer, pointer + bytes.length, bytes);
    return pointer;
  }

  void _release(int pointer, int length) {
    if (pointer != 0) {
      _callVoid2(_exports.free, pointer, length);
    }
  }

  @override
  Uint8List? abiInfo() {
    final int outLen = _call1(_exports.alloc, 4);
    if (outLen == 0) {
      return null;
    }
    int pointer = 0;
    int length = 0;
    try {
      pointer = _call1(_exports.abiInfo, outLen);
      if (pointer == 0) {
        return null;
      }
      length = _usizeAt(outLen);
      if (length == 0) {
        return null;
      }
      // Copied, unlike every other response: the caller decodes after this
      // returns, and an identity is a few dozen bytes.
      return Uint8List.fromList(
        _exports.memory.buffer.toDart.asUint8List(pointer, length),
      );
    } finally {
      _release(pointer, length);
      _callVoid2(_exports.free, outLen, 4);
    }
  }

  @override
  int create(NativeKind kind, Uint8List request) {
    final int pointer = _write(request);
    if (pointer == 0 && request.isNotEmpty) {
      return 0;
    }
    try {
      return switch (kind) {
        NativeKind.document => _call2(_exports.docCreate, pointer, request.length),
        NativeKind.grammar => _call2(_exports.grammarCreate, pointer, request.length),
        NativeKind.highlighter =>
          _call2(_exports.highlighterCreate, pointer, request.length),
      };
    } finally {
      _release(pointer, request.length);
    }
  }

  @override
  void free(NativeKind kind, int handle) {
    switch (kind) {
      case NativeKind.document:
        _callVoid1(_exports.docFree, handle);
      case NativeKind.grammar:
        _callVoid1(_exports.grammarFree, handle);
      case NativeKind.highlighter:
        _callVoid1(_exports.highlighterFree, handle);
    }
  }

  @override
  int revision(int document) => _u64(
      _exports.docRevision.callAsFunction(null, document.toJS));

  @override
  int lineCount(int document) => _call1(_exports.docLineCount, document);

  @override
  T? invoke<T>(
    NativeOperation operation,
    int handle,
    Uint8List request,
    T Function(Uint8List) decode,
  ) {
    final int requestPtr = _write(request);
    if (requestPtr == 0 && request.isNotEmpty) {
      return null;
    }
    // A slot for the length the module writes back. `usize` is four bytes here.
    final int outLen = _call1(_exports.alloc, 4);
    if (outLen == 0) {
      _release(requestPtr, request.length);
      return null;
    }
    int responsePtr = 0;
    int responseLen = 0;
    try {
      responsePtr = switch (operation) {
        NativeOperation.splice =>
          _call4(_exports.docSplice, handle, requestPtr, request.length, outLen),
        NativeOperation.analyzeChunks => _call2(_exports.docChunkAnalyze, handle, outLen),
        NativeOperation.find =>
          _call4(_exports.docFind, handle, requestPtr, request.length, outLen),
        NativeOperation.highlight =>
          _call4(_exports.highlight, handle, requestPtr, request.length, outLen),
        NativeOperation.updateHighlighter =>
          _call4(_exports.highlighterUpdate, handle, requestPtr, request.length, outLen),
        NativeOperation.highlighterSpans =>
          _call4(_exports.highlighterSpans, handle, requestPtr, request.length, outLen),
      };
      if (responsePtr == 0) {
        return null;
      }
      responseLen = _usizeAt(outLen);
      // A view rather than a copy, and taken after the call that may have grown
      // the memory. Nothing between here and the release below calls into the
      // module, which is what keeps the buffer this points at alive.
      return decode(
        _exports.memory.buffer.toDart.asUint8List(responsePtr, responseLen),
      );
    } finally {
      _release(responsePtr, responseLen);
      _release(requestPtr, request.length);
      _callVoid2(_exports.free, outLen, 4);
    }
  }

  @override
  Future<T?> findAsync<T>(
    int document,
    Uint8List request,
    T Function(Uint8List) decode,
  ) async {
    // Synchronous, and not for want of trying. `wasm32-unknown-unknown` has no
    // threads, so there is no worker to hand this to — and the editor's answer
    // to a search that cannot be handed off is to run it here, which is what
    // every other platform does too when a thread cannot be started.
    return invoke(NativeOperation.find, document, request, decode);
  }
}
