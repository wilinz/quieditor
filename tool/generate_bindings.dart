// Regenerates the Dart half of the FlatBuffers bindings, from the schemas in
// the engine's repository.
//
//   dart run tool/generate_bindings.dart
//
// Run this after editing any `.fbs` file, and commit the output: the generated
// Dart lives in the package so that a checkout builds without flatc installed.
//
// The schemas are not ours. They describe the wire format the shim reads, and
// the shim lives with the engine — beside the algorithm it wraps, in the same
// repository that builds the WebAssembly module from it. That is where they are
// edited and where their Rust half is generated.
//
// They are taken from the exact checkout the build uses rather than from a copy
// kept here. `rust/Cargo.toml` pins the engine to a tag and `cargo metadata`
// says where that checkout landed, so this side cannot be generated from a
// different revision of the schema than the shim was compiled against. A copy
// would be a second source of truth for a contract that only one of them can be
// right about.
//
// flatc names the Dart file after the namespace (`abi_re_editor.ffi_generated
// .dart`), which is an awkward thing to import. We rename it to match the
// schema instead, so every schema yields `<name>_generated.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String _dartOutDir = 'lib/src/native/generated';

/// The crate whose schema this is.
///
/// Named rather than found by path, because the path is a checkout under
/// cargo's own directory with a hash in it.
const String _schemaCrate = 'quieditor_ffi';

void main(List<String> args) {
  final Directory root = Directory.current;
  if (!File(p.join(root.path, 'pubspec.yaml')).existsSync()) {
    stderr.writeln('Run this from the root of the re_editor package.');
    exitCode = 1;
    return;
  }

  final Directory? schemaDir = _engineSchemaDir(root);
  if (schemaDir == null) {
    return; // Already explained.
  }

  final String flatc = _resolveFlatc();
  final List<File> schemas = schemaDir
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.fbs'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  if (schemas.isEmpty) {
    stderr.writeln('No .fbs schemas found under ${schemaDir.path}.');
    exitCode = 1;
    return;
  }

  final Directory staging = Directory.systemTemp.createTempSync('re_editor_fbs');
  try {
    final ProcessResult result = Process.runSync(flatc, <String>[
      '--dart',
      '-o',
      staging.path,
      ...schemas.map((File f) => f.path),
    ]);
    if (result.exitCode != 0) {
      stderr
        ..writeln('flatc failed (${result.exitCode}):')
        ..writeln(result.stdout)
        ..writeln(result.stderr);
      exitCode = result.exitCode;
      return;
    }

    final Directory dartOut = Directory(p.join(root.path, _dartOutDir))
      ..createSync(recursive: true);

    final List<File> staged = staging.listSync().whereType<File>().toList();
    int written = 0;
    for (final File schema in schemas) {
      // flatc derives the output name from the schema's basename, but the Dart
      // one also carries the namespace (`abi_re_editor.ffi_generated.dart`), so
      // match on the prefix rather than reconstructing the name.
      final String base = p.basenameWithoutExtension(schema.path);

      final File? dart = _findStaged(staged, base, '_generated.dart');
      if (dart == null) {
        stderr.writeln(
          'flatc produced no Dart output for ${p.basename(schema.path)}.',
        );
        exitCode = 1;
        return;
      }
      File(p.join(dartOut.path, '${base}_generated.dart'))
          .writeAsStringSync(dart.readAsStringSync());
      written++;
    }

    stdout.writeln(
      'Regenerated $written binding file(s) from ${schemas.length} schema(s) '
      'in ${schemaDir.path}.',
    );
  } finally {
    staging.deleteSync(recursive: true);
  }
}

/// Where the pinned engine keeps its schemas, or `null` after saying why not.
Directory? _engineSchemaDir(Directory root) {
  final ProcessResult metadata;
  try {
    metadata = Process.runSync('cargo', <String>[
      'metadata',
      '--format-version',
      '1',
      // Not `--no-deps`: the schemas are in a *dependency*, which is the whole
      // point — the version this reads is the one the build compiled against.
      '--manifest-path',
      p.join(root.path, 'rust', 'Cargo.toml'),
    ]);
  } on ProcessException {
    stderr.writeln(
      'cargo not found. The schemas belong to the engine and are read from its '
      'checkout, which only cargo knows the path of; install Rust and try '
      'again.',
    );
    exitCode = 1;
    return null;
  }
  if (metadata.exitCode != 0) {
    stderr
      ..writeln('cargo metadata failed (${metadata.exitCode}):')
      ..writeln(metadata.stderr);
    exitCode = metadata.exitCode;
    return null;
  }

  final Map<String, dynamic> decoded =
      jsonDecode(metadata.stdout as String) as Map<String, dynamic>;
  for (final dynamic entry in decoded['packages'] as List<dynamic>) {
    final Map<String, dynamic> package = entry as Map<String, dynamic>;
    if (package['name'] != _schemaCrate) {
      continue;
    }
    final Directory crateDir =
        Directory(p.dirname(package['manifest_path'] as String));
    final Directory schemaDir = Directory(p.join(crateDir.path, 'schema'));
    if (!schemaDir.existsSync()) {
      stderr.writeln(
        'The engine at ${crateDir.path} has no schema/ directory. It may predate '
        'the move of the schemas into it; raise the pin in rust/Cargo.toml.',
      );
      exitCode = 1;
      return null;
    }
    return schemaDir;
  }

  stderr.writeln(
    'cargo resolved no $_schemaCrate. The schemas are read from that crate, so '
    'either the pin in rust/Cargo.toml is wrong or the engine does not have it.',
  );
  exitCode = 1;
  return null;
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
      'Its output will not compile against the pinned flatbuffers crate. '
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
