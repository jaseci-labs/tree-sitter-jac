# Editor integration

The grammar manifest lives in [`tree-sitter.json`](../tree-sitter.json) (scope
`source.jac`, file type `jac`) and the highlight/locals/injections/folds/
indents/textobjects queries live in [`queries/jac/`](../queries/jac). Neovim has its own
guide in [nvim.md](./nvim.md); this covers the rest.

## Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "jac"
scope = "source.jac"
file-types = ["jac"]
comment-tokens = ["#"]
indent = { tab-width = 4, unit = "    " }
roots = ["jac.toml"]

[language.language-servers]
# optional semantic features (ships with jaclang)
jac = { command = "jac", args = ["lsp"] }

[[grammar]]
name = "jac"
source = { git = "https://github.com/jaseci-labs/tree-sitter-jac", rev = "main" }
```

Then build the grammar and install the queries:

```sh
hx --grammar fetch && hx --grammar build
# copy this repo's queries to Helix's runtime:
cp queries/jac/*.scm ~/.config/helix/runtime/queries/jac/
```

## Zed

Zed consumes tree-sitter grammars through an [extension]. A minimal
`extensions/jac/extension.toml`:

```toml
id = "jac"
name = "Jac"
version = "0.1.0"
schema_version = 1

[grammars.jac]
repository = "https://github.com/jaseci-labs/tree-sitter-jac"
rev = "main"
```

with `extensions/jac/languages/jac/config.toml`:

```toml
name = "Jac"
grammar = "jac"
path_suffixes = ["jac"]
line_comments = ["# "]
```

and the queries copied to `extensions/jac/languages/jac/` (Zed reads
`highlights.scm`, `injections.scm`, `indents.scm`, etc. from there).

[extension]: https://zed.dev/docs/extensions/languages

## Registries (upstream PRs — maintainer action)

These make the grammar installable with zero manual config, but each is a pull
request to a *third-party* repository:

- **nvim-treesitter** — add a `jac` entry to `lua/nvim-treesitter/parsers.lua`
  (url, files `{ "src/parser.c", "src/scanner.c" }`, maintainers) so
  `:TSInstall jac` works out of the box. Queries are vendored under
  `queries/jac/` in that repo.
- **nvim-lspconfig** — add a `jac` server config (`cmd = { "jac", "lsp" }`,
  `root_dir` on `jac.toml`) — tracking issue jaseci-labs/jaseci#6784.
- **GitHub Linguist** — add `Jac` to `lib/linguist/languages.yml`, vendor this
  grammar, and provide `samples/Jac/` so `.jac` files highlight (and are
  classified) on GitHub.
- **Helix / Zed registries** — submit the grammar + queries above to
  helix-editor/helix and the Zed extensions registry.

The in-repo artifacts those PRs reference — `src/parser.c` + `src/scanner.c`,
`queries/jac/*.scm`, and `tree-sitter.json` — are all present and CI-verified here.
