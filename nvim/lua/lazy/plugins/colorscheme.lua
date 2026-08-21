-- 候補となる colorscheme を登録するだけの場所。どれを適用するかは
-- $NVIM_COLORSCHEME を見て lua/colorscheme.lua が決める。
--
-- どのホストでも候補として選べるよう、遅延読み込みはしない。ハイライト
-- 定義を読むだけなので、複数入っていても起動コストはほとんど増えない。
-- priority を上げて、ハイライトを引くプラグインより先に読ませる。
return {
  {
    -- 'mhartington/oceanic-next',
        -- colorscheme OceanicNext
    'glepnir/zephyr-nvim',
    lazy = false,
    priority = 1000,
  },
  {
    -- setup() は colorscheme コマンドより先に呼ぶ必要がある。
    "ellisonleao/gruvbox.nvim",
    lazy = false,
    priority = 1000,
    opts = {},
    config = function(_, opts)
      require("gruvbox").setup(opts)
      vim.o.background = "dark"
    end,
  },
  {
    -- ホスト別設定が無いマシンのデフォルト。
    -- setup() は colorscheme コマンドより先に呼ぶ必要がある。
    "maxmx03/solarized.nvim",
    lazy = false,
    priority = 1000,
    opts = {},
    config = function(_, opts)
      vim.o.background = "dark"
      require("solarized").setup(opts)
    end,
  },
  {
    -- boucherie 用。herdr 側のテーマ (tokyo-night) と揃える。
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = {},
  },
}
