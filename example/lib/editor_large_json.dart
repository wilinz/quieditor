// A large document in the language the editor is most often pointed at.
//
// `LargeCodeEditor` next to this does the same thing with Dart; this one is
// JSON, for two reasons. It is what people actually open by the megabyte, and
// its grammar is the least forgiving of the two — a JSON document is mostly
// strings and structure, so a mistake in the highlighter shows up as text that
// is the wrong colour rather than as text that is missing.
//
// The document is the package's own `code.json` sample repeated into an array,
// rather than a large file committed beside it: what is being shown is what a
// document this size costs to highlight, so the size is a number you can change,
// and the repository does not carry megabytes of it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:re_editor_exmaple/find.dart';
import 'package:re_editor_exmaple/menu.dart';

/// How many times the sample is repeated, which is what sets the document's
/// size. 300 is around 1.4 MB and 40,000 lines.
const int _repeats = 300;

class LargeJsonEditor extends StatefulWidget {

  const LargeJsonEditor({super.key});

  @override
  State<LargeJsonEditor> createState() => _LargeJsonEditorState();

}

class _LargeJsonEditorState extends State<LargeJsonEditor> {

  final CodeLineEditingController _controller = CodeLineEditingController();

  @override
  void initState() {
    rootBundle.loadString('assets/code.json').then((value) {
      // An array of copies, which is a document the grammar is written for: the
      // sample on its own is one object, and copying it into a list keeps every
      // copy a whole JSON value.
      final StringBuffer buffer = StringBuffer('[\n');
      for (int i = 0; i < _repeats; i++) {
        if (i > 0) {
          buffer.write(',\n');
        }
        buffer.write(value.trim());
      }
      buffer.write('\n]\n');
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
            'json': CodeHighlightThemeMode(mode: langJson),
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
