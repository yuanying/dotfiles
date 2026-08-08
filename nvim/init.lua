require("options").setup()
require("keymaps").setup()
require("plugins").setup()
-- colorscheme の適用はプラグイン読み込み後でなければならない。
require("colorscheme").setup()
