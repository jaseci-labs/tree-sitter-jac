# tree-sitter-jac

A [tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for the
[Jac](https://www.jac-lang.org/) programming language — providing fast,
incremental syntax highlighting, code folding, structural selection, and
text objects for editors (Neovim, Helix, Zed, Emacs, …).

## What's unusual about this grammar

The grammar is **authored in Jac itself**, using object-spatial programming
(OSP). Instead of the conventional `grammar.js`, the grammar is built as an
**ordered graph** — every tree-sitter rule construct is a `node`, structure is
expressed with ordered child edges, and a node ability serializes the graph to
`src/grammar.json`, which `tree-sitter generate` consumes to produce
`src/parser.c`.

```
grammar.jac  ──jac run──▶  src/grammar.json  ──tree-sitter generate──▶  src/parser.c
```

This is possible because tree-sitter's real input contract is `grammar.json`;
`grammar.js` is just the usual way to emit it. Authoring as an ordered OSP
graph relies on Jac's guaranteed connection-order out-edges
([jaseci-labs/jaseci#6785](https://github.com/jaseci-labs/jaseci/issues/6785)),
so `seq(A, B, C)` connects three child edges that read back in order at emit
time. See [`grammar.jac`](grammar.jac).

## Source of truth & drift detection

The Jac grammar's authoritative EBNF is auto-extracted from the jaclang parser
by `grammar_extract_pass` and published as `jaclang/jac.spec`. This tree-sitter
grammar is a hand-tuned translation of that spec. CI fetches `jac.spec` from the
pinned jaclang release tag (`.jaclang-version`) and diffs it against the
committed `jac.spec.snapshot`, so any drift in the upstream language grammar
surfaces as a failing check.

## Building

Prerequisites: [jaclang](https://www.jac-lang.org) (`pip install jaclang`) and
the tree-sitter CLI (`npm i -g tree-sitter-cli` or `cargo install tree-sitter-cli`).

```sh
jac run grammar.jac                        # OSP grammar graph -> src/grammar.json
tree-sitter generate src/grammar.json      # -> src/parser.c
tree-sitter test                           # run corpus tests
```

The committed `src/parser.c` and `src/scanner.c` are what editors compile, so
**consumers need no build step** — only contributors regenerating the grammar
do. This is a Jac project (`jac.toml`); there is intentionally no
`package.json`/npm manifest. Editors consume `src/parser.c` + `src/scanner.c` +
`queries/`, with grammar metadata in `tree-sitter.json`.

## Status

**Parses real-world Jac.** Across the full jaclang corpus (~3,100 `.jac` files)
**~91% parse with zero error nodes** — and since a large share of the remainder
are jaclang's own negative-test fixtures (files written to *fail* compilation),
the pass rate on valid Jac is **~97%**. Track it with
`jac run scripts/error-density.jac <corpus-dir> [--sample N] [--triage]`.

Covered: declarations (obj/node/edge/walker/class with access tags & bases,
abilities with event clauses, has + property accessors, enum + bases, impl,
glob, test, type, sem), statements (if/elif/else, while, for-in / for-to-by,
try/except/finally, with, match, switch, return/yield/raise/assert/del/visit/
report/disengage/global/nonlocal), the full expression precedence ladder
including atomic & concurrent (`flow`/`wait`) expressions, collections &
comprehensions (incl. generators), imports (dotted, relative, string-path/JS),
graph/edge & disconnect operators, and object-spatial filter comprehensions.

An **external scanner** ([`src/scanner.c`](src/scanner.c)) supplies the
context-sensitive tokens the grammar can't express:

- **f-strings** — `f"...{expr}..."` is split into text + parsed interpolations
  (with format specs, conversions, escapes, triple/raw quotes, and nesting).
- **JSX / view bodies** (`.cl.jac`) — elements, attributes/spread, fragments,
  `{expr}` children, and `{ if/for { <jsx> } }` view-body control flow.
- **`::py::`** inline-Python blocks.

**Known gaps (small, tracked follow-ups):**
- **Cast `x as T`** — `as` is reserved for except/with/import bindings to avoid
  pervasive grammar conflicts; bare casts are deferred.
- A few reserved words used as identifiers (e.g. `override = ...`) and some
  `.na` native-only constructs.

### Engineering note (parse-table size)

tree-sitter builds one LR state machine per *distinct* rule structure, so
inlining a helper (e.g. a name/decorator/code-block fragment) at many call
sites duplicates its states and can blow up table construction. Helpers that
appear in many places — `name_ref`, `decorator_list`, `block_body` — are
therefore emitted as **shared named rules**, not inlined. Regenerate with a
memory cap during development (`ulimit -v` + `timeout`) so a structural mistake
fails fast instead of exhausting host memory.

## Editor integration

The grammar manifest is [`tree-sitter.json`](tree-sitter.json) and the queries
(highlights / locals / folds / injections / indents / textobjects) are in
[`queries/`](queries).

- **Neovim** — [`docs/nvim.md`](docs/nvim.md). This repo doubles as a Neovim
  plugin (it ships [`ftdetect/`](ftdetect/jac.lua) and
  [`ftplugin/`](ftplugin/jac.lua)); register the parser with `nvim-treesitter`
  (be sure to list **both** `src/parser.c` and `src/scanner.c`).
- **Helix / Zed** — [`docs/editors.md`](docs/editors.md).
- **Registries** (nvim-treesitter, nvim-lspconfig, Helix/Zed, GitHub Linguist)
  are upstream PRs; the artifacts they need live here. See
  [`docs/editors.md`](docs/editors.md#registries-upstream-prs--maintainer-action).

## License

MIT
