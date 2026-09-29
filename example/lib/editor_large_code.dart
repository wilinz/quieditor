// The case the native highlighter exists for: a large file *in a language the
// editor can colour*, edited while it is open.
//
// `LargeTextEditor` next to this is 4.6 MB of an RFC with no theme set, which
// stresses the editor rather than the highlighter — nothing in it is highlighted,
// so nothing in it shows what highlighting costs. This one is code, and it is
// highlighted: type anywhere and the colour of the line you are on catches up
// while the rest of the document is left alone, which is what the incremental
// highlighter does and what a keystroke in a document this size used to spend a
// second on.
//
// The document is the package's own `code.dart` sample repeated, rather than a
// large file committed beside it: what is being shown is the cost of
// highlighting a large document, so the document is a size you can turn up or
// down, and the repository does not carry megabytes of it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:re_editor_exmaple/find.dart';
import 'package:re_editor_exmaple/menu.dart';

/// How many times the sample is repeated, which is what sets the document's
/// size. 2,000 is around 20,000 lines and half a megabyte.
///
/// Above this the editor's own work — laying out and drawing the lines that are
/// on screen — starts to be what you notice rather than the highlighting, which
/// is a different problem from the one this page is here for.
const int _repeats = 2000;

class LargeCodeEditor extends StatefulWidget {

  const LargeCodeEditor({super.key});

  @override
  State<LargeCodeEditor> createState() => _LargeCodeEditorState();

}

class _LargeCodeEditorState extends State<LargeCodeEditor> {

  final CodeLineEditingController _controller = CodeLineEditingController();

  @override
  void initState() {
    rootBundle.loadString('assets/code.dart').then((value) {
      // Repeated as lines: the sample already ends with a line break, and
      // joining whole copies keeps every line a line of the language.
      final StringBuffer buffer = StringBuffer();
      for (int i = 0; i < _repeats; i++) {
        buffer.write(value);
      }
      _controller.text = buffer.toString();
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return CodeEditor(
      controller: _controller,
      wordWrap: false,
      // One language, so the highlighter knows what it is looking at — and so
      // the native one can take the document, since choosing between several
      // languages is `highlightAuto`, which it does not do.
      style: CodeEditorStyle(
        codeTheme: CodeHighlightTheme(
          languages: <String, CodeHighlightThemeMode>{
            'dart': CodeHighlightThemeMode(mode: langDart),
          },
          theme: atomOneLightTheme,
        ),
      ),
      indicatorBuilder: (context, editingController, chunkController, notifier) {
        return Row(
          children: [
            DefaultCodeLineNumber(
              controller: editingController,
              notifier: notifier,
            ),
            DefaultCodeChunkIndicator(
              width: 20,
              controller: chunkController,
              notifier: notifier
            )
          ],
        );
      },
      findBuilder: (context, controller, readOnly) => CodeFindPanelView(controller: controller, readOnly: readOnly),
      toolbarController: const ContextMenuControllerImpl(),
      leadingDivider: Container(
        width: 1,
        color: Colors.blue
      ),
    );
  }

}
