/// The no-native-code arm of the conditional import in `native.dart`.
///
/// Selected when `dart.library.ffi` is absent — the web, today — so that
/// nothing above this file has to know the platform. There is nothing to load
/// and nothing to call, and the editor uses its Dart implementation.
library;

import 'native_api.dart';

/// Returns `null`: this build has no native core.
///
/// Always inlined to a constant, so callers can drop their native branches
/// entirely on platforms that never have one.
ReEditorNativeApi? createReEditorNativeApi() => null;

/// Whether this platform can host the Rust core at all.
///
/// `false` here; the FFI arm answers by probing. Callers use it to skip the
/// probe rather than to guess at the result.
const bool nativePlatformSupported = false;
