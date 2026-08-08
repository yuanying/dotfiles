-- ホストごとに配色を変えるため、適用する colorscheme を環境変数で選ぶ。
-- ステータスラインを $AIRLINE_THEME で切り替えているのと同じ流儀。
-- 値は ~/.zshrc.local (リポジトリ管理外) でホストごとに設定する。
--
-- 候補になる colorscheme は lua/lazy/plugins/colorscheme.lua に登録して
-- おくこと。未登録の名前を指定すると既定値へフォールバックする。
local M = {}

local DEFAULT = "solarized"

function M.setup()
  local name = vim.env.NVIM_COLORSCHEME
  if name == nil or name == "" then
    name = DEFAULT
  end

  -- 指定された配色が入っていない環境でも起動を止めない。
  local ok = pcall(vim.cmd.colorscheme, name)
  if not ok and name ~= DEFAULT then
    vim.notify(
      ("colorscheme %q が見つかりません。%s を使います。"):format(name, DEFAULT),
      vim.log.levels.WARN
    )
    pcall(vim.cmd.colorscheme, DEFAULT)
  end
end

return M
