library re_editor;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:re_highlight/re_highlight.dart';
import 'package:isolate_manager/isolate_manager.dart';

// The Rust core is reached through this one import. `native.dart` picks the
// FFI or the stub implementation at compile time, so nothing below has to know
// which platform it is being built for.
import 'native/native.dart';

// Getting a grammar to the Rust highlighter, and its answer back into a
// renderer. Neither knows about the other, so they stay their own libraries.
import 'native/auto_detect.dart';
import 'native/grammar_json.dart';
import 'native/highlight_lines.dart';
import 'native/highlight_spans.dart';

// The types that appear in the public surface — the identity of the loaded
// library, for a bug report to be answerable, and the results the native core
// hands back. The loader itself stays internal, so there is exactly one way in.
export 'native/native.dart'
    show
        NativeAbiInfo,
        NativeChunk,
        NativeChunkAnalysis,
        NativeDocument,
        NativeFindMatch,
        NativeFindResult,
        NativeGrammar,
        NativeHighlightChunk,
        NativeHighlightNode,
        NativeHighlightUpdate,
        NativeHighlighter,
        NativeLine,
        kAllHighlightLines;

part '_code_floating_cursor.dart';
part '_code_autocomplete.dart';
part '_code_editable.dart';
part '_code_extensions.dart';
part '_code_field.dart';
part '_code_find.dart';
part '_code_formatter.dart';
part '_code_highlight.dart';
part '_code_indicator.dart';
part '_code_input.dart';
part '_code_line.dart';
part '_code_lines.dart';
part '_code_paragraph.dart';
part '_code_scroll.dart';
part '_code_selection.dart';
part '_code_shortcuts.dart';
part '_code_span.dart';
part '_consts.dart';
part '_isolate.dart';
part '_re_editor_native.dart';
part 'code_autocomplete.dart';
part 'code_chunk.dart';
part 'code_editor.dart';
part 'code_find.dart';
part 'code_formatter.dart';
part 'code_indicator.dart';
part 'code_line.dart';
part 'code_lines.dart';
part 'code_paragraph.dart';
part 'code_shortcuts.dart';
part 'code_scroll.dart';
part 'code_span.dart';
part 'code_theme.dart';
part 'code_toolbar.dart';
part 'debug/_trace.dart';