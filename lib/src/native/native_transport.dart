/// How a call reaches the Rust core.
///
/// The native layer is written once and reaches the core two ways. Through
/// `dart:ffi` a library is linked into the process, the caller allocates the
/// request, and the loader resolves the symbols by name. Through `WebAssembly`
/// there is a module with a linear memory of its own, no symbols to resolve,
/// and no way to get a request into it except by asking it for the room.
///
/// That difference is small, and it lives entirely below this line. Everything
/// above it — which FlatBuffer to build, what an answer means, what to do when
/// there is none — is in `native_core.dart` and is written once for both.
///
/// A handle is an `int` either way. The core issues them into a table of its
/// own and never hands out an address, so nothing here is pointer-shaped and
/// nothing here can be dereferenced by mistake.
library;

import 'dart:typed_data';

/// Which of the core's three long-lived kinds of value.
enum NativeKind { document, grammar, highlighter }

/// An operation that takes a handle, and usually a request, and answers with a
/// FlatBuffer.
///
/// [analyzeChunks] is the one that carries no request: the document is already
/// on the other side, which is the whole reason it has a handle.
enum NativeOperation {
  splice,
  analyzeChunks,
  find,
  highlight,
  updateHighlighter,
  highlighterSpans,
}

/// The core, as the platform on this side of the boundary allows it to be
/// reached.
abstract interface class NativeTransport {
  /// The ABI the core was built against.
  ///
  /// Read after the arm that selected this transport has already checked it
  /// against the one the Dart was written for, so this is a value both sides
  /// agree on rather than something to compare again.
  int get abiVersion;

  /// The `AbiInfo` the core reports of itself, or null when it cannot say.
  Uint8List? abiInfo();

  /// Takes a value of [kind] from a request, and answers the handle that names
  /// it — or zero, which the core never issues and which means it declined.
  int create(NativeKind kind, Uint8List request);

  /// Releases a handle.
  ///
  /// A handle that is not live — already released, or never issued — does
  /// nothing, so a double release costs a lookup. That is what makes this safe
  /// to leave to a finalizer.
  void free(NativeKind kind, int handle);

  /// The document's revision, or zero when there is no such document.
  int revision(int document);

  /// How many lines the document holds, or zero when there is no such document.
  int lineCount(int document);

  /// Runs [decode] over the answer to [request], while it is still where the
  /// core put it, and answers what [decode] returned.
  ///
  /// Zero-copy, and that is what shapes this: a whole-document highlight is
  /// over a hundred megabytes of response for a five-megabyte document, and
  /// copying every one of them so a reader could walk them once is the cost
  /// this avoids. The consequence lands on [decode] — it has to turn the bytes
  /// into plain Dart values, because nothing it leaves pointing at them outlives
  /// the call.
  ///
  /// Answers null when the core declined, which is not the same as an empty
  /// answer and is read differently by every caller that can tell them apart.
  T? invoke<T>(
    NativeOperation operation,
    int handle,
    Uint8List request,
    T Function(Uint8List) decode,
  );

  /// Searches, on a worker thread where there is one.
  ///
  /// The whole arrangement is the transport's business. Whether a worker can
  /// exist at all is a fact about the platform — `wasm32-unknown-unknown` has
  /// no threads — and what to do when there is none is the same everywhere, so
  /// it is decided once here rather than by every caller.
  Future<T?> findAsync<T>(
    int document,
    Uint8List request,
    T Function(Uint8List) decode,
  );
}
