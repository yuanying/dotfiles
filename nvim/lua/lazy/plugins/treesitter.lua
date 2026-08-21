-- tree-sitter のパーサーとクエリ。
--
-- nvim-treesitter は main ブランチを使う。master は Neovim 0.11 までで
-- 打ち止めで、0.12 では query の directive に渡る match の形が「1 キャプチャ
-- = 1 ノード」から「ノードの配列」に変わったのに追従していない。そのため
-- master の set-lang-from-info-string! などが TSNode ではなくテーブルを
-- get_node_text() に渡し、markdown / ruby / html を開くと highlighter が
-- "attempt to call method 'range'" で落ちる。
--
-- main は完全な作り直しで nvim-treesitter.configs は無い。プラグインが持つ
-- のはパーサーの導入とクエリだけで、ハイライトとインデントの有効化は
-- 利用側 (このファイル) の仕事になっている。
--
-- パーサーは配布物ではなくその場でビルドするので tree-sitter CLI が要る。
-- devbox は Dockerfile が、Mac は bin/mac/setup-packages.sh の brew が入れる。

-- 入れておく言語。ファイルタイプ名ではなく tree-sitter の言語名で書く。
--
-- ここに書いた言語だけ、パーサーとクエリが stdpath('data')/site 以下へ入り
-- $VIMRUNTIME のものより優先される。書かなかった言語は Neovim 同梱の
-- パーサーとクエリがそのまま使われる (markdown などはそれで足りる)。
-- パーサーとクエリは版が揃っていないと壊れるので、片方だけ足さない。
local LANGUAGES = {
  "c",
  "go",
  "html",
  "javascript",
  "json",
  "lua",
  "python",
  "ruby",
  "vim",
  "vimdoc",
  "yaml",
}

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    -- main は遅延読み込みに対応していない (plugin/ でコマンドと
    -- ファイルタイプ登録を張るため)。
    lazy = false,
    build = ":TSUpdate",
    config = function()
      local installed = require("nvim-treesitter.config").get_installed()
      local missing = vim.tbl_filter(function(lang)
        return not vim.list_contains(installed, lang)
      end, LANGUAGES)

      if #missing > 0 then
        -- install() は非同期。ビルドの完了を待つと起動が止まるので待たず、
        -- 終わってから開いているバッファへ FileType を撃ち直して
        -- 下の autocmd を通す (初回起動でハイライトが付かないのを防ぐ)。
        require("nvim-treesitter").install(missing):await(vim.schedule_wrap(function()
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) then
              vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
            end
          end
        end))
      end

      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("treesitter", { clear = true }),
        callback = function(args)
          local lang = vim.treesitter.language.get_lang(args.match)
          -- パーサーが無ければ add() が nil を返す。ここで弾かないと
          -- start() が E5108 で落ちる (インストール完了前や未対応の
          -- ファイルタイプで通る)。
          if not lang or not vim.treesitter.language.add(lang) then
            return
          end
          vim.treesitter.start(args.buf, lang)
          -- インデントは main でも experimental 扱い。indents.scm を持つ
          -- 言語だけに絞り、無い言語は Vim 標準の indentexpr に任せる。
          if vim.treesitter.query.get(lang, "indents") then
            vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })
    end,
  },
}
