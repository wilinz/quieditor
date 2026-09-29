part of re_editor;

class _CodeFindControllerImpl extends ValueNotifier<CodeFindValue?> implements CodeFindController {

  late final CodeLineEditingController _controller;
  late final TextEditingController _findInputController;
  late final FocusNode _findInputFocusNode;
  late final TextEditingController _replaceInputController;
  late final FocusNode _replaceInputFocusNode;
  late bool _shouldNotUpdateResults;
  late bool _replacingMatch;

  _CodeFindControllerImpl(CodeLineEditingController controller, [CodeFindValue? value]) : super(value) {
    _controller = controller is _CodeLineEditingControllerDelegate ? controller.delegate : controller;
    _controller.addListener(_updateResult);
    _findInputController = TextEditingController();
    _findInputController.addListener(_onFindPatternChanged);
    _findInputFocusNode = FocusNode();
    _replaceInputController = TextEditingController();
    _replaceInputFocusNode = FocusNode();
    _shouldNotUpdateResults = false;
    _replacingMatch = false;
    _updateResult();
  }

  @override
  void dispose() {
    super.dispose();
    _controller.removeListener(_updateResult);
    _findInputController.removeListener(_onFindPatternChanged);
    _findInputController.dispose();
    _findInputFocusNode.dispose();
    _replaceInputController.dispose();
    _replaceInputFocusNode.dispose();
  }

  @override
  TextEditingController get findInputController => _findInputController;

  @override
  TextEditingController get replaceInputController => _replaceInputController;

  @override
  FocusNode get findInputFocusNode => _findInputFocusNode;

  @override
  FocusNode get replaceInputFocusNode => _replaceInputFocusNode;

  @override
  List<CodeLineSelection>? get allMatchSelections {
    final List<CodeLineSelection>? matches = value?.result?.matches;
    if (matches == null) {
      return null;
    }
    if (value!.result!.dirty) {
      return null;
    }
    final List<CodeLineSelection> selections = [];
    for (final CodeLineSelection match in matches) {
      final CodeLineSelection? selection = convertMatchToSelection(match);
      if (selection == null) {
        continue;
      }
      selections.add(selection);
    }
    return selections;
  }

  @override
  CodeLineSelection? get currentMatchSelection {
    final CodeLineSelection? currentMatch = value?.result?.currentMatch;
    if (currentMatch == null) {
      return null;
    }
    if (value!.result!.dirty) {
      return null;
    }
    return convertMatchToSelection(currentMatch);
  }

  @override
  void findMode() {
    _findInputFocusNode.requestFocus();
    final String? autoFilled = _autoFilledPattern();
    _findInputController.removeListener(_onFindPatternChanged);
    if (autoFilled != null) {
      _findInputController.value = TextEditingValue(
        text: autoFilled,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: autoFilled.length
        )
      );
    } else {
      _findInputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findInputController.text.length
      );
    }
    _findInputController.addListener(_onFindPatternChanged);
    final CodeFindValue preValue = value ?? const CodeFindValue.empty();
    value = preValue.copyWith(
      option: preValue.option.copyWith(
        pattern: _findInputController.text
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void replaceMode() {
    _replaceInputFocusNode.requestFocus();
    final String? autoFilled = _autoFilledPattern();
    _findInputController.removeListener(_onFindPatternChanged);
    if (autoFilled != null) {
      _findInputController.value = TextEditingValue(
        text: autoFilled,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: autoFilled.length
        )
      );
    } else {
      _findInputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findInputController.text.length
      );
    }
    _findInputController.addListener(_onFindPatternChanged);
    final CodeFindValue preValue = value ?? const CodeFindValue.empty();
    value = preValue.copyWith(
      option: preValue.option.copyWith(
        pattern: _findInputController.text,
      ),
      replaceMode: true,
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void focusOnFindInput() {
    _findInputFocusNode.requestFocus();
    _findInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _findInputController.text.length
    );
  }

  @override
  void focusOnReplaceInput() {
    _replaceInputFocusNode.requestFocus();
    _replaceInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _replaceInputController.text.length
    );
  }

  @override
  void toggleMode() {
    final CodeFindValue? preValue = value;
    if (preValue == null) {
      return;
    }
    value = preValue.copyWith(
      replaceMode: !preValue.replaceMode,
      result: preValue.result
    );
  }

  @override
  void close() {
    value = null;
  }

  @override
  void toggleRegex() {
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return;
    }
    value = value?.copyWith(
      option: option.copyWith(
        regex: !option.regex,
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void toggleCaseSensitive() {
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return;
    }
    value = value?.copyWith(
      option: option.copyWith(
        caseSensitive: !option.caseSensitive,
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void previousMatch() {
    final CodeFindResult? result = value?.result;
    if (result == null || result.dirty) {
      return;
    }
    final CodeFindValue newValue = value!.copyWith(
      result: result.previous
    );
    _expandChunkIfNeeded(newValue);
    value = newValue;
    if (result.matches.length == 1) {
      final CodeLineSelection? selection = currentMatchSelection;
      if (selection != null) {
        _controller.makePositionCenterIfInvisible(selection.start);
      }
    }
  }

  @override
  void nextMatch() {
    final CodeFindResult? result = value?.result;
    if (result == null || result.dirty) {
      return;
    }
    final CodeFindValue newValue = value!.copyWith(
      result: result.next
    );
    _expandChunkIfNeeded(newValue);
    value = newValue;
    if (result.matches.length == 1) {
      final CodeLineSelection? selection = currentMatchSelection;
      if (selection != null) {
        _controller.makePositionCenterIfInvisible(selection.start);
      }
    }
  }

  @override
  void replaceMatch() {
    final CodeFindResult? result = value?.result;
    if (result == null || result.dirty) {
      return;
    }
    if (currentMatchSelection == null) {
      _expandChunkIfNeeded(value!);
    }
    final CodeLineSelection? selection = currentMatchSelection;
    if (selection == null) {
      return;
    }
    _replacingMatch = true;
    final CodeLines preCodeLines = _controller.codeLines;
    _controller.replaceSelection(_replaceInputController.text, selection);
    final CodeFindValue newValue = value!.copyWith(
      result: result.next.copyWith(
        dirty: !preCodeLines.equals(_controller.codeLines)
      )
    );
    _expandChunkIfNeeded(newValue);
    value = newValue;
    _replacingMatch = false;
  }

  @override
  void replaceAllMatches() {
    final CodeFindResult? result = value?.result;
    if (result == null || result.matches.isEmpty || result.dirty) {
      return;
    }
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return;
    }
    final RegExp? regExp = option.regExp;
    if (regExp == null) {
      return;
    }
    _replacingMatch = true;
    final CodeLines preCodeLine = _controller.codeLines;
    _controller.replaceAll(regExp, _replaceInputController.text);
    value = value?.copyWith(
      result: result.copyWith(
        dirty: !preCodeLine.equals(_controller.codeLines)
      )
    );
    _replacingMatch = false;
  }

  @override
  CodeLineSelection? convertMatchToSelection(CodeLineSelection match) {
    final CodeLineIndex baseIndex = _controller.lineIndex2Index(match.baseIndex);
    if (baseIndex.chunkIndex >= 0) {
      // This match is in a collapsed chunk, invisble
      return null;
    }
    final CodeLineIndex extentIndex;
    if (match.isSameLine) {
      extentIndex = baseIndex;
    } else {
      extentIndex = _controller.lineIndex2Index(match.extentIndex);
    }
    if (extentIndex.chunkIndex >= 0) {
      // This match is in a collapsed chunk, invisble
      return null;
    }
    return match.copyWith(
      baseIndex: baseIndex.index,
      extentIndex: extentIndex.index
    );
  }

  void _onFindPatternChanged() {
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return;
    }
    if (_findInputController.text == option.pattern) {
      return;
    }
    value = value?.copyWith(
      option: option.copyWith(
        pattern: _findInputController.text,
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  String? _autoFilledPattern() {
    final CodeLineSelection selection = _controller.selection;
    if (selection.isCollapsed || !selection.isSameLine) {
      return null;
    }
    return _controller.selectedText;
  }

  void _updateResult() {
    if (_shouldNotUpdateResults) {
      return;
    }
    final CodeFindOption? option = value?.option;
    if (option == null || option.pattern.isEmpty) {
      value = value?.copyWith(
        result: null,
        searching: false
      );
      return;
    }
    final bool optionChanged = value?.result?.option != option;
    if (!optionChanged && _controller.codeLines.equals(value?.result?.codeLines)) {
      value = value?.copyWith(
        result: value?.result,
        searching: false
      );
      return;
    }
    final CodeLines codeLines = _controller.codeLines;
    final CodeLineSelection selection = _controller.unfoldLineSelection;
    final bool forwardMatch = !_replacingMatch;

    // The native side first. It already holds the document, so nothing has to be
    // serialised across to an isolate — and the copy it holds carries the
    // flattened view search reads, folded regions and all.
    //
    // The search runs on a worker thread, so the answer arrives later, exactly
    // as the isolate's did. That is not incidental: applying a result expands
    // the chunk holding the current match, which writes back to the controller
    // that is in the middle of notifying.
    final _NativeDocumentMirror? mirror = _nativeMirror();
    if (mirror != null) {
      final Future<NativeFindResult?> search = mirror.find(
        pattern: option.pattern,
        caseSensitive: option.caseSensitive,
        regex: option.regex,
      );
      search
          .then((NativeFindResult? found) => _applyResult(
                option,
                optionChanged,
                _toFindResult(found, option, codeLines, selection, forwardMatch),
              ));
      return;
    }

    // No document to search: a controller of someone else's that keeps no
    // native copy, or a build with no native core. The search is the core's and
    // there is no second implementation of it here, so the panel is told there
    // is nothing to show.
    _applyResult(option, optionChanged, null);
  }

  /// The native copy of the document, if the controller keeps one.
  ///
  /// A custom [CodeLineEditingController] implementation has nowhere to keep
  /// one, and has nothing to search.
  _NativeDocumentMirror? _nativeMirror() {
    final _CodeLineEditingControllerImpl? owner =
        _controller is _CodeLineEditingControllerImpl
            ? _controller as _CodeLineEditingControllerImpl
            : null;
    return owner?.syncNativeDocument();
  }

  /// The search result, or `null` when there is nothing to show.
  ///
  /// The Dart implementation spells "no match" and "no valid pattern" the same
  /// way — as no result at all — so this does too rather than inventing a
  /// distinction the panel has never drawn.
  static CodeFindResult? _toFindResult(
    NativeFindResult? found,
    CodeFindOption option,
    CodeLines codeLines,
    CodeLineSelection selection,
    bool forwardMatch,
  ) {
    if (found == null || found.matches.isEmpty) {
      return null;
    }
    final List<CodeLineSelection> selections = found.matches
        .map((NativeFindMatch match) => CodeLineSelection(
              baseIndex: match.startLine,
              baseOffset: match.startOffset,
              extentIndex: match.endLine,
              extentOffset: match.endOffset,
            ))
        .toList();
    return CodeFindResult(
      index: _currentMatchIndex(selections, selection, forwardMatch),
      matches: selections,
      option: option,
      codeLines: codeLines,
      dirty: false,
    );
  }

  /// Applies a search result, or the absence of one.
  ///
  /// Shared by both engines so that which one answered cannot change what the
  /// panel shows.
  void _applyResult(CodeFindOption option, bool optionChanged, CodeFindResult? result) {
    if (option != value?.option) {
      // The option changed while the search was in flight, so the answer is to
      // a question nobody is asking any more.
      value = value?.copyWith(result: null, searching: false);
      return;
    }
    final CodeFindValue newValue = value!.copyWith(result: result, searching: false);
    if (optionChanged) {
      _expandChunkIfNeeded(newValue);
    }
    value = newValue;
  }

  /// Which match the caret is on, or should move to.
  ///
  /// Shared by both engines: the choice is about where the caret is, not about
  /// how the matches were found, and a second copy of it would eventually
  /// disagree with this one.
  static int _currentMatchIndex(
    List<CodeLineSelection> selections,
    CodeLineSelection selection,
    bool forwardMatch,
  ) {
    int index;
    if (forwardMatch) {
      index = selections.length - 1;
      for (; index > 0; index--) {
        if (selections[index].contains(selection)) {
          break;
        }
        if (selections[index].endIndex < selection.startIndex) {
          break;
        }
        if (selections[index].endIndex == selection.startIndex &&
          selections[index].endOffset <= selection.startOffset) {
          break;
        }
      }
    } else {
      index = 0;
      for (; index < selections.length; index++) {
        if (selections[index].contains(selection)) {
          break;
        }
        if (selections[index].startIndex > selection.endIndex) {
          break;
        }
        if (selections[index].startIndex == selection.endIndex &&
          selections[index].startOffset >= selection.endOffset) {
          break;
        }
      }
    }
    return max(min(index, selections.length - 1), 0);
  }

  void _expandChunkIfNeeded(CodeFindValue value) {
    _shouldNotUpdateResults = true;
    final CodeLineSelection? match = value.result?.currentMatch;
    if (match != null) {
      _expandChunkIfSelectionInvisible(match);
    }
    _shouldNotUpdateResults = false;
  }

  void _expandChunkIfSelectionInvisible(CodeLineSelection match) {
    if (match.isSameLine) {
      final CodeLineIndex start = _controller.lineIndex2Index(match.startIndex);
      if (start.chunkIndex < 0) {
        return;
      }
      _controller.expandChunk(start.index);
    } else {
      final CodeLineIndex start = _controller.lineIndex2Index(match.startIndex);
      final CodeLineIndex end = _controller.lineIndex2Index(match.endIndex);
      if (start.chunkIndex >= 0) {
        _controller.expandChunk(start.index);
      } else if (end.chunkIndex >= 0) {
        _controller.expandChunk(end.index);
      } else {
        return;
      }
    }
    // If the selection is in a nested chunk, we should expand the chunk from outside one by one
    _expandChunkIfSelectionInvisible(match);
  }
}
