// External scanner for tree-sitter-jac (hand-written C).
//
// This is the ONE hand-authored native file in the project; the grammar itself
// is authored in Jac (grammar.jac -> src/grammar.json) and src/parser.c is
// generated. The scanner supplies tokens whose boundaries the context-free
// grammar cannot express, because they require unbounded, context-sensitive
// lexing:
//
//   * PYINLINE  -- a `::py:: ... ::py::` inline-Python block (jac.spec PYNLINE).
//   * JSX_TEXT  -- a run of raw character data between JSX tags, i.e. up to the
//                  next `<`, `{` or `}` (which the context-free grammar handles).
//
// The TokenType enum order MUST match the `externals` array in grammar.jac.

#include "tree_sitter/parser.h"

#include <wctype.h>

enum TokenType {
  PYINLINE,
  JSX_TEXT,
};

// ---------------------------------------------------------------------------
// No persistent state (yet); all tokens are scanned in a single call.
// ---------------------------------------------------------------------------

void *tree_sitter_jac_external_scanner_create(void) { return NULL; }
void tree_sitter_jac_external_scanner_destroy(void *payload) { (void)payload; }

unsigned tree_sitter_jac_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}

void tree_sitter_jac_external_scanner_deserialize(void *payload, const char *buffer,
                                                  unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

// `::py::` -- the same marker opens and closes the block.
static const char PY_MARK[] = {':', ':', 'p', 'y', ':', ':'};
static const int PY_MARK_LEN = 6;
// KMP longest-proper-prefix-suffix table for "::py::" (fallback uses LPS[m-1]).
static const int PY_LPS[] = {0, 1, 0, 0, 1, 2};

static bool scan_pyinline(TSLexer *lexer) {
  // Skip leading whitespace (treated as extras, not part of the token).
  while (iswspace(lexer->lookahead)) {
    lexer->advance(lexer, true);
  }

  // Match the opening `::py::`.
  for (int i = 0; i < PY_MARK_LEN; i++) {
    if (lexer->lookahead != (int32_t)PY_MARK[i]) {
      return false;
    }
    lexer->advance(lexer, false);
  }

  // Scan the body until the closing `::py::` (KMP over the marker).
  int m = 0;
  while (!lexer->eof(lexer)) {
    int32_t c = lexer->lookahead;
    while (m > 0 && c != (int32_t)PY_MARK[m]) {
      m = PY_LPS[m - 1];
    }
    if (c == (int32_t)PY_MARK[m]) {
      m++;
    }
    lexer->advance(lexer, false);
    if (m == PY_MARK_LEN) {
      lexer->mark_end(lexer);
      lexer->result_symbol = PYINLINE;
      return true;
    }
  }
  return false;  // unterminated block
}

// JSX raw text: a run of characters between tags, terminated by `<` (a child
// or closing tag), `{` (an embedded expression) or `}`. Leading layout
// whitespace is skipped as extras so insignificant indentation between tags
// doesn't become text nodes; a run that is only whitespace yields no token.
static bool scan_jsx_text(TSLexer *lexer) {
  while (iswspace(lexer->lookahead)) {
    lexer->advance(lexer, true);
  }
  bool has_text = false;
  while (!lexer->eof(lexer)) {
    int32_t c = lexer->lookahead;
    if (c == '<' || c == '{' || c == '}') {
      break;
    }
    lexer->advance(lexer, false);
    has_text = true;
    lexer->mark_end(lexer);
  }
  if (has_text) {
    lexer->result_symbol = JSX_TEXT;
    return true;
  }
  return false;
}

bool tree_sitter_jac_external_scanner_scan(void *payload, TSLexer *lexer,
                                           const bool *valid_symbols) {
  (void)payload;
  if (valid_symbols[JSX_TEXT] && scan_jsx_text(lexer)) {
    return true;
  }
  if (valid_symbols[PYINLINE]) {
    return scan_pyinline(lexer);
  }
  return false;
}
