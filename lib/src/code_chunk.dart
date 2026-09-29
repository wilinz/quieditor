part of re_editor;

class CodeChunkController extends ValueNotifier<List<CodeChunk>> {

  late final CodeLineEditingController _controller;
  final CodeChunkAnalyzer _analyzer;

  late final _IsolateTasker<_CodeChunkAnalyzePayload, _CodeChunkAnalyzeResult> _tasker;

  late bool _shouldNotUpdateChunks;

  /// Set in [dispose], so a deferred analysis does not write to a notifier that
  /// is no longer listening.
  bool _disposed = false;

  CodeChunkController(CodeLineEditingController controller, this._analyzer) : super(const []) {
    _controller = controller is _CodeLineEditingControllerDelegate ? controller.delegate : controller;
    _controller.addListener(_onCodeChanged);
    _tasker = _IsolateTasker<_CodeChunkAnalyzePayload, _CodeChunkAnalyzeResult>('CodeChunk', _run);
    _shouldNotUpdateChunks = false;
    _runChunkAnalyzeTask();
  }

  void collapse(int index) {
    final CodeChunk? chunk = findByIndex(index);
    if (chunk == null) {
      // Not support to collapse
      return;
    }
    if (!chunk.canCollapse) {
      // Has collapsed or nothing to collapse
      return;
    }
    final List<CodeChunk> codeChunks = List.of(value);
    // Remove sub chunks
    codeChunks.removeWhere((e) => e.index > chunk.index && e.end < chunk.end);
    // Chunks after the collapsed should adjust the offset
    for (int i = 0; i < codeChunks.length; i++) {
      final CodeChunk e = codeChunks[i];
      if (e.index >= index || e.end >= index) {
        codeChunks[i] = CodeChunk(e.index > index ? e.index - chunk.collapseSize : e.index,
          e.end > index ? e.end - chunk.collapseSize : e.end
        );
      }
    }
    value = codeChunks;
    _shouldNotUpdateChunks = true;
    _controller.collapseChunk(chunk.index, chunk.end);
    _shouldNotUpdateChunks = false;
  }

  void expand(int index) {
    final CodeLine codeLine = _controller.codeLines[index];
    if (!codeLine.chunkParent) {
      // Nothing to expand, this should not happen.
      return;
    }
    final List<CodeChunk> codeChunks = List.of(value);
    bool exists = false;
    for (int i = 0; i < codeChunks.length; i++) {
      final CodeChunk e = codeChunks[i];
      if (e.index >= index || e.end >= index) {
        codeChunks[i] = CodeChunk(e.index > index ? e.index + codeLine.chunks.length : e.index,
          e.end > index ? e.end + codeLine.chunks.length : e.end
        );
      }
      if (e.index == index) {
        exists = true;
      }
    }
    // Add self into the chunks if not exists
    if (!exists) {
      codeChunks.add(CodeChunk(index, index + codeLine.chunks.length + 1));
      // sort by index
      codeChunks.sort((a, b) => a.index - b.index);
    }
    value = codeChunks;
    _controller.expandChunk(index);
  }

  void toggle(int index) {
    if (_controller.codeLines[index].chunkParent) {
      expand(index);
    } else {
      collapse(index);
    }
  }

  CodeChunk? findByIndex(int index) {
    for (final CodeChunk chunk in value) {
      if (chunk.index == index) {
        return chunk;
      } else if (chunk.index > index) {
        break;
      }
    }
    return null;
  }

  bool canCollapse(int index) {
    return findByIndex(index)?.canCollapse ?? false;
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.removeListener(_onCodeChanged);
    _tasker.close();
    super.dispose();
  }

  void _onCodeChanged() {
    if (_shouldNotUpdateChunks) {
      return;
    }
    if (_controller.codeLines.length < 3 && value.isEmpty) {
      value = [];
      return;
    }
    if (_controller.codeLines.equals(_controller.preValue?.codeLines)) {
      return;
    }
    _runChunkAnalyzeTask();
  }

  /// The controller that owns the native document, if this is one of ours.
  ///
  /// Null for a custom [CodeLineEditingController] implementation, which has
  /// nowhere to keep a native mirror; those go through the analyzer, which
  /// builds a document of its own to ask the core with.
  _CodeLineEditingControllerImpl? get _nativeOwner =>
      _controller is _CodeLineEditingControllerImpl
          ? _controller as _CodeLineEditingControllerImpl
          : null;

  void _runChunkAnalyzeTask() {
    final CodeLines codeLines = _controller.codeLines;
    // The exact runtime type, not `is`: an analyzer that subclasses the default
    // one to override `run` would otherwise silently get the built-in analysis
    // instead of its own. The isolate path costs a frame, which is nothing next
    // to being wrong.
    if (_analyzer.runtimeType == DefaultCodeChunkAnalyzer) {
      final NativeChunkAnalysis? analysis = _nativeOwner?.analyzeChunksNatively();
      if (analysis != null) {
        final List<CodeChunk> chunks = analysis.chunks
            .map((NativeChunk chunk) => CodeChunk(chunk.index, chunk.end))
            .toList();
        // The analysis itself ran just now, inside the controller's own
        // notification. *Applying* it is deferred, for two reasons that both
        // come from where this is called.
        //
        // The first is ordering. `expand()` and `collapse()` maintain `value`
        // themselves and then mutate the controller; the re-analysis that
        // follows has always landed after that work rather than in the middle
        // of it, and the sequence callers observe should not depend on which
        // implementation is running.
        //
        // The second is reentrancy. `_expandInvalidCollapsedChunks` calls
        // `expand()`, which writes back to the controller. Deferring keeps that
        // out of the notification it came from.
        scheduleMicrotask(() {
          if (_disposed || !_controller.codeLines.equals(codeLines)) {
            return;
          }
          value = chunks;
          _expandInvalidCollapsedChunks(_invalidCollapsedChunks(codeLines, chunks));
        });
        return;
      }
    }
    _tasker.run(_CodeChunkAnalyzePayload(_analyzer, codeLines), (result) {
      if (_controller.codeLines.equals(codeLines)) {
        value = result.chunks;
        _expandInvalidCollapsedChunks(result.invalidCollapsedChunkIndexes);
      }
    });
  }

  /// Collapsed lines whose folded state no longer matches the analysis.
  ///
  /// A line that holds chunks but no longer starts a region — or whose region
  /// no longer has anything to hide — was collapsed against an older document
  /// and has to be opened back up.
  static List<int> _invalidCollapsedChunks(CodeLines codeLines, List<CodeChunk> chunks) {
    final List<int> invalid = [];
    for (int i = 0; i < codeLines.length; i++) {
      if (!codeLines[i].chunkParent) {
        continue;
      }
      final int index = chunks.indexWhere((e) => e.index == i);
      if (index < 0 || chunks[index].canCollapse) {
        invalid.add(i);
      }
    }
    return invalid;
  }

  void _expandInvalidCollapsedChunks(List<int> indexes) {
    // Expand invalid chunks from bottom to top
    for (int i = indexes.length - 1; i >=0; i--) {
      expand(indexes[i]);
    }
  }

  @pragma('vm:entry-point')
  static _CodeChunkAnalyzeResult _run(_CodeChunkAnalyzePayload payload) {
    final List<CodeChunk> chunks = payload.analyzer.run(payload.codeLines);
    return _CodeChunkAnalyzeResult(
      chunks,
      _invalidCollapsedChunks(payload.codeLines, chunks),
    );
  }

}

class CodeChunk {

  final int index;
  final int end;

  const CodeChunk(this.index, this.end);

  bool get canCollapse => collapseSize > 0;

  int get collapseSize => end - index - 1;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is CodeChunk
        && other.index == index
        && other.end == end;
  }

  @override
  int get hashCode => Object.hash(index, end);

  @override
  String toString() {
    return '[$index, $end]';
  }

}

abstract class CodeChunkAnalyzer {

  List<CodeChunk> run(CodeLines codeLines);

}

class NonCodeChunkAnalyzer implements CodeChunkAnalyzer {

  const NonCodeChunkAnalyzer();

  @override
  List<CodeChunk> run(CodeLines codeLines) => const [];

}

class DefaultCodeChunkAnalyzer implements CodeChunkAnalyzer {

  const DefaultCodeChunkAnalyzer();

  /// Answers with the collapsible regions of [codeLines].
  ///
  /// The analysis is the Rust core's, and this is a way of asking it with lines
  /// rather than with a document: it puts the lines into a native document of
  /// their own and reads the analysis back out. That is a whole document's work
  /// for one answer, which is why the editor does not go through it — a
  /// controller that has one keeps it and asks it directly — but a caller
  /// holding nothing but lines has no other way to the same answer.
  ///
  /// A build with no native core has no analysis to give, and answers with none:
  /// there is no second implementation of this in Dart.
  @override
  List<CodeChunk> run(CodeLines codeLines) {
    final List<NativeLine> lines = <NativeLine>[];
    for (int i = 0; i < codeLines.length; i++) {
      final CodeLine line = codeLines[i];
      lines.add(NativeLine(line.text, line.chunks.map((CodeLine chunk) => chunk.text).toList()));
    }
    final NativeDocument? document = ReEditorNative.openDocument(lines);
    if (document == null) {
      return const <CodeChunk>[];
    }
    try {
      return document
          .analyzeChunks()
          .chunks
          .map((NativeChunk chunk) => CodeChunk(chunk.index, chunk.end))
          .toList();
    } finally {
      document.dispose();
    }
  }

}

class CodeChunkSymbol {

  final String value;
  final int index;

  const CodeChunkSymbol(this.value, this.index);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is CodeChunkSymbol
        && other.value == value
        && other.index == index;
  }

  @override
  int get hashCode => Object.hash(value, index);

  @override
  String toString() {
    return '$value@$index';
  }

}

class _CodeChunkAnalyzePayload {

  final CodeChunkAnalyzer analyzer;
  final CodeLines codeLines;

  const _CodeChunkAnalyzePayload(this.analyzer, this.codeLines);

}

class _CodeChunkAnalyzeResult {

  final List<CodeChunk> chunks;
  final List<int> invalidCollapsedChunkIndexes;

  const _CodeChunkAnalyzeResult(this.chunks, this.invalidCollapsedChunkIndexes);

}