# Running in a browser

On every platform but one, the editor's Rust core arrives as a library the build
hook compiles and links. In a browser it arrives as a file an application has to
serve, and this package does not carry it.

| File | Where it comes from | Moves when |
|---|---|---|
| `quieditor_wasm.wasm` | the `ENGINE_TAG` release | the engine changes |

```sh
dart run re_editor:fetch_web
```

places it in `web/quieditor`, which is where the package looks. The release is
pinned by repository, tag and SHA-256 in [`tool/web.lock`](../tool/web.lock),
downloads are refused if they do not match, and what is downloaded is cached
outside the project — a second checkout on the same machine pays nothing.

`--into DIR` puts it somewhere else, `--offline` fails rather than reaching the
network, and `--from DIR` takes whatever a local build directory holds instead.

## Why nothing here is committed

It was, in the project this arrangement is copied from, and it went out of step
with the Rust it came from: a live page served a fixed bug for a while after the
fix had landed, because rebuilding the module was a step someone had to
remember. Anything that has to be remembered eventually is not.

A build hook cannot place it either. Hooks emit code assets, which are libraries
the Dart runtime loads, and a web build declares it wants none, so
`hook/build.dart` returns before it reaches Rust. A hook also writes into its own
output directory, never into an application's `web/`.

It is a plain file rather than a declared Flutter asset because declaring assets
would make this a Flutter package, and `dart run` and `dart test` would stop
working.

So it is either a committed binary that can rot, or a download that cannot.

## Building the module yourself

To try a change to the engine without waiting for a release:

```sh
git clone https://github.com/wilinz/quieditor_engine
cd quieditor_engine
cargo build -p quieditor_wasm --target wasm32-unknown-unknown --profile wasm
```

Then, from your application:

```sh
dart run re_editor:fetch_web --from ../quieditor_engine/target/wasm32-unknown-unknown/wasm
```

`rust-toolchain.toml` in the engine pins the compiler, so with no local change
this is the same module CI would publish. `--from` wins where it has the file,
so the cache answers if it does not.

The `wasm` profile in the engine's manifest is the one CI uses. It is `release`
with `strip` and one codegen unit, and `panic = "abort"` — which is not a choice
so much as what `wasm32-unknown-unknown` already does. That has a consequence
worth knowing: **a panic in the engine traps the module**, and the instance is
finished. The Dart side treats a trapped module as a core it can no longer use
and falls back to the Dart implementation, which is the same thing every other
refusal does.

## Running the browser tests

`test/native_web_test.dart` puts the whole core through the module — a
document, folds, search, a compiled grammar, a highlighter in pieces — and
compares it against what every other platform answers. It needs a server that
has the module, which the Dart test server is not, so it is told where to look:

The test page and the module come from different origins, so whatever serves the
module has to say it may be read from another one — and `python3 -m http.server`
does not. From a directory holding `quieditor_wasm.wasm`:

```sh
python3 - <<'PY'
import http.server
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()
http.server.HTTPServer(('127.0.0.1', 8789), H).serve_forever()
PY

flutter test --platform chrome test/native_web_test.dart \
  --dart-define=RE_EDITOR_WEB_MODULE=http://127.0.0.1:8789/quieditor_wasm.wasm
```

Without the define the test skips, and says why rather than passing quietly.

The example application is the other way to see it working: `fetch_web` into its
`web/`, build for the web, and it prints which core it is running on when it
starts.

## The check that makes the re-pin unavoidable

`tool/web.lock` names the engine a browser fetches. `rust/Cargo.toml` names the
engine every other platform links. They are two artifacts of one commit, and
nothing about a browser running an older one is visible at run time — it
highlights and folds correctly, and differs only where nobody looks.

```sh
flutter test test/web_lock_test.dart
```

fails when the two drift apart, and runs with the rest of the suite. Moving the
pin is two edits; this is what makes the second one happen.
