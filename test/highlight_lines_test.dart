// The two line-level operations the incremental highlighter is built on.
//
// They are pure, and they are where a mistake would be silent: an edit read
// wrongly means highlighting the wrong lines, and a cache spliced wrongly means
// every line after an edit belongs to the line before it. Neither shows up as an
// error — only as the wrong colours in the wrong places.

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_editor/src/native/highlight_lines.dart';

/// A document of `count` lines, `line n`.
List<String> document(int count) =>
    List<String>.generate(count, (index) => 'line $index');

void main() {
  group('lineChange', () {
    test('finds a line that changed in the middle', () {
      final List<String> before = document(10);
      final List<String> after = <String>[...before]..[4] = 'changed';
      expect(lineChange(before, after).start, 4);
      expect(lineChange(before, after).removed, 1);
      expect(lineChange(before, after).added, <String>['changed']);
    });

    test('finds lines that were added', () {
      final List<String> before = document(10);
      final List<String> after = <String>[...before]..insert(4, 'new');
      final LineChange change = lineChange(before, after);
      expect(change.start, 4);
      expect(change.removed, 0);
      expect(change.added, <String>['new']);
    });

    test('finds lines that were removed', () {
      final List<String> before = document(10);
      final List<String> after = <String>[...before]..removeAt(4);
      final LineChange change = lineChange(before, after);
      expect(change.start, 4);
      expect(change.removed, 1);
      expect(change.added, isEmpty);
    });

    test('leaves the lines that match at both ends alone', () {
      // The whole point: the edit is one line in the middle, not the document.
      final List<String> before = document(1000);
      final List<String> after = <String>[...before]..[500] = 'edited';
      final LineChange change = lineChange(before, after);
      expect(change.start, 500);
      expect(change.removed, 1);
      expect(change.added, <String>['edited']);
    });

    test('replaces everything for a document with nothing in common', () {
      final LineChange change = lineChange(<String>['a', 'b'], <String>['c', 'd']);
      expect(change.start, 0);
      expect(change.removed, 2);
      expect(change.added, <String>['c', 'd']);
    });

    test('reports nothing for a document that did not change', () {
      final List<String> lines = document(5);
      final LineChange change = lineChange(lines, List<String>.of(lines));
      expect(change.removed, 0);
      expect(change.added, isEmpty);
    });
  });

  group('spliceByLine', () {
    /// An update that replaces the lines `from..replaced` with `count` new ones.
    NativeHighlightUpdate update({
      required int from,
      required int replaced,
      required int count,
    }) =>
        NativeHighlightUpdate(
          from: from,
          to: from + count,
          replaced: replaced,
          scannedTo: from + count,
          nodes: const <NativeHighlightNode>[],
        );

    test('keeps the lines either side of an edit', () {
      final List<String> cache = document(10);
      final List<String> out = spliceByLine(
        cache,
        update(from: 3, replaced: 4, count: 1),
        <String>['new'],
      );
      expect(out.length, 10);
      expect(out[2], 'line 2');
      expect(out[3], 'new');
      expect(out[4], 'line 4');
    });

    test('makes room for lines that were added', () {
      final List<String> cache = document(10);
      final List<String> out = spliceByLine(
        cache,
        update(from: 3, replaced: 3, count: 2),
        <String>['a', 'b'],
      );
      expect(out.length, 12);
      expect(out.sublist(2, 6), <String>['line 2', 'a', 'b', 'line 3']);
    });

    test('closes the gap when lines were removed', () {
      final List<String> cache = document(10);
      final List<String> out = spliceByLine(
        cache,
        update(from: 3, replaced: 5, count: 0),
        <String>[],
      );
      expect(out.length, 8);
      expect(out.sublist(2, 4), <String>['line 2', 'line 5']);
    });

    test('answers with what an edit did, applied to a cache that matches it', () {
      // Typing a character into line 4 of a document: the update covers the
      // lines it re-highlighted, and the cache has to come out with the same
      // lines as the document does.
      final List<String> before = document(10);
      final List<String> after = <String>[...before]..[4] = 'lined 4';
      final LineChange change = lineChange(before, after);
      final List<String> out = spliceByLine(
        before,
        NativeHighlightUpdate(
          from: change.start,
          to: change.start + change.added.length,
          replaced: change.start + change.removed,
          scannedTo: change.start + change.added.length,
          nodes: const <NativeHighlightNode>[],
        ),
        change.added,
      );
      expect(out, after);
    });
  });
}
