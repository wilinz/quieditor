/// Reads a FlatBuffer `ulong` on a platform that has no 64-bit integer.
///
/// `package:flat_buffers` reads one with `ByteData.getUint64`, and **the web has
/// no such method**. JavaScript has no 64-bit integer to put the answer in, so
/// the call does not compile there and anything reading a `ulong` — three
/// responses, all of them carrying a document's revision — is a decode that
/// throws. Nothing about that is visible until it runs in a browser: on the VM
/// the same generated code has always worked.
///
/// So the value is assembled from the two 32-bit halves it is stored as, which
/// every platform can read. `tool/generate_bindings.dart` hands this reader to
/// the generated code as it writes each file out; the fields are `ulong` in the
/// schemas and stay that way.
library;

import 'dart:typed_data';

import 'package:flat_buffers/flat_buffers.dart' as fb;

/// Reads an unsigned 64-bit integer as two unsigned 32-bit halves.
///
/// Named to match the reader it replaces, so the substitution in the generator
/// reads as what it is.
class Uint64Reader extends fb.Reader<int> {
  const Uint64Reader();

  @override
  int get size => 8;

  @override
  int read(fb.BufferContext bc, int offset) {
    final ByteData data = bc.buffer;
    final int low = data.getUint32(offset, Endian.little);
    final int high = data.getUint32(offset + 4, Endian.little);
    // Exact as far as a JavaScript number counts integers, which is 2^53. The
    // three fields this reads are document revisions — a counter the editor
    // spends one of per edit — and reaching 2^53 would take four thousand
    // trillion of them, so the limit is not one to design around. What matters
    // is that the alternative is not a smaller limit but a decoder that throws
    // in every browser.
    return low + high * 0x100000000;
  }
}
