/// Chooses the native implementation at compile time.
///
/// The conditional import is the whole point of this file: `dart:ffi` does not
/// exist on the web, so `native_ffi.dart` cannot be compiled there, and the web
/// build needs `native_stub.dart` in its place. Both declare the same
/// top-level names, so callers never see the seam.
///
/// This is why the native layer lives in real libraries rather than `part`
/// files: a `part` may not carry its own imports, and a conditional import is
/// an import.
library;

export 'native_api.dart';
export 'native_stub.dart' if (dart.library.ffi) 'native_ffi.dart';
