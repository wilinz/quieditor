part of re_editor;

class _CodeHighlighter extends ValueNotifier<List<_HighlightResult>> {

  final BuildContext _context;
  final _CodeParagraphProvider _provider;
  final _CodeHighlightEngine _engine;

  CodeLineEditingController _controller;
  CodeHighlightTheme? _theme;

  _CodeHighlighter({
    required BuildContext context,
    required CodeLineEditingController controller,
    CodeHighlightTheme? theme,
  }) : _context = context,
    _provider = _CodeParagraphProvider(),
    _controller = controller,
    _theme = theme,
    _engine = _CodeHighlightEngine(theme),
    super(const []) {
    // A language chosen for a theme naming several arrives a frame or more after
    // it was asked for, and the document has to be highlighted with it then.
    _engine.onHighlightAgain = _processHighlight;
    _controller.addListener(_onCodesChanged);
    _processHighlight();
  }

  set controller(CodeLineEditingController value) {
    if (_controller == value) {
      return;
    }
    _controller.removeListener(_onCodesChanged);
    _controller = value;
    _controller.addListener(_onCodesChanged);
    _processHighlight();
  }

  set theme(CodeHighlightTheme? value) {
    if (_theme == value) {
      return;
    }
    _theme = value;
    _engine.theme = value;
    _processHighlight();
  }

  /// Says which lines the editor is showing.
  ///
  /// Highlighting follows the window rather than the document: the visible lines
  /// are carried on from the ones above them, and the rest of the document is
  /// left until it is scrolled into view.
  void noteDrawn(int index) {
    _engine.noteDrawn(index);
  }

  IParagraph build({
    required int index,
    required TextStyle style,
    required double maxWidth,
    int? maxLengthSingleLineRendering,
  }) {
    // Every line the renderer draws comes through here, which is what makes this
    // the place that knows the window — the lines below what is being drawn are
    // not built at all.
    _engine.noteDrawn(index);
    _provider.updateBaseStyle(style);
    _provider.updateMaxLengthSingleLineRendering(maxLengthSingleLineRendering);
    return _provider.build(_controller.buildTextSpan(
      context: _context,
      index: index,
      textSpan: _buildSpan(index, style),
      style: style
    ), maxWidth);
  }

  void clearCache() {
    _provider.clearCache();
  }

  @override
  void dispose() {
    _controller.removeListener(_onCodesChanged);
    _engine.dispose();
    super.dispose();
  }

  TextSpan _buildSpan(int index, TextStyle style) {
    final String text = _controller.codeLines[index].text;
    if (index >= value.length) {
      return TextSpan(
        text: text,
        style: style
      );
    }
    final _HighlightResult result = value[index];
    if (result.nodes.isEmpty) {
      return TextSpan(
        text: text,
        style: style
      );
    }
    if (result.source == text) {
      return _buildSpanFromNodes(result.nodes, style);
    }
    // Diff the changes and reuse node to avoid style blink.
    final List<_HighlightNode> startNodes = [];
    int start = 0;
    int end = text.length;
    for (int i = 0; i < result.nodes.length && start < end; i++) {
      final String value = result.nodes[i].value;
      if (text.startsWith(value, start)) {
        startNodes.add(result.nodes[i]);
        start += value.length;
      } else {
        break;
      }
    }
    final List<_HighlightNode> endNodes = [];
    for (int i = result.nodes.length - 1; i >= 0 && start < end; i--) {
      final String value = result.nodes[i].value;
      if (text.substring(start, end).endsWith(value)) {
        endNodes.insert(0, result.nodes[i]);
        end -= value.length;
      } else {
        break;
      }
    }
    final _HighlightNode? midNode;
    if (startNodes.isEmpty) {
      midNode = _HighlightNode(text.substring(start, end), result.nodes[0].className);
    } else if (startNodes.length < result.nodes.length) {
      midNode = _HighlightNode(text.substring(start, end), result.nodes[startNodes.length].className);
    } else if (end > start){
      midNode = _HighlightNode(text.substring(start, end), result.nodes.last.className);
    } else {
      midNode = null;
    }
    return _buildSpanFromNodes([
      ...startNodes,
      if (midNode != null)
        midNode,
      ...endNodes
    ], style);
  }

  TextSpan _buildSpanFromNodes(List<_HighlightNode> nodes, TextStyle baseStyle) {
    return TextSpan(
      children: nodes.map((e) => TextSpan(
          text: e.value,
          style: _findStyle(e.className)
        )).toList(),
      style: baseStyle
    );
  }

  TextStyle? _findStyle(String? className) {
    if (className == null) {
      return null;
    }
    while(true) {
      final TextStyle? style = _theme?.theme[className];
      if (style != null) {
        return style;
      }
      final int pieceIndex = className!.indexOf('-');
      if (pieceIndex < 0) {
        break;
      }
      className = className.substring(pieceIndex + 1);
      if (className.isEmpty) {
        break;
      }
    }
    return null;
  }

  void _onCodesChanged() {
    if (_controller.preValue?.codeLines == _controller.codeLines) {
      return;
    }
    _processHighlight();
  }

  void _processHighlight() {
    _engine.run(_controller.codeLines, (result) => value = result);
  }

}

class _CodeHighlightEngine {

  /// The worker the whole-document highlight runs in.
  ///
  /// It is the core's work that runs there, not a second implementation: a
  /// document's worth of it is hundreds of milliseconds, which is a second of
  /// frozen editor if it happens where the frames are. The incremental
  /// highlighter below is the other half of the same idea — it is cheap enough
  /// to run here.
  late final _IsolateTasker<_HighlightPayload, _HighlightAnswer> _tasker;

  List<_GrammarSource> _native = const <_GrammarSource>[];
  CodeHighlightTheme? _theme;

  /// The native highlighter for the document being shown, when there is one.
  ///
  /// It lives here, on the isolate that draws, rather than in the worker the
  /// whole-document highlight runs in: a compiled grammar and the states between
  /// a document's lines belong to the isolate that made them and cannot be sent
  /// to another. What makes that acceptable is that a keystroke costs tens of
  /// lines through it — microseconds — where the whole-document path costs
  /// hundreds of milliseconds and belongs off this isolate.
  NativeHighlighter? _incremental;

  /// The lines the highlighter has seen, so an edit can be told from a
  /// different document, and the results for each line, so the ones an edit did
  /// not touch can be kept.
  List<String> _lines = const <String>[];
  List<_HighlightResult> _results = const <_HighlightResult>[];

  /// The lines `_results` covers: `0.._scannedTo` has been highlighted and the
  /// rest has not.
  ///
  /// One number rather than a line-by-line record, because a grammar's state
  /// carries from one line to the next: a scan can only ever start from the top
  /// and carry on, so what has been highlighted is always a prefix. The lines
  /// past it are drawn plain, which is what an index past the end of `_results`
  /// already means to the renderer.
  int _scannedTo = 0;

  /// The language chosen for a theme that names several, and the text the choice
  /// was read from.
  ///
  /// Kept rather than chosen again on every pass: a language carries its state
  /// from line to line, so a highlighter built for one cannot be handed another,
  /// and re-choosing mid-document would mean rebuilding from the top. The text
  /// is kept so that a document edited at its top — pasted over, most likely —
  /// is chosen for again.

  /// Whether a language is being chosen for a document too long to score whole.

  /// The language chosen for a theme that names several, and the text the choice
  /// was read from.
  ///
  /// Kept rather than chosen again on every pass: a language carries its state
  /// from line to line, so a highlighter built for one cannot be handed another,
  /// and re-choosing mid-document would mean rebuilding it from the top. The
  /// text is kept so that a document edited at its top — pasted over, most
  /// likely — is chosen for again.
  _GrammarSource? _pinnedLanguage;
  String? _pinnedSample;

  /// Whether a language is being chosen for a document too long to score whole.
  bool _choosingLanguage = false;

  /// Called when the document has to be highlighted again, without having been
  /// edited: a language was chosen for it a frame or more after it was asked
  /// for, or a highlighter was thrown away and another has to be opened.
  void Function()? onHighlightAgain;

  /// The lines the renderer has asked for since the last frame, which is the
  /// window: it builds the lines it is showing and no others.
  ///
  /// Read here rather than taken from the render object's
  /// `onRenderParagraphsChanged`, because that callback is skipped on exactly
  /// the layouts a scroll produces — it returns early when the first built line
  /// is already past the top of the viewport, which is the case as soon as the
  /// document is scrolled at all. Every line is built through `build` whatever
  /// else the layout does, so this cannot miss one.
  int? _drawnFirst;
  int? _drawnLast;

  /// What those came to on the last frame that drew anything: the window the
  /// editor is showing, one past its last line.
  int _viewportFrom = 0;
  int _viewportTo = 0;

  /// The lines the editor has been told about. Behind `_scannedTo` while the
  /// fill works below the window, which is what the next notification is
  /// measured against.
  int _publishedTo = 0;

  /// Where the results go when a scan happens outside a `run` — a scroll is not
  /// a change to the document, so it does not go through one.
  void Function(List<_HighlightResult>)? _publish;

  /// Whether a scan is already waiting on the next frame, so that the many
  /// layouts a fling produces ask for one rather than one each.
  bool _scanScheduled = false;

  _CodeHighlightEngine(final CodeHighlightTheme? theme) {
    this.theme = theme;
    _tasker = _IsolateTasker<_HighlightPayload, _HighlightAnswer>('CodeHighlightEngine', _run);
  }

  set theme(CodeHighlightTheme? value) {
    if (_theme == value) {
      return;
    }
    _theme = value;
    _incremental?.dispose();
    _incremental = null;
    _lines = const <String>[];
    _results = const <_HighlightResult>[];
    _scannedTo = 0;
    _publishedTo = 0;
    final Map<String, CodeHighlightThemeMode>? modes = _theme?.languages;
    _native = modes == null ? const <_GrammarSource>[] : _grammarSources(modes);
  }

  /// The theme's languages, in the form the Rust core reads them — empty when
  /// the core should not be asked to highlight with them.
  ///
  /// This has to happen now rather than at the first highlight: `re_highlight`
  /// compiles a language by rewriting it in place — following `ref`s, turning
  /// `match` into `begin` — and a language that has been through that can no
  /// longer be transcribed exactly. Setting the theme is the last moment the
  /// grammars are still the ones their authors wrote.
  ///
  /// Empty is the answer for every way this cannot be done: a theme carrying
  /// plugins, which are Dart code the core cannot run, a language that cannot be
  /// transcribed, or one whose sub-language cannot be — which would show up as a
  /// difference in colour between two documents rather than as an error.
  List<_GrammarSource> _grammarSources(Map<String, CodeHighlightThemeMode> modes) {
    // A plugin is Dart code that runs around the highlight: one can rewrite the
    // text before it and rewrite the tree after it, and there is no way to hand
    // that across the boundary. Highlighting natively would quietly drop it,
    // which for a plugin that rewrites the code means colouring text the editor
    // is not showing.
    if (_theme!.plugins.isNotEmpty) {
      return const <_GrammarSource>[];
    }

    // With one language there is nothing to choose and nothing to decide: the
    // theme has already said which it is. With several, the choice is
    // `highlightAuto`'s, and a language that has asked not to be auto-detected
    // is not part of it — the Dart side would not consider it either.
    final Iterable<MapEntry<String, CodeHighlightThemeMode>> chosen =
        modes.length == 1
            ? modes.entries
            : modes.entries.where((entry) => entry.value.mode.disableAutodetect != true);

    final List<_GrammarSource> sources = <_GrammarSource>[];
    for (final MapEntry<String, CodeHighlightThemeMode> entry in chosen) {
      final _GrammarSource? source = _grammarSource(entry.key, entry.value, modes);
      if (source == null) {
        // One language the core cannot take means none of them: choosing
        // between scores from two implementations would be comparing two
        // scales, and the Dart side is the one that can answer for all of them.
        return const <_GrammarSource>[];
      }
      sources.add(source);
    }
    // Scoring cannot choose between fewer than two.
    if (modes.length > 1 && sources.length < 2) {
      return const <_GrammarSource>[];
    }
    return sources;
  }

  /// One language, transcribed, or `null` when it cannot be.
  _GrammarSource? _grammarSource(
    String name,
    CodeHighlightThemeMode mode,
    Map<String, CodeHighlightThemeMode> modes,
  ) {
    final Map<String, dynamic>? json = nativeGrammarJson(mode.mode);
    if (json == null) {
      return null;
    }
    final Map<String, String> subLanguages = <String, String>{};
    for (final String sub in nativeGrammarSubLanguages(json)) {
      final CodeHighlightThemeMode? definition = modes[sub];
      if (definition == null) {
        // Not registered here either, so the Dart side would leave its text
        // plain too. The two agree by both doing nothing.
        continue;
      }
      final Map<String, dynamic>? subJson = nativeGrammarJson(definition.mode);
      if (subJson == null) {
        return null;
      }
      subLanguages[sub] = jsonEncode(subJson);
    }
    return _GrammarSource(
      name: name,
      json: jsonEncode(json),
      subLanguages: subLanguages,
      supersetOf: mode.mode.supersetOf,
    );
  }

  void dispose() {
    _incremental?.dispose();
    _incremental = null;
    _tasker.close();
  }

  void run(CodeLines codes, IsolateCallback<List<_HighlightResult>> callback) {
    // Kept because a scroll highlights without a change to the document, so
    // there is no `run` to deliver its results from.
    _publish = callback;
    final Map<String, CodeHighlightThemeMode>? modes = _theme?.languages;
    // No languages, or none the core can take: the document is drawn plain.
    // This is what the web build does, and what a theme the core cannot read
    // does — there is no second implementation here to hand the work to.
    if (modes == null || modes.isEmpty || _native.isEmpty) {
      callback(const []);
      return;
    }

    // The incremental highlighter first, which is the one that can answer
    // without the whole document being walked: an edit costs the lines it
    // touched, and the lines it did not are kept from the last answer.
    final List<_HighlightResult>? incremental = _runIncrementally(modes, codes);
    if (incremental != null) {
      // Delivered out of the frame rather than in it: one of the callers sets a
      // notifier while the widget tree is being built, where a change during the
      // build is an error.
      //
      // Read from the field when it is delivered rather than taken here, because
      // a frame highlights what it is showing after its own post-frame callbacks
      // and this runs before them: by the time this arrives the answer has grown,
      // and handing over the list as it was would put the shorter one back.
      scheduleMicrotask(() => callback(_results));
      return;
    }

    if (_choosingLanguage) {
      // A language is being chosen for a document too long to score whole. The
      // answer is a frame or more away and there is nothing to draw with until
      // it arrives; sending the document to the worker in the meantime would be
      // the whole-document pass this is here to avoid.
      callback(const <_HighlightResult>[]);
      return;
    }
    _tasker.run(_HighlightPayload(
      codes: codes,
      maxSizes: modes.values.map((e) => e.maxSize).toList(),
      maxLineLengths: modes.values.map((e) => e.maxLineLength).toList(),
      native: _native,
    ), (_HighlightAnswer answer) => callback(answer.results ?? const <_HighlightResult>[]));
  }

  /// Highlights [codes] with the native highlighter for this document, or
  /// returns `null` when there is none or no update was needed.
  ///
  /// The first call for a document builds the highlighter, which costs one
  /// whole-document highlight on this isolate — the same work the worker would
  /// do, and bounded by the theme's size limits, which is what stops a document
  /// too large to hold up a frame from ever reaching here. Every call after it
  /// costs the lines the edit touched.
  List<_HighlightResult>? _runIncrementally(
    Map<String, CodeHighlightThemeMode> modes,
    CodeLines codes,
  ) {
    final List<String> lines =
        List<String>.generate(codes.length, (index) => codes[index].text);
    if (!_withinLimits(modes, lines)) {
      return null;
    }
    final _GrammarSource? source = _sourceFor(lines);
    if (source == null) {
      return null;
    }

    NativeHighlighter? highlighter = _incremental;
    if (highlighter == null) {
      highlighter = ReEditorNative.openHighlighter(
        source.json,
        subLanguages: source.subLanguages,
        text: lines.join('\n'),
      );
      if (highlighter == null) {
        return null;
      }
      _incremental = highlighter;
      _lines = lines;
      _results = const <_HighlightResult>[];
      _scannedTo = 0;
      // The top of the document, so a file opened at its start is coloured on
      // the frame it appears. Everything below waits until the editor says it is
      // showing it — which is the difference between opening a large file and
      // highlighting all of it first.
      _scanTo(_initialScanLines);
      // Handed straight back, so these lines count as told about.
      _publishedTo = _scannedTo;
      return _results;
    }

    final LineChange change = lineChange(_lines, lines);
    if (change.removed == 0 && change.added.isEmpty) {
      return _results;
    }
    final NativeHighlightUpdate update;
    try {
      update = highlighter.splice(
        start: change.start,
        removed: change.removed,
        added: change.added,
      );
    } on Object catch (error) {
      // The core refused the edit, which means its idea of the document and this
      // one have parted. Answering "nothing changed" would leave the lines that
      // did change coloured as they were, so the highlighter is dropped and the
      // worker — which highlights a document from scratch — is left to answer
      // the pass after this one.
      assert(() {
        throw StateError('re_editor: the native highlighter refused an edit: $error');
      }());
      _restartIncremental();
      return null;
    }
    // The spans of the lines that changed, rendered the way every other line
    // was — the native side speaks in lines and offsets, and the editor draws in
    // classes, so the same renderer the Dart path uses does the conversion.
    final List<_HighlightResult> replaced =
        _renderSpans(lines, update.nodes, update.from, update.to);
    _results = spliceByLine(_results, update, replaced);
    _scannedTo = _results.length;
    assert(
      _scannedTo == update.scannedTo,
      'the cache came out $_scannedTo long and the core said '
      '${update.scannedTo}',
    );
    _publishedTo = _scannedTo;
    _lines = lines;
    return _results;
  }

  /// Which language to highlight [lines] with, or nothing when this path cannot
  /// answer for them.
  ///
  /// A theme naming one language has answered before it gets here. One naming
  /// several leaves the choice to `highlightAuto`, which scores every language
  /// over the whole document — the right answer on the documents this path has
  /// always served, and the reason a large one is different: there, the choice
  /// is read from the top of the document, once, and kept.

  /// Which language to highlight [lines] with, or nothing when this path cannot
  /// answer for them.
  ///
  /// A theme naming one language has answered before it gets here. One naming
  /// several leaves the choice to `highlightAuto`, which scores every language
  /// over the whole document — the right answer on the documents this path has
  /// always served, and the reason a long one is different: there, the choice is
  /// read from the top of the document, once, and kept.
  _GrammarSource? _sourceFor(List<String> lines) {
    if (_native.length == 1) {
      return _native.first;
    }
    if (_native.length < 2) {
      return null;
    }
    if (!_worthSampling(lines)) {
      // Short enough that scoring every language over all of it costs what
      // scoring a sample would: anything less than the whole text is a worse
      // answer for no saving at all.
      return null;
    }
    final String sample = _sampleOf(lines);
    if (_pinnedLanguage != null && _pinnedSample == sample) {
      return _pinnedLanguage;
    }
    _askForLanguage(sample);
    return null;
  }

  /// Whether [lines] are long enough that choosing a language from the top of
  /// them is worth more than reading all of them.
  bool _worthSampling(List<String> lines) {
    if (lines.length > _languageSampleLines) {
      return true;
    }
    int total = 0;
    for (final String line in lines) {
      total += line.length;
      if (total > _languageSampleChars) {
        return true;
      }
    }
    return false;
  }

  /// The top of [lines], cut where a line ends, for choosing a language from.
  String _sampleOf(List<String> lines) {
    final String sample = lines.take(_languageSampleLines).join('\n');
    if (sample.length <= _languageSampleChars) {
      return sample;
    }
    final int cut = sample.lastIndexOf('\n', _languageSampleChars);
    return cut <= 0
        ? sample.substring(0, _languageSampleChars)
        : sample.substring(0, cut);
  }

  /// Asks the worker which language [sample] is written in.
  void _askForLanguage(String sample) {
    if (_choosingLanguage) {
      return;
    }
    _choosingLanguage = true;
    _tasker.run(
      _HighlightPayload.choose(sample: sample, native: _native),
      (_HighlightAnswer answer) {
        _choosingLanguage = false;
        final String? name = answer.language;
        if (name == null) {
          return;
        }
        final int index =
            _native.indexWhere((_GrammarSource source) => source.name == name);
        if (index < 0) {
          return;
        }
        _pinnedLanguage = _native[index];
        _pinnedSample = sample;
        onHighlightAgain?.call();
      },
    );
  }

  /// The most of a document to read when choosing its language, in characters
  /// and in lines.
  static const int _languageSampleChars = 4000;
  static const int _languageSampleLines = 200;

  /// How many lines of a document to highlight before its first frame.
  ///
  /// Opening at the top is what almost every document does, and this is enough
  /// lines to fill a tall window. What it costs is a fraction of a millisecond.
  static const int _initialScanLines = 64;

  /// How far past the visible lines to highlight, so that scrolling a few lines
  /// does not immediately ask for more.
  static const int _viewportMarginLines = 200;

  /// How many lines one scan of a jump adds before the time is checked again.
  ///
  /// A jump — to the end of a document, to a line number — cannot be answered
  /// without walking everything above it, because a grammar's state runs from
  /// line to line. Walking it in one go is what the budget below bounds. This is
  /// the unit it is measured in, and it has to be small enough that one step
  /// fits in a frame on its own: measured over a Dart source, a scan costs about
  /// 11 µs a line, so this is roughly 6 ms.
  static const int _catchUpChunkLines = 512;

  /// How long a jump may hold the frame it is walking on.
  ///
  /// A time rather than a line count because the same number of lines costs
  /// different amounts in different grammars, and the one that matters is the
  /// one the document is written in. What it buys is the window arriving sooner:
  /// the alternative is a longer frame that highlights more of a document nobody
  /// is looking at yet.
  static const int _jumpBudgetMicroseconds = 4000;

  /// How many lines the fill adds before the time is checked again. See
  /// [_catchUpChunkLines] for where the number comes from.
  static const int _fillChunkLines = 256;

  /// How long a frame may spend on lines nobody has asked for.
  ///
  /// Small, and smaller than a jump's share, because nothing waits on it: the
  /// window was served first, and these lines are only here so that scrolling
  /// into them shows colours rather than plain text.
  static const int _fillBudgetMicroseconds = 2000;

  /// Notes that line [index] is being drawn, and arranges to highlight what the
  /// editor is showing.
  ///
  /// Called for every line the renderer builds, which is the visible ones. What
  /// is drawn is what is paid for, and the rest of the document is left until it
  /// is scrolled into view.
  void noteDrawn(int index) {
    if (_drawnFirst == null || index < _drawnFirst!) {
      _drawnFirst = index;
    }
    if (_drawnLast == null || index > _drawnLast!) {
      _drawnLast = index;
    }
    _scheduleScan();
  }

  /// Highlights what the editor is showing, and then the rest of the document,
  /// once the frame that reported it is over.
  ///
  /// Deferred because this is called from the middle of a layout, and a scan
  /// ends by publishing results — which is a notification, and one of the
  /// callers sets a notifier while the tree is being built, where a change
  /// during the build is an error. Deferring also collapses the many layouts a
  /// fling produces into one request for where it ended up.
  void _scheduleScan() {
    if (_scanScheduled || _incremental == null) {
      return;
    }
    _scanScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scanScheduled = false;
      // Read once, here: a frame can build lines in more than one layout pass,
      // and this is the range they came to. Cleared so that a frame which draws
      // nothing does not ask again for the last range — a run that is still
      // filling the document carries on with the window it already has.
      final int? first = _drawnFirst;
      final int? last = _drawnLast;
      _drawnFirst = null;
      _drawnLast = null;
      if (_incremental == null) {
        return;
      }
      if (first != null && last != null) {
        _viewportFrom = first;
        _viewportTo = last + 1;
      }
      final Stopwatch clock = Stopwatch()..start();
      // The window first, because that is what someone is looking at. A short
      // gap is closed in one go — one step of the walk, and one slow frame is
      // better than a screenful of plain text — and a long one, a jump, is
      // walked a step at a time until this frame's share is spent.
      final int wanted = _wantedScanLine;
      final bool allAtOnce = _viewportFrom - _scannedTo <= _catchUpChunkLines;
      while (_scannedTo < wanted) {
        if (_scanTo(_scannedTo + _catchUpChunkLines) == null) {
          break;
        }
        if (allAtOnce || clock.elapsedMicroseconds >= _jumpBudgetMicroseconds) {
          break;
        }
      }
      // Then the rest of it, on whatever the frame has left: nobody is waiting
      // for those lines, and having them there is what makes scrolling into them
      // show colours rather than plain text.
      while (_scannedTo < _lines.length &&
          clock.elapsedMicroseconds < _fillBudgetMicroseconds) {
        if (_scanTo(_scannedTo + _fillChunkLines) == null) {
          break;
        }
      }
      // Only tell the editor when the lines just added are ones it is drawing.
      // A notification makes the render object lay out again and rebuild the
      // paragraphs on screen, and the fill spends most of its time below the
      // window, where that would be work for nothing.
      if (_scannedTo > _publishedTo) {
        final bool onScreen =
            _scannedTo > _viewportFrom && _publishedTo < _viewportTo;
        _publishedTo = _scannedTo;
        if (onScreen) {
          _publish?.call(_results);
        }
      }
      if (_scannedTo < _lines.length) {
        // A post-frame callback does not ask for a frame, so the next piece of
        // the fill would wait for whatever the editor happened to draw next —
        // which, on a document nobody is touching, may be nothing.
        SchedulerBinding.instance.scheduleFrame();
        _scheduleScan();
      }
    });
  }

  /// The line the editor needs covered: the end of what it is showing, plus the
  /// margin that keeps a small scroll from asking again.
  int get _wantedScanLine =>
      min(_viewportTo + _viewportMarginLines, _lines.length);

  /// Highlights everything up to [to], and answers with the lines that added —
  /// nothing when there was nothing to add.
  ///
  /// The core may stop short of [to] or run past it, so the answer's own range
  /// is what it added and what the cache now reaches.
  NativeHighlightChunk? _scanTo(int to) {
    final NativeHighlighter? highlighter = _incremental;
    if (highlighter == null || to <= _scannedTo) {
      return null;
    }
    final NativeHighlightChunk chunk;
    try {
      chunk = highlighter.scan(to);
    } on Object catch (error) {
      // As above: the two have parted, and this runs out of a post-frame
      // callback, where throwing reaches the framework's error handler rather
      // than anything that could carry on with the document.
      assert(() {
        throw StateError('re_editor: the native highlighter refused a scan: $error');
      }());
      _restartIncremental();
      onHighlightAgain?.call();
      return null;
    }
    if (chunk.from != _scannedTo) {
      // The core is further along than this cache. The two only lose step
      // through a bug, and carrying on would draw the wrong colours from here
      // down, so start again from nothing.
      assert(
        false,
        'the highlighter covered ${chunk.from} lines and this has $_scannedTo',
      );
      _restartIncremental();
      return null;
    }
    if (chunk.to <= chunk.from) {
      return null;
    }
    _results = <_HighlightResult>[
      ..._results,
      ..._renderSpans(_lines, chunk.nodes, chunk.from, chunk.to),
    ];
    _scannedTo = _results.length;
    assert(_scannedTo == chunk.to);
    return chunk;
  }

  /// Throws the highlighter away and opens another, leaving the document to be
  /// highlighted again from its top.
  void _restartIncremental() {
    _incremental?.dispose();
    _incremental = null;
    _results = const <_HighlightResult>[];
    _scannedTo = 0;
    _publishedTo = 0;
  }

  /// Whether the document is small enough that the theme wants it highlighted.
  ///
  /// The same limits the whole-document path applies, for the same reason: they
  /// are how a caller says that a document this large is not worth colouring.
  static bool _withinLimits(
    Map<String, CodeHighlightThemeMode> modes,
    List<String> lines,
  ) {
    final int maxSize = modes.values.map((mode) => mode.maxSize).reduce(min);
    final int maxLineLength =
        modes.values.map((mode) => mode.maxLineLength).reduce(min);
    int total = 0;
    for (final String line in lines) {
      if (line.length > maxLineLength || total > maxSize) {
        return false;
      }
      total += line.length;
    }
    return true;
  }

  /// The per-line results for `nodes`, which cover the lines `from..to` of
  /// [lines].
  ///
  /// The spans arrive in document lines and offsets, so the text of the range is
  /// what the renderer walks: it is the same renderer the whole-document path
  /// uses, which is what keeps a line highlighted by an edit identical to the
  /// same line highlighted from scratch.
  static List<_HighlightResult> _renderSpans(
    List<String> lines,
    List<NativeHighlightNode> nodes,
    int from,
    int to,
  ) {
    final String code = lines.sublist(from, to).join('\n');
    // Overlap rather than containment, and every offset clamped into the range.
    // A node that starts before the range but runs into it — a comment or a
    // string spanning the boundary — still colours the part of it that is here.
    // Today none do: the core re-opens the enclosing scopes at the first byte of
    // the piece it hands back, so every node already starts inside it. But a
    // node that escaped that would subtract its way to a negative line, and
    // `_offset` clamps negative lines to the end of the text — a frame of
    // visibly wrong colour rather than an error saying what went wrong.
    final List<NativeHighlightNode> within = nodes
        .where((node) => node.endLine >= from && node.startLine < to)
        .map((node) => NativeHighlightNode(
              scope: node.scope,
              startLine: (node.startLine < from ? from : node.startLine) - from,
              startOffset: node.startLine < from ? 0 : node.startOffset,
              endLine: (node.endLine > to - 1 ? to - 1 : node.endLine) - from,
              endOffset: node.endLine > to - 1 ? lines[to - 1].length : node.endOffset,
              depth: node.depth,
            ))
        .toList();
    final _HighlightLineRenderer renderer = _HighlightLineRenderer();
    replayHighlightSpans(code: code, nodes: within, renderer: renderer);
    return renderer.lineResults;
  }

  @pragma('vm:entry-point')
  static _HighlightAnswer _run(_HighlightPayload payload) {
    final CodeLines? codes = payload.codes;
    if (codes == null) {
      return _HighlightAnswer.chosen(
        _chooseNatively(payload.native, payload.sample!),
      );
    }
    final CodeLines codeLines = codes;
    final int maxSize = payload.maxSizes.reduce(min);
    final int maxLineLength = payload.maxLineLengths.reduce(min);
    // Evalaute performance
    bool canHighlight = true;
    int total = 0;
    for (int i = 0; i < codeLines.length; i++) {
      final int length = codeLines[i].length;
      if (length > maxLineLength || total > maxSize) {
        canHighlight = false;
        break;
      }
      total += length;
    }
    // Too large for the theme to want highlighted, or the core would not answer:
    // the document is drawn plain. There is no other implementation here to
    // hand the work to — one that wants the Dart highlighter has `re_highlight`
    // itself.
    if (!canHighlight) {
      return const _HighlightAnswer.rendered(<_HighlightResult>[]);
    }
    final String code = codeLines.asString(TextLineBreak.lf, false);
    return _HighlightAnswer.rendered(
      _runNatively(payload.native, code) ?? const <_HighlightResult>[],
    );
  }

  /// Which language a document is written in, read from the top of it.
  ///
  /// `highlightAuto` scores every language over the whole document, which is the
  /// text read once per language — the right answer on the documents this path
  /// has always served, and the reason a long one asks a different question.
  /// What arrives here is a sample: the top of the document, which is the part a
  /// viewport-first highlighter has by the time it needs an answer.
  ///
  /// The rule that settles a tie is unchanged and still `bestLanguage`'s; what
  /// changes is the text the scores are read off.
  static String? _chooseNatively(List<_GrammarSource> sources, String code) {
    final List<NativeHighlightCandidate> candidates = <NativeHighlightCandidate>[];
    for (final _GrammarSource source in sources) {
      final NativeHighlightResult? result = _score(source, code);
      if (result == null) {
        // One language the core would not answer for means none of them, the
        // same as it does when every language is scored over everything.
        return null;
      }
      candidates.add(NativeHighlightCandidate(
        name: source.name,
        relevance: result.relevance,
        supersetOf: source.supersetOf,
      ));
    }
    return bestLanguage(candidates);
  }


  /// Highlights [code] with the Rust core, or returns `null` when there is no
  /// grammar for it here or the core would not answer.
  ///
  /// This runs in the worker rather than on the thread that draws, and it has to:
  /// measured over the package's own sources at 181,000 lines, the core takes
  /// 907 ms against the Dart implementation's 54,000 — sixty times faster, and
  /// still a second of a document, which is a second of frozen editor if it
  /// happens where the frames are.
  ///
  /// The grammar is compiled here rather than brought in compiled, because a
  /// handle belongs to the isolate that made it. It is compiled once: the worker
  /// outlives the call, and the grammar is the one thing a keystroke does not
  /// change.
  ///
  /// What comes back is fed through the same renderer the Dart path uses, which
  /// is what keeps the two drawing the same thing — it decides how a scope
  /// becomes a class name and how a span crossing a line break becomes a node on
  /// each line.
  static List<_HighlightResult>? _runNatively(List<_GrammarSource> sources, String code) {
    if (sources.isEmpty) {
      return null;
    }
    if (sources.length == 1) {
      final NativeHighlightResult? result = _score(sources.first, code);
      return result == null ? null : _render(code, result.nodes);
    }

    // A theme naming several languages: highlight each and keep the one that
    // found the most. This is `highlightAuto`, and the choosing is the editor's
    // — the scores are the core's, and the rule that settles them is
    // `bestLanguage`.
    final List<NativeHighlightResult> results = <NativeHighlightResult>[];
    for (final _GrammarSource source in sources) {
      final NativeHighlightResult? result = _score(source, code);
      if (result == null) {
        // One language the core would not answer for means none of them: a
        // choice between what it could score and what it could not is not the
        // choice the Dart side would make.
        return null;
      }
      results.add(result);
    }
    final List<NativeHighlightCandidate> candidates = <NativeHighlightCandidate>[
      for (int i = 0; i < sources.length; i++)
        NativeHighlightCandidate(
          name: sources[i].name,
          relevance: results[i].relevance,
          supersetOf: sources[i].supersetOf,
        ),
    ];
    final String? best = bestLanguage(candidates);
    final int chosen = sources.indexWhere((source) => source.name == best);
    if (chosen < 0) {
      return null;
    }
    return _render(code, results[chosen].nodes);
  }

  /// What one grammar made of [code], or `null` when it would not answer.
  static NativeHighlightResult? _score(_GrammarSource source, String code) {
    final NativeGrammar? grammar = _compiledGrammar(source);
    if (grammar == null) {
      return null;
    }
    try {
      return grammar.highlight(code);
    } catch (_) {
      // The core could not answer, or found the code is not this language's at
      // all. Either way the Dart implementation is what the editor falls back
      // to, and it still works.
      return null;
    }
  }

  /// The per-line results for [nodes], through the renderer the Dart path uses.
  static List<_HighlightResult> _render(String code, List<NativeHighlightNode> nodes) {
    final _HighlightLineRenderer renderer = _HighlightLineRenderer();
    replayHighlightSpans(code: code, nodes: nodes, renderer: renderer);
    return renderer.lineResults;
  }



}

/// The grammars this worker has compiled, by the JSON they were compiled from.
///
/// Module-level rather than on the engine because the engine lives on the
/// isolate that asked for the work, and the grammars live here. Compiling is a
/// few milliseconds — eight, measured on the Dart grammar — but it is the one
/// step a keystroke cannot change, so it is not repeated per keystroke. A theme
/// naming several languages needs several, which is why this is a map.
final Map<String, NativeGrammar?> _compiledGrammars = <String, NativeGrammar?>{};

/// The compiled grammar for [source], compiling it the first time.
NativeGrammar? _compiledGrammar(_GrammarSource source) => _compiledGrammars.putIfAbsent(
      source.json,
      () => ReEditorNative.compileGrammar(source.json, subLanguages: source.subLanguages),
    );

/// A grammar in the form the Rust core reads it in.
///
/// Transcribed on the isolate that owns the language, because a language that
/// `re_highlight` has compiled can no longer be transcribed exactly, and
/// compiled where the handle has to live.
class _GrammarSource {
  const _GrammarSource({
    required this.name,
    required this.json,
    required this.subLanguages,
    required this.supersetOf,
  });

  /// What the theme calls it, which is what the chosen language is reported as.
  final String name;

  final String json;
  final Map<String, String> subLanguages;

  /// The language this one says it is a superset of, if it says so — which is
  /// what settles a tie between two that scored the same.
  final String? supersetOf;
}

/// What the worker answered.
///
/// A job either highlights the document or says which language to highlight it
/// with. The second is what a document too long to score whole asks for before
/// it is drawn, and it carries a name rather than a document — not sending the
/// document is the whole point of it.
class _HighlightAnswer {

  const _HighlightAnswer.rendered(this.results) : language = null;

  const _HighlightAnswer.chosen(this.language) : results = null;

  /// The highlighted lines, or nothing when the job was to choose.
  final List<_HighlightResult>? results;

  /// The language to highlight with, or nothing when the job was to render.
  final String? language;

}

class _HighlightPayload {

  /// The document to highlight, or nothing when the job is to choose the
  /// language for it — and then only [sample] crosses.
  final CodeLines? codes;

  /// The top of the document, for choosing a language with.
  final String? sample;

  final List<int> maxSizes;
  final List<int> maxLineLengths;

  /// The grammars to highlight with — one for a theme naming one language,
  /// several for a theme that leaves the choice to `highlightAuto`. Transcribed
  /// by the engine before the languages could be compiled; compiled here, where
  /// the work happens.
  final List<_GrammarSource> native;

  const _HighlightPayload({
    required CodeLines this.codes,
    required this.maxSizes,
    required this.maxLineLengths,
    required this.native,
  }) : sample = null;

  const _HighlightPayload.choose({
    required String this.sample,
    required this.native,
  })  : codes = null,
        maxSizes = const <int>[],
        maxLineLengths = const <int>[];

}

class _HighlightResult {
  final List<_HighlightNode> nodes;

  _HighlightResult(this.nodes);

  String get source => nodes.map((e) => e.value).join();
}

class _HighlightNode {

  final String? className;
  final String value;

  const _HighlightNode(this.value, [this.className]);
}

class _HighlightLineRenderer implements HighlightRenderer {

  final List<_HighlightResult> lineResults;
  final List<String?> classNames;
  _HighlightLineRenderer(): lineResults = [
    _HighlightResult([])
  ], classNames = [];

  @override
  void addText(String text) {
    final String? className = classNames.isEmpty ? null : classNames.last;
    final List<String> lines = text.split(TextLineBreak.lf.value);
    lineResults.last.nodes.add(_HighlightNode(lines.first, className));
    if (lines.length > 1) {
      for (int i = 1; i < lines.length; i++) {
        lineResults.add(_HighlightResult([_HighlightNode(lines[i], className)]));
      }
    }
  }

  @override
  void openNode(DataNode node) {
    final String? className = classNames.isEmpty ? null : classNames.last;
    String? newClassName;
    if (className == null || node.scope == null) {
      newClassName = node.scope;
    } else {
      newClassName = '$className-${node.scope!}';
    }
    newClassName = newClassName?.split('.')[0];
    classNames.add(newClassName);
  }


  @override
  void closeNode(DataNode node) {
    if (classNames.isNotEmpty) {
      classNames.removeLast();
    }
  }

}

