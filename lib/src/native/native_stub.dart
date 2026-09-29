/// The no-native-code arm of the conditional import in `native.dart`.
///
/// Selected when there is neither `dart:ffi` nor `dart:js_interop`, which in
/// practice is nowhere: the two real arms cover every platform this package
/// builds for. It is the default rather than a special case, so a platform that
/// arrives with neither has somewhere to land that is written down.
library;

import 'native_api.dart';

/// Returns `null`: this build has no native core.
ReEditorNativeApi? createReEditorNativeApi() => null;

/// The same, asynchronously.
Future<ReEditorNativeApi?> loadReEditorNativeApi() async => null;

/// Whether this platform can host the Rust core at all.
///
/// `false` here; the FFI arm answers by probing. Callers use it to skip the
/// probe rather than to guess at the result.
const bool nativePlatformSupported = false;
