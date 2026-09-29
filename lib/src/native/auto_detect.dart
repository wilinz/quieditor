/// Which of several languages a document is written in.
///
/// This is highlight.js's rule, and it is here rather than in the core because
/// the answers it needs are the editor's: which languages a theme offers, and
/// which of them declare themselves a superset of another. What the core
/// contributes is the score — how much of the document looked like what each
/// grammar is made of — and picking between scores is this.
library;

/// One language's case for being the right one.
class NativeHighlightCandidate {
  const NativeHighlightCandidate({
    required this.name,
    required this.relevance,
    this.supersetOf,
  });

  final String name;

  /// What the core found, on highlight.js's scale.
  final double relevance;

  /// The language this one is a superset of, if it says so — C++ of C, for
  /// instance. A tie goes to the narrower one, because a document written in C
  /// is also valid C++.
  final String? supersetOf;

  @override
  String toString() => '$name ($relevance${supersetOf == null ? '' : ', superset of $supersetOf'})';
}

/// The language [candidates] agree the document is written in, or `null` when
/// there are none to choose between.
///
/// The highest score wins. A tie goes to whichever came first, except that a
/// language naming another as its `supersetOf` gives way to it — so a theme
/// offering C++ and C picks C for a file that both can read.
String? bestLanguage(List<NativeHighlightCandidate> candidates) {
  if (candidates.isEmpty) {
    return null;
  }
  NativeHighlightCandidate best = candidates.first;
  for (final NativeHighlightCandidate candidate in candidates.skip(1)) {
    if (_beats(candidate, best)) {
      best = candidate;
    }
  }
  return best.name;
}

/// Whether [candidate] should be preferred to the one in front.
///
/// Three rules, in the order highlight.js applies them:
///
/// * the higher score wins;
/// * a language that names the other as the thing it is a superset *of* gives
///   way, because a document the narrower one can read is also readable as the
///   wider one, and the narrower is the more useful answer;
/// * anything else is a tie, and a tie leaves the one that came first where it
///   is — which is how highlight.js has always settled them, its sort being
///   stable.
bool _beats(NativeHighlightCandidate candidate, NativeHighlightCandidate best) {
  if (candidate.relevance != best.relevance) {
    return candidate.relevance > best.relevance;
  }
  if (candidate.supersetOf == best.name) {
    return false;
  }
  if (best.supersetOf == candidate.name) {
    return true;
  }
  return false;
}
