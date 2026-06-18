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
grammar is a hand-tuned translation of that spec. CI regenerates `jac.spec`
from a pinned jaclang and diffs it against a committed snapshot, so any drift in
the upstream language grammar surfaces as a failing check.

## Building

Prerequisites: [jaclang](https://www.jac-lang.org) (`pip install jaclang`) and
the tree-sitter CLI (`npm i -g tree-sitter-cli` or `cargo install tree-sitter-cli`).

```sh
jac run grammar.jac                        # OSP grammar graph -> src/grammar.json
tree-sitter generate src/grammar.json      # -> src/parser.c
tree-sitter test                           # run corpus tests
```

The committed `src/parser.c` is what editors compile, so **consumers need no
build step** — only contributors regenerating the grammar do. This is a Jac
project (`jac.toml`); there is intentionally no `package.json`/npm manifest
(nvim-treesitter consumes `src/parser.c` + `queries/` directly).

## Status

**v0.1 — generates cleanly and parses core Jac.** The parser builds without
errors (~13 MB `parser.c`); simple, idiomatic files parse with zero or few
error nodes (e.g. the chess example: 0 errors; littleX `main.jac`: a handful).

Covered: declarations (obj/node/edge/walker/class, abilities with access tags,
has, enum, impl, glob, test, type, sem), statements (if/elif/else, while, for
in / for-to-by, try/except/finally, with, match, switch, return/yield/raise/
assert/del/visit/report/disengage/global/nonlocal), the full expression
precedence ladder, collections & comprehensions, imports (dotted, relative,
and string-path/JS-interop), and the graph/edge operators.

**Known gaps (tracked follow-ups), in rough priority order:**
- **f-strings** — interpolation isn't split out; `f"..."` is lexed as an opaque
  string. Needs a C external scanner.
- **JSX / view bodies** (`.cl.jac` frontend files) — not yet modelled; needs a
  C external scanner for JSX text/tag tokenization. These files dominate the
  remaining parse errors in the example corpus.
- **Typed lambdas** (`lambda x: T : expr`) and some **complex edge-reference
  filters** (`[self<-:Follow:<-[?:Profile]]`).
- **Cast `x as T`** — `as` is currently reserved for except/with/import
  bindings to avoid pervasive grammar conflicts.

### Engineering note (parse-table size)

tree-sitter builds one LR state machine per *distinct* rule structure, so
inlining a helper (e.g. a name/decorator/code-block fragment) at many call
sites duplicates its states and can blow up table construction. Helpers that
appear in many places — `name_ref`, `decorator_list`, `block_body` — are
therefore emitted as **shared named rules**, not inlined. Regenerate with a
memory cap during development (`ulimit -v` + `timeout`) so a structural mistake
fails fast instead of exhausting host memory.

## Neovim

See [`docs/nvim.md`](docs/nvim.md) for filetype detection, parser registration
with `nvim-treesitter`, and query installation.

## License

MIT
