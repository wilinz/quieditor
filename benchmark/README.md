# Benchmarks

What is here, how to run each, and what the numbers came to when they were last
taken. The numbers are a record, not a promise: they move with the machine, with
the grammar, and with the size of the document.

Everything below was measured on 2026-09-30, on an M-series Mac, against the
`dart` grammar unless it says otherwise.

## Running them

| File | What it measures | How to run it |
|---|---|---|
| `highlight_bench_test.dart` | Highlighting a whole document, Rust against Dart | `flutter test benchmark/highlight_bench_test.dart` |
| `incremental_bench_test.dart` | Opening a document, and a keystroke in one | `flutter test benchmark/incremental_bench_test.dart` |
| `rust_backend_bench_test.dart` | The Rust core against the Dart implementation it replaces | `flutter test benchmark/rust_backend_bench_test.dart` |
| `hotpath_bench_test.dart` | The editor's Dart-side hot paths | `flutter test benchmark/hotpath_bench_test.dart` |
| `example/lib/bench_main.dart` | The same numbers in an AOT build, which is the only fair way to compare Dart with a `--release` Rust core | `flutter build macos --release --target=lib/bench_main.dart`, then `./build/macos/Build/Products/Release/example.app/Contents/MacOS/example` |

`incremental_bench_test.dart` reads `/tmp/bigger.dart` and does nothing if it is
not there. The AOT harness builds its own document instead, because a sandboxed
macOS app cannot reach `/tmp`.

## Performance

### The Rust core against Dart

From `example/lib/bench_main.dart`, release build, 105,001 lines / 1.58 M chars:

| | |
|---|---|
| Rust: highlight the whole document | 319 ms (119,000 nodes) |
| Dart: highlight the whole document | 4,922 ms |
| | **15.4×** |

### Opening a document

From `incremental_bench_test.dart`, the package's own sources at 181,165 lines /
5.53 MB:

| | |
|---|---|
| Open a highlighter (highlights nothing) | 34.8 ms |
| Scan the window it opens with (264 lines) | 5.6 ms |
| **Opening, altogether** | **≈ 40 ms** |
| Scan the rest — *what opening used to cost* | 1,042 ms |

Building a highlighter no longer highlights anything: a document is highlighted
from its top as the editor draws it, and the rest follows on later frames. What
opening used to cost is the line in italics, which is measured here for exactly
that comparison.

Before this, opening also paid a second whole-document scan: the constructor's
pass computed the spans and threw them away, and `spans()` then walked it again
for the answer. Measured separately at the time, the two together were 2,219 ms
on a 4 MB document. So the honest range is **26×** against the one scan, and
around **50×** against what the two of them cost.

### A keystroke

From the AOT harness, 108,162 lines:

| | |
|---|---|
| Rust: splice one line | 0.30 ms |
| Rust: bracket analysis (`analyze`) | 4.84 ms |
| Dart: locating the changed span | 0.067 ms |
| **Per keystroke** | **5.2 ms** |

And the highlighting half of a keystroke, from the same run:

| | |
|---|---|
| Keystroke near the top / middle / end | 0.48 – 0.70 ms, **0 lines re-highlighted** |
| Opening a brace | 0.49 ms, 0 lines re-highlighted |

So a keystroke's cost is the bracket analysis, not the highlighting. Making
keystrokes faster means looking at `chunk::analyze`.

### Memory

RSS, release build, a 5.0 MB document of 120,806 lines, taken in stages:

| Stage | RSS | Change |
|---|---|---|
| Baseline, app started | 92.1 MB | |
| Document text in place | 109.3 MB | +17.2 |
| Highlighter built (highlights nothing) | 134.5 MB | **+25.2** |
| Opening window scanned (264 lines) | 130.0 MB | −4.5 |
| Whole document scanned (409,836 nodes) | 260.8 MB | **+130.8** |
| Highlighter released | 261.0 MB | +0.2 |

What this says: **covering a whole document costs about 131 MB for 5 MB of text
— roughly 26× the text, or 1.1 KB per line.** It is spent on the result, not on
the text: 409,836 span nodes, in the engine, in the encoded buffer that carries
them, and in the objects Dart keeps. Building a highlighter costs 25 MB on its
own, before it has looked at a line.

Highlighting as the editor draws does **not** reduce this. It reduces the wait,
and the background fill walks to the end of the document, so the steady state is
the same as highlighting it all at once. What it does remove is the *transient*
double: the old path held the spans from the constructor's scan and then
produced them again.

## How to read these numbers

* **AOT against JIT.** Everything run through `flutter test` is Dart in JIT debug
  mode with assertions on, while the Rust core is always built `--release`. The
  comparison is unfair in the other direction — Dart is *slower* in AOT on this
  workload, so the test numbers understate the native win. Only
  `example/lib/bench_main.dart` measures both in release.
* **RSS is coarse.** It counts the Flutter engine, the allocator's retained
  pages, and everything else in the process, and it says nothing about what the
  GC has collected. Use it for the shape of the curve, not as an exact account.
  The 5 MB figure above is one run.
* **A freed allocation does not lower RSS.** That the number stays at 261 MB
  after `dispose()` is what most allocators do with freed pages; it is not
  evidence of a leak, and this method cannot rule one out either. A heap profiler
  is the tool for that.
* **One document, one grammar.** Every number here is Dart source through the
  `dart` grammar, measured once. A grammar with more rules, or a document in a
  language with longer strings and comments, moves them.
