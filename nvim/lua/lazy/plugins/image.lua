-- PNG を開くと kitty graphics protocol で画像として表示する。
--
-- 経路は Ghostty -> ssh -> herdr -> nvim。herdr は kitty graphics を自分で
-- 描いて外の端末へ出し直すので、ssh で直接つないだときだけ見える。mosh は
-- 画像を運ばないため、mosh 越しでは表示されない。
--
-- snacks は PNG でも大きさを ImageMagick の identify で調べる。入っていないと
-- 何も表示されない。
return {
  {
    "folke/snacks.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      image = {
        enabled = true,
        formats = { "png" },
        -- Markdown などに埋め込まれた画像の表示は使わない。
        doc = { enabled = false },
      },
    },
  },
}
