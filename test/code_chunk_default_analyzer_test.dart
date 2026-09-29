// The one chunk analyzer this package ships, which is a way of asking the Rust
// core with lines rather than with a document.
//
// The analysis itself is the core's and is tested there: `chunk::tests` in
// `rust/core/src/chunk.rs` is where the brackets, the strings and the nesting
// are worked out. What is left to test here is the API — that a caller holding
// nothing but lines gets the same answer a document would give, and that a build
// with no core gets no answer rather than a different one.
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  const DefaultCodeChunkAnalyzer analyzer = DefaultCodeChunkAnalyzer();
  final bool native = ReEditorNative.isAvailable;
  final String? skip = native
      ? null
      : 'no native core (${ReEditorNative.backendDescription}) — this analyzer '
          'has no analysis to give without one';

  /// The chunks of a document written as one string.
  List<CodeChunk> chunksOf(String text) =>
      analyzer.run(CodeLines.of(text.split('\n').map(CodeLine.new).toList()));

  test('finds a region that spans lines', () {
    expect(chunksOf('a(\nb\nc\n)'), <CodeChunk>[const CodeChunk(0, 3)]);
  }, skip: skip);

  test('finds the innermost regions, not the outermost alone', () {
    expect(
      chunksOf('{\nx(\ny\n)\n}'),
      <CodeChunk>[const CodeChunk(0, 4), const CodeChunk(1, 3)],
    );
  }, skip: skip);

  test('a bracket that opens and closes on one line hides nothing', () {
    expect(chunksOf('a(b)c'), isEmpty);
  }, skip: skip);

  test('a bracket inside a string is not a region', () {
    expect(chunksOf('"a(\nb"'), isEmpty);
  }, skip: skip);
}
