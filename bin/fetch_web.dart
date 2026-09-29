/// Puts the engine's WebAssembly module where an application can serve it.
///
///     dart run re_editor:fetch_web              # into web/quieditor
///     dart run re_editor:fetch_web --into DIR
///     dart run re_editor:fetch_web --from DIR   # from a local build
///     dart run re_editor:fetch_web --offline    # cache only, never the network
///
/// The module is not carried in this package. A compiled artifact sitting
/// beside the sources it came from goes out of step with them, and one did in
/// the project this arrangement is copied from: a live page served a fixed bug
/// for a while after Rust had been corrected, because rebuilding it was a step
/// someone had to remember. Anything that has to be remembered eventually is
/// not.
///
/// So it is built by the engine's CI and fetched from a release, pinned by
/// repository, tag and checksum in `tool/web.lock`. The engine is where it can
/// be built: the module is compiled from the same source as the C ABI every
/// other platform links, and rebuilt whenever the engine changes.
///
/// It is a file rather than a declared Flutter asset because declaring assets
/// would make this a Flutter package, and `dart run` and `dart test` would stop
/// working. A build hook cannot place it either: hooks emit code assets, which
/// are libraries the Dart runtime loads, and a web build declares it wants
/// none, so the hook returns before reaching Rust. A hook also writes into its
/// own output directory, never into an application's `web/`.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  // The Dart VM ignores whatever `main` returns, so the status has to be set
  // rather than returned. Without this every failure below would leave the
  // process reporting success, which a build script would never notice.
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return 0;
  }

  final into = Directory(_option(args, '--into') ?? 'web/quieditor');
  final from = _option(args, '--from');
  final offline = args.contains('--offline');

  final packageRoot = await _packageRoot();
  if (packageRoot == null) {
    stderr.writeln(
      're_editor: could not find the package. Run this from an application '
      'that depends on re_editor.',
    );
    return 1;
  }

  final _Lock lock;
  try {
    lock = _Lock.read(File('${packageRoot.path}/tool/web.lock'));
  } on FormatException catch (e) {
    stderr.writeln('re_editor: ${e.message}');
    return 1;
  }

  // A local build wins if it has the file, so a change to the engine can be
  // tried without waiting for a release.
  final File source;
  final String where;
  final File? built = from == null ? null : File('$from/${lock.module}');
  if (built != null && built.existsSync()) {
    source = built;
    where = '${_size(built)}  (from $from)';
  } else {
    try {
      source = await _fetch(
        repo: lock.repo,
        tag: lock.tag,
        name: lock.module,
        want: lock.sha256,
        // Downloads are kept between runs, keyed by the checksum they must
        // have, so a second project on the same machine pays nothing, and a
        // re-run after a failure pays nothing either.
        cache: Directory('${_cacheRoot()}/re_editor/web'),
        offline: offline,
      );
    } on _FetchFailure catch (e) {
      stderr.writeln(e.message);
      return 1;
    }
    where = '${_size(source)}  (${lock.tag})';
  }

  into.createSync(recursive: true);
  source.copySync('${into.path}/${lock.module}');
  stdout.writeln('  ${lock.module}  $where');
  stdout.writeln(
    '\nPut into ${into.path}. That is where the package looks — if the module '
    'has to be served from somewhere else, say so with configureReEditorWeb() '
    'from package:re_editor/src/native/native_wasm.dart.',
  );
  return 0;
}

/// Gets the release asset, from the cache if it is already there.
///
/// The checksum names the file in the cache as well as guaranteeing it: a hit
/// is a file already known to be the right one, so nothing is verified twice,
/// and a pin that changes cannot be answered by a stale copy.
Future<File> _fetch({
  required String repo,
  required String tag,
  required String name,
  required String want,
  required Directory cache,
  required bool offline,
}) async {
  final cached = File('${cache.path}/$want/$name');
  if (cached.existsSync()) return cached;

  final url = 'https://github.com/$repo/releases/download/$tag/$name';
  if (offline) {
    throw _FetchFailure(
      're_editor: $name is not in the cache and --offline was given.\n'
      '  It would have come from $url',
    );
  }

  stdout.writeln('  fetching $name from $tag');
  final bytes = await _get(url);

  final got = sha256.convert(bytes).toString();
  if (got != want) {
    throw _FetchFailure(
      '''
re_editor: $name is not what tool/web.lock pins.
  from     $url
  pinned   $want
  received $got

  A release asset can be replaced, so nothing here uses bytes the lock does not
  name. If the engine was released on purpose, re-pin it: take the checksum
  from the `quieditor_wasm.build` beside the module in that release.''',
    );
  }

  cached.parent.createSync(recursive: true);
  // Written beside and moved into place, so an interrupted run cannot leave a
  // truncated file under a name that says it has been checked.
  File('${cached.path}.part')
    ..writeAsBytesSync(bytes)
    ..renameSync(cached.path);
  return cached;
}

Future<List<int>> _get(String url) async {
  final client = HttpClient();
  try {
    final response = await client.getUrl(Uri.parse(url)).then((r) => r.close());
    if (response.statusCode != 200) {
      throw _FetchFailure(
        're_editor: $url answered ${response.statusCode}.\n'
        '  The tag in tool/web.lock may not exist, or may not carry this '
        'asset.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  } on SocketException catch (e) {
    throw _FetchFailure('re_editor: could not reach $url ($e)');
  } finally {
    client.close();
  }
}

class _FetchFailure implements Exception {
  const _FetchFailure(this.message);
  final String message;
}

/// `tool/web.lock`: the whole of what this package trusts about the one
/// artifact it does not carry.
class _Lock {
  const _Lock({
    required this.repo,
    required this.tag,
    required this.module,
    required this.sha256,
  });

  final String repo, tag, module, sha256;

  static _Lock read(File file) {
    if (!file.existsSync()) throw FormatException('${file.path} is missing');
    final values = <String, String>{};
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final i = trimmed.indexOf('=');
      if (i > 0) values[trimmed.substring(0, i)] = trimmed.substring(i + 1);
    }
    String need(String key) =>
        values[key] ?? (throw FormatException('${file.path} has no $key'));
    return _Lock(
      repo: need('ENGINE_REPO'),
      tag: need('ENGINE_TAG'),
      module: need('ENGINE_MODULE'),
      sha256: need('ENGINE_SHA256'),
    );
  }
}

/// Where downloads are kept between runs.
///
/// Outside the project, so several checkouts share one copy, and under the
/// platform's own cache directory so that clearing caches clears this too.
String _cacheRoot() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  if (Platform.isWindows) return env['LOCALAPPDATA'] ?? '$home/AppData/Local';
  if (Platform.isMacOS) return '$home/Library/Caches';
  return env['XDG_CACHE_HOME'] ?? '$home/.cache';
}

const _usage = '''
Places the engine's WebAssembly module for an application to serve.

  dart run re_editor:fetch_web [--into DIR] [--from DIR] [--offline]

  --into DIR   where to put it; web/quieditor by default, which is where the
               package looks without being told otherwise
  --from DIR   take the module from this directory instead of from a release.
               Building the engine's `quieditor_wasm` crate and pointing this
               at its output is how to try a change to the engine without
               waiting for a release.
  --offline    use only what has already been downloaded, and fail rather than
               reach the network

The module is not carried in this package. It is fetched from the release named
in tool/web.lock, checked against the checksum there, and kept in a cache
between runs.
''';

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

String _size(File file) {
  final kb = file.lengthSync() / 1024;
  return kb < 1024
      ? '${kb.round()} KB'
      : '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// This package's root.
///
/// Resolved through the package config rather than from `Platform.script`,
/// which under `dart run re_editor:fetch_web` points at a snapshot in
/// `.dart_tool` instead of at the package.
Future<Directory?> _packageRoot() async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:re_editor/'));
  if (uri == null) return null;
  return Directory.fromUri(uri.resolve('..'));
}
