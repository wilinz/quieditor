/// The two line-level operations the incremental highlighter needs.
///
/// Both are pure, and both are where a mistake would be silent: an edit read
/// wrongly means highlighting the wrong lines, and a cache spliced wrongly means
/// the lines after an edit belong to the lines before it. Neither shows up as an
/// error — just as the wrong colours, in the wrong places, which is the failure
/// mode this whole seam exists to prevent.
library;

import 'native_api.dart';

/// The smallest edit that turns one document into another, in whole lines.
class LineChange {
  const LineChange(this.start, this.removed, this.added);

  /// The first line that differs.
  final int start;

  /// How many lines of the old document it replaces.
  final int removed;

  /// The lines that replace them.
  final List<String> added;

  @override
  String toString() => 'LineChange($start, -$removed, +${added.length})';
}

/// The edit that turns [before] into [after].
///
/// Lines that match at the front and the back are left alone, which is what
/// makes an edit cost what it touched: typing in the middle of a document leaves
/// the lines above it and below it identical, and the native side is told only
/// about the middle.
///
/// A document that has nothing in common with the previous one comes out as
/// replacing all of it, which is the right answer for a different document in
/// the same editor.
LineChange lineChange(List<String> before, List<String> after) {
  int start = 0;
  while (start < before.length &&
      start < after.length &&
      before[start] == after[start]) {
    start++;
  }
  int end = 0;
  while (end < before.length - start &&
      end < after.length - start &&
      before[before.length - 1 - end] == after[after.length - 1 - end]) {
    end++;
  }
  return LineChange(
    start,
    before.length - start - end,
    after.sublist(start, after.length - end),
  );
}

/// [cache], with the lines a native update covers replaced by [replacement].
///
/// The update says which of the caller's lines it replaces and which of its own
/// it answers with, and those are different ranges whenever the edit added or
/// removed lines: `update.from..update.replaced` of the cache gives way to
/// `update.from..update.to` of the answer. Splicing by those two ranges is what
/// leaves the cache's lines numbered like the document's.
List<T> spliceByLine<T>(
  List<T> cache,
  NativeHighlightUpdate update,
  List<T> replacement,
) {
  final List<T> out = List<T>.of(cache);
  out.removeRange(update.from, update.replaced.clamp(update.from, out.length));
  out.insertAll(update.from, replacement);
  return out;
}
