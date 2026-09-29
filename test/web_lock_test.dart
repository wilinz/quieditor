/// The browser's module and the native library have to be the same engine.
///
/// They are two artifacts of one commit, released together and pinned apart:
/// `tool/web.lock` names the tag a browser fetches, and `rust/Cargo.toml` names
/// the tag every other platform links against. Neither file can see the other,
/// and nothing about a browser running an engine a version behind is visible at
/// run time — it highlights and folds correctly, and differs only where nobody
/// looks.
///
/// So it is checked here rather than trusted. Moving the pin is two edits, and
/// this is what makes the second one happen.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The value of `KEY=` in a `key=value` file, or null.
String? _lockValue(String path, String key) {
  for (final String line in File(path).readAsLinesSync()) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    final int i = trimmed.indexOf('=');
    if (i > 0 && trimmed.substring(0, i) == key) {
      return trimmed.substring(i + 1);
    }
  }
  return null;
}

/// The tag `rust/Cargo.toml` pins the engine to.
String? _cargoEngineTag() {
  final RegExp pin = RegExp(
    r'^quieditor_ffi\s*=\s*\{[^}]*\btag\s*=\s*"([^"]+)"',
    multiLine: true,
  );
  return pin.firstMatch(File('rust/Cargo.toml').readAsStringSync())?.group(1);
}

void main() {
  test('the module a browser fetches is the engine every other platform links',
      () {
    final String? locked = _lockValue('tool/web.lock', 'ENGINE_TAG');
    final String? pinned = _cargoEngineTag();

    expect(locked, isNotNull, reason: 'tool/web.lock has no ENGINE_TAG');
    expect(pinned, isNotNull, reason: 'rust/Cargo.toml pins no engine tag');
    expect(
      locked,
      pinned,
      reason: 'A browser would run $locked while every other platform runs '
          '$pinned. Raise both together: the tag in tool/web.lock and the one '
          'in rust/Cargo.toml, and the checksum beside it — see the note at the '
          'top of tool/web.lock.',
    );
  });

  test('the lock names a checksum and a module', () {
    expect(
      _lockValue('tool/web.lock', 'ENGINE_SHA256'),
      matches(RegExp(r'^[0-9a-f]{64}$')),
      reason: 'fetch_web verifies the download against this, so it has to be a '
          'sha256 and not a placeholder',
    );
    expect(_lockValue('tool/web.lock', 'ENGINE_MODULE'), endsWith('.wasm'));
    expect(_lockValue('tool/web.lock', 'ENGINE_REPO'), contains('/'));
  });
}
