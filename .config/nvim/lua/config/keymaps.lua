-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set
local opts = { noremap = true, silent = true }

-- e → entra in insert mode (da normal mode)
map("n", "e", "i", opts)

-- Esc da normal mode → chiudi editor
map("n", "<Esc>", ":q<CR>", opts)

-- Cmd+s / Ctrl+s → salva (WezTerm mappa Cmd+s a Ctrl+s)
map({ "n", "i", "v" }, "<C-s>", "<Esc>:w<CR>", opts)
