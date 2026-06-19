# Neovim setup

`tree-sitter-jac` works with Neovim's tree-sitter integration
(`nvim-treesitter`). Until the parser lands in the nvim-treesitter community
registry, register it manually as shown below.

This repo doubles as a Neovim plugin: it ships `ftdetect/jac.lua` (filetype
detection for `*.jac` and the `*.impl.jac` / `*.cl.jac` / `*.sv.jac` /
`*.na.jac` / `*.test.jac` variants) and `ftplugin/jac.lua` (commentstring,
indent). Install it like any plugin to get those for free, e.g. with lazy.nvim:

```lua
{ "jaseci-labs/tree-sitter-jac" }
```

If you are *not* installing it as a plugin, add filetype detection yourself:

```lua
vim.filetype.add({ extension = { jac = "jac" } })
```

## 1. Register and install the parser

```lua
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.jac = {
  install_info = {
    url = "https://github.com/jaseci-labs/tree-sitter-jac",
    -- BOTH files are required: the grammar uses an external scanner
    -- (src/scanner.c) for f-strings, JSX text, and `::py::` blocks.
    files = { "src/parser.c", "src/scanner.c" },
    branch = "main",
    generate_requires_npm = false, -- src/parser.c is committed
  },
  filetype = "jac",
}
```

Then `:TSInstall jac`.

For local development against a checkout, point the url at the path:

```lua
parser_config.jac.install_info.url = "/path/to/tree-sitter-jac"
```

## 2. Install the queries

`:TSInstall` compiles the parser but does not copy queries. Put this repo's
`queries/*.scm` where nvim-treesitter looks for them — `queries/jac/` on your
`runtimepath` (e.g. `~/.config/nvim/queries/jac/`), or get them automatically
by installing this repo as a plugin (above). Provided queries:

- `highlights.scm` — syntax highlighting (incl. f-string interpolations & JSX)
- `locals.scm` — scopes & definitions
- `folds.scm` — `foldmethod=expr` folding
- `injections.scm` — embedded languages (inline Python, comments)
- `indents.scm` — indentation
- `textobjects.scm` — `nvim-treesitter-textobjects` (functions, classes, …)

> `::py:: … ::py::` blocks (and code-in-comments) are highlighted by injecting
> another language, so install that parser for it to render — e.g.
> `:TSInstall python`. The `textobjects.scm` motions additionally require the
> `nvim-treesitter-textobjects` plugin.

## 3. Folding & indentation

```lua
-- folding
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
-- indentation: enable in your nvim-treesitter setup
require("nvim-treesitter.configs").setup({ indent = { enable = true } })
```

## 4. LSP (separate from this grammar)

Highlighting (this grammar) and semantic features (completion, hover,
diagnostics, go-to-definition) are independent. For the latter, point Neovim's
built-in LSP at the Jac language server, which ships with jaclang:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "jac",
  callback = function(args)
    vim.lsp.start({
      name = "jac",
      cmd = { "jac", "lsp" },
      root_dir = vim.fs.root(args.buf, { "jac.toml", ".git" }),
    })
  end,
})
```

Once `jac` is added to [nvim-lspconfig], this becomes
`require("lspconfig").jac.setup({})`. The upstream tracking issue is
jaseci-labs/jaseci#6784.

[nvim-lspconfig]: https://github.com/neovim/nvim-lspconfig
