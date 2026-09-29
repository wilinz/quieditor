// Compiles `rust/ffi` into a code asset the Dart side can resolve.
//
// This hook runs during every build of any app that depends on re_editor. Most
// of those builds happen on machines with no Rust toolchain, so rather than
// asking the person to install one, the toolchain is fetched into the build
// directory — see `lib/src/hook/rustup.dart` for what that does and why.
//
// There is deliberately no "carry on without the native library" path. The
// editor still *runs* without it (the Dart implementation backs every platform,
// and the web has no native code at all), but a build that silently produced a
// slower editor would be a much worse outcome than a build that failed and said
// why.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';
import 'package:re_editor/src/hook/rustup.dart';

/// The library that declares the `@Native` bindings.
///
/// A `@Native` annotation with no explicit `assetId` resolves symbols against
/// the URI of the library that declares them, so the compiled library has to be
/// registered under exactly this name. Keep it in step with
/// `lib/src/native/native_ffi.dart`.
const String _bindingsLibrary = 'src/native/native_ffi.dart';

void main(List<String> args) async {
  // Where there is no rustup, one is fetched and this hook runs itself again
  // with it on PATH; that copy does the build. This returns false in the copy
  // that started it, whose child has already written the output.
  if (!await ensureRustup(args)) return;

  await build(args, (input, output) async {
    // The hook is also run in modes that want no native code at all — the web,
    // among them — and reading the code configuration in one of those throws.
    if (!input.config.buildCodeAssets) return;

    await const RustBuilder(
      assetName: _bindingsLibrary,
      cratePath: 'rust/ffi',
    ).run(input: input, output: output);

    // Rebuild when the manifest — and so the dependency set — changes.
    // `native_toolchain_rust` already reports the crate's sources, but the
    // manifest itself is not always among them.
    output.dependencies.add(input.packageRoot.resolve('rust/ffi/Cargo.toml'));
  });
}
