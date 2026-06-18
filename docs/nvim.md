# Neovim setup

`tree-sitter-jac` works with Neovim's tree-sitter integration
(`nvim-treesitter`). Until the parser is published to the nvim-treesitter
registry, register it manually.

## 1. Filetype detection

Teach Neovim that `*.jac` (and the `*.impl.jac` / `*.test.jac` / `*.cl.jac` /
`*.sv.jac` / `*.na.jac` variants) are filetype `jac`:

```lua
vim.filetype.add({
  extension = { jac = "jac" },
  pattern = { [".*%.%a+%.jac"] = "jac" }, -- impl.jac, test.jac, cl.jac, ...
})
```

## 2. Register the parser

```lua
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.jac = {
  install_info = {
    url = "https://github.com/jaseci-labs/tree-sitter-jac",
    files = { "src/parser.c" },
    branch = "main",
    -- generate_requires_npm = false, -- parser.c is committed
  },
  filetype = "jac",
}
```

Then `:TSInstall jac`.

For local development against a checkout:

```lua
parser_config.jac.install_info.url = "/path/to/tree-sitter-jac" -- local path
```

## 3. Install queries

Copy this repo's `queries/*.scm` to where nvim-treesitter looks for them, e.g.
`~/.config/nvim/queries/jac/`, or rely on the runtime path if installed as a
plugin. Provided queries:

- `highlights.scm` — syntax highlighting
- `locals.scm` — scopes & definitions (for variable highlighting)
- `folds.scm` — `foldmethod=expr` folding
- `injections.scm` — embedded language regions (e.g. inline Python)

## 4. Editor niceties (ftplugin)

Tree-sitter handles highlighting/folding, but comments and indent are still
worth setting. In `~/.config/nvim/after/ftplugin/jac.lua`:

```lua
vim.bo.commentstring = "# %s"
vim.bo.comments = ":#"
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
```

## LSP (separate from this grammar)

Syntax highlighting (this grammar) and semantic features (completion, hover,
diagnostics, go-to-definition) are independent. For the latter, point Neovim's
built-in LSP at the Jac language server:

```lua
vim.lsp.start({
  name = "jac",
  cmd = { "jac", "lsp" },
  root_dir = vim.fs.dirname(vim.fs.find({ "jac.toml", ".git" }, { upward = true })[1]),
})
```

Run this from the `jac` ftplugin or a `FileType jac` autocommand so it attaches
to `.jac` buffers.
