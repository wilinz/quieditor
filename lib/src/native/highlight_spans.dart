/// Replays the native highlighter's answer into a renderer.
///
/// The native side reports a flat list of scoped spans; a renderer wants the
/// events a tree walk produces. Replaying into the editor's own renderer is what
/// keeps the two implementations drawing the same thing — a span that crosses a
/// line break becomes a node on each line because that is what the renderer does
/// with text containing a break, and a scope becomes a class name for the same
/// reason it always did.
library;

import 'package:re_highlight/re_highlight.dart';

import 'native_api.dart';

/// Feeds `nodes` to `renderer` as if it had walked the tree they describe.
///
/// [nodes] are in reading order, each one before the nodes nested inside it,
/// and its depth says how many enclose it — which is all that is needed to
/// reconstruct the walk. A node deeper than the last is inside it, one at the
/// same depth is its next sibling, and one shallower closes as many as it takes.
///
/// The text between the spans is replayed too, unscoped. Every character has to
/// reach the renderer exactly once and in order, or the line the editor draws
/// would not be the line it holds.
void replayHighlightSpans({
  required String code,
  required List<NativeHighlightNode> nodes,
  required HighlightRenderer renderer,
}) {
  // Spans arrive as a line and an offset into it, which is how the editor
  // counts; the renderer wants offsets into the whole text, so each line's
  // start is worked out once rather than per span.
  final List<int> lineStarts = _lineStarts(code);
  int cursor = 0;

  void addTextUntil(int end) {
    if (end > cursor) {
      renderer.addText(code.substring(cursor, end));
      cursor = end;
    }
  }

  int startOf(NativeHighlightNode node) => _offset(lineStarts, code, node.startLine, node.startOffset);
  int endOf(NativeHighlightNode node) => _offset(lineStarts, code, node.endLine, node.endOffset);

  // The renderer is inside a node before it is given anything: highlight.js
  // reports the whole document as a node with no scope, and a client that opens
  // its first scope while nothing is open yet is a client written against a
  // different event stream. Opening it here is what makes the two streams the
  // same rather than merely equivalent.
  renderer.openNode(DataNode(children: const <Object>[]));

  final List<int> open = <int>[];
  for (final NativeHighlightNode node in nodes) {
    // Close whatever this node is not inside. A node nested `depth` deep is
    // inside the one at `depth - 1`, so anything at that depth or deeper has
    // ended by the time this one starts.
    while (open.length > node.depth) {
      final int closing = open.removeLast();
      addTextUntil(closing);
      renderer.closeNode(DataNode(children: const <Object>[]));
    }

    addTextUntil(startOf(node));
    renderer.openNode(DataNode(scope: node.scope, children: const <Object>[]));
    open.add(endOf(node));
  }

  while (open.isNotEmpty) {
    final int closing = open.removeLast();
    addTextUntil(closing);
    renderer.closeNode(DataNode(children: const <Object>[]));
  }
  // Whatever follows the last span.
  addTextUntil(code.length);
  renderer.closeNode(DataNode(children: const <Object>[]));
}

/// The index each line of [code] begins at.
List<int> _lineStarts(String code) {
  final List<int> starts = <int>[0];
  for (int index = 0; index < code.length; index++) {
    if (code.codeUnitAt(index) == 0x0a) {
      starts.add(index + 1);
    }
  }
  return starts;
}

/// Where a line and an offset into it land in the whole text.
///
/// Clamped rather than trusted: a span that does not fit the text it came with
/// would otherwise be a range error in the middle of drawing a frame, and the
/// alternative — the tail of the document drawn as part of the last line — is a
/// rendering that is wrong rather than a frame that does not happen.
int _offset(List<int> lineStarts, String code, int line, int offset) {
  if (line < 0 || line >= lineStarts.length) {
    return code.length;
  }
  return (lineStarts[line] + offset).clamp(lineStarts[line], code.length);
}
