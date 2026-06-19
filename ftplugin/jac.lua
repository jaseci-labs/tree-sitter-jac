-- Buffer-local settings for Jac files.
--
-- Tree-sitter highlighting, folding, and indentation are driven by the
-- queries/ in this repo once the parser is installed (see docs/nvim.md); this
-- ftplugin only sets the editor conventions Neovim can't infer from the grammar.

vim.bo.commentstring = "# %s"
vim.bo.comments = ":#"
vim.bo.suffixesadd = ".jac"

-- Jac uses Python-style 4-space indentation.
vim.bo.expandtab = true
vim.bo.shiftwidth = 4
vim.bo.softtabstop = 4
vim.bo.tabstop = 4

vim.b.undo_ftplugin = table.concat({
  "setlocal commentstring< comments< suffixesadd<",
  "expandtab< shiftwidth< softtabstop< tabstop<",
}, " ")
