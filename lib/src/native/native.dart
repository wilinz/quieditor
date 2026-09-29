/// Chooses how the core is reached, at compile time.
///
/// The conditional import is the whole point of this file. `dart:ffi` does not
/// exist on the web, so `native_ffi.dart` cannot be compiled there;
/// `dart:js_interop` is how the web reaches a module instead. Every arm
/// declares the same top-level names, so nothing above this file sees the seam.
///
/// The order matters and is not arbitrary. `dart.library.ffi` is asked first
/// because it is the one that decides: a platform with `dart:ffi` links a
/// library, and asking about `js_interop` there would be asking about a
/// library that exists but is not how native code is reached. The stub is what
/// is left for a platform with neither — written down rather than left to a
/// compile error.
///
/// This is why the native layer lives in real libraries rather than `part`
/// files: a `part` may not carry its own imports, and a conditional import is
/// an import.
library;

export 'native_api.dart';
export 'native_stub.dart'
    if (dart.library.ffi) 'native_ffi.dart'
    if (dart.library.js_interop) 'native_wasm.dart';
