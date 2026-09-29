// Regenerates the FlatBuffers bindings on both sides of the FFI boundary from
// the schemas in rust/ffi/schema.
//
//   dart run tool/generate_bindings.dart
//
// Run this after editing any .fbs file, and commit the output: the generated
// Rust and Dart both live in the package so that a checkout builds without
// needing flatc installed.
//
// flatc names the Dart file after the namespace (`abi_re_editor.ffi_generated
// .dart`), which is an awkward thing to import. We rename it to match the
// schema instead, so every schema yields `<name>_generated.{rs,dart}`.
import 'dart:io';

import 'package:path/path.dart' as p;

const String _rustOutDir = 'rust/ffi/src/generated';
const String _dartOutDir = 'lib/src/native/generated';

void main(List<String> args) {
  final Directory root = Directory.current;
  if (!File(p.join(root.path, 'pubspec.yaml')).existsSync()) {
    stderr.writeln('Run this from the root of the re_editor package.');
    exitCode = 1;
    return;
  }

  final String flatc = _resolveFlatc();
  final List<File> schemas = Directory(p.join(root.path, 'rust/ffi/schema'))
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.fbs'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  if (schemas.isEmpty) {
    stderr.writeln('No .fbs schemas found under rust/ffi/schema.');
    exitCode = 1;
    return;
  }

  final Directory staging = Directory.systemTemp.createTempSync('re_editor_fbs');
  try {
    final ProcessResult result = Process.runSync(flatc, <String>[
      '--rust',
      '--dart',
      '-o',
      staging.path,
      ...schemas.map((File f) => p.relative(f.path, from: root.path)),
    ]);
    if (result.exitCode != 0) {
      stderr
        ..writeln('flatc failed (${result.exitCode}):')
        ..writeln(result.stdout)
        ..writeln(result.stderr);
      exitCode = result.exitCode;
      return;
    }

    final Directory rustOut = Directory(p.join(root.path, _rustOutDir))
      ..createSync(recursive: true);
    final Directory dartOut = Directory(p.join(root.path, _dartOutDir))
      ..createSync(recursive: true);

    final List<File> staged = staging.listSync().whereType<File>().toList();
    int written = 0;
    for (final File schema in schemas) {
      // flatc derives both output names from the schema's basename, but the
      // Dart one also carries the namespace (`abi_re_editor.ffi_generated
      // .dart`), so match on the prefix rather than reconstructing the name.
      final String base = p.basenameWithoutExtension(schema.path);

      final File? rust = _findStaged(staged, base, '_generated.rs');
      if (rust == null) {
        stderr.writeln('flatc produced no Rust output for ${p.basename(schema.path)}.');
        exitCode = 1;
        return;
      }
      _copy(rust, File(p.join(rustOut.path, '${base}_generated.rs')));
      written++;

      final File? dart = _findStaged(staged, base, '_generated.dart');
      if (dart == null) {
        stderr.writeln('flatc produced no Dart output for ${p.basename(schema.path)}.');
        exitCode = 1;
        return;
      }
      _copy(dart, File(p.join(dartOut.path, '${base}_generated.dart')));
      written++;
    }

    _writeRustModuleIndex(rustOut, schemas);
    stdout.writeln('Regenerated $written binding files from ${schemas.length} schema(s).');
  } finally {
    staging.deleteSync(recursive: true);
  }
}

/// The Rust emitter changed incompatibly between 24.x and 25.x; 24.x output
/// does not compile against the `flatbuffers` crate version this package pins.
const int _minimumFlatcMajor = 25;

String _resolveFlatc() {
  final String? override = Platform.environment['FLATC'];
  final String candidate;
  if (override != null && override.isNotEmpty) {
    candidate = override;
  } else {
    final ProcessResult which = Process.runSync('which', <String>['flatc']);
    if (which.exitCode != 0) {
      stderr.writeln(
        'flatc not found. Install FlatBuffers (brew install flatbuffers) or set '
        'the FLATC environment variable.',
      );
      exit(1);
    }
    candidate = (which.stdout as String).trim();
  }

  final ProcessResult version = Process.runSync(candidate, <String>['--version']);
  final String reported = '${version.stdout}'.trim();
  final int? major = int.tryParse(
    RegExp(r'(\d+)\.').firstMatch(reported)?.group(1) ?? '',
  );
  if (major == null || major < _minimumFlatcMajor) {
    stderr.writeln(
      'flatc at $candidate reports "$reported", which is older than the '
      '$_minimumFlatcMajor.x this package needs.\n'
      'Its Rust output will not compile against the pinned flatbuffers crate. '
      'Install a newer one (brew install flatbuffers) and set FLATC.',
    );
    exit(1);
  }
  return candidate;
}

/// Finds the staged output whose name starts with `<base>_` and ends with
/// [suffix]. The prefix has to be anchored, or `abi` would also match a longer
/// schema name like `abi_v2`.
File? _findStaged(List<File> staged, String base, String suffix) {
  for (final File file in staged) {
    final String name = p.basename(file.path);
    if (name.startsWith('${base}_') && name.endsWith(suffix)) {
      return file;
    }
  }
  return null;
}

void _copy(File from, File to) {
  to.writeAsStringSync(from.readAsStringSync());
}

/// The Rust side needs a module per schema, listed in one place.
void _writeRustModuleIndex(Directory rustOut, List<File> schemas) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('//! FlatBuffers tables generated by `flatc` from `rust/ffi/schema`.')
    ..writeln('//!')
    ..writeln('//! Regenerate with `dart run tool/generate_bindings.dart`; do not edit.')
    ..writeln('//!')
    ..writeln('//! The generated code is not ours to keep tidy, and it predates several')
    ..writeln('//! current idioms, so the lints it trips are switched off here rather than')
    ..writeln('//! in the crate root — this keeps them on for the hand-written shim, where')
    ..writeln('//! they are worth having.')
    ..writeln('//!')
    ..writeln('//! Notably `unsafe_op_in_unsafe_fn`: flatc emits bodies that rely on the')
    ..writeln('//! pre-2024 rule that the body of an `unsafe fn` is implicitly unsafe.')
    ..writeln('#![allow(')
    ..writeln('    clippy::all,')
    ..writeln('    dead_code,')
    ..writeln('    mismatched_lifetime_syntaxes,')
    ..writeln('    missing_debug_implementations,')
    ..writeln('    unsafe_op_in_unsafe_fn,')
    ..writeln('    unused_imports')
    ..writeln(')]')
    ..writeln();
  for (final File schema in schemas) {
    final String module = '${p.basenameWithoutExtension(schema.path)}_generated';
    buffer.writeln('pub mod $module;');
  }
  File(p.join(rustOut.path, 'mod.rs')).writeAsStringSync(buffer.toString());
}
