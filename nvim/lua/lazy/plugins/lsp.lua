local lsp = vim.api.nvim_create_augroup("LSP", { clear = true })

return {
  {
    "hedyhli/outline.nvim",
    config = function()
      -- Example mapping to toggle outline
      vim.keymap.set("n", "<leader>o", "<cmd>OutlineOpen<CR>",
        { desc = "Open Outline" })

      require("outline").setup {
        -- Your setup opts here (leave empty to use defaults)
      }
    end,
  },

  {
    'lvimuser/lsp-inlayhints.nvim',
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      local inlayhints = require("lsp-inlayhints")
      inlayhints.setup({ enabled_at_startup = false })
      vim.api.nvim_create_autocmd("LspAttach", {
        group = lsp,
        callback = function(args)
          if not (args.data and args.data.client_id) then
            return
          end

          local bufnr = args.buf
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client.server_capabilities.inlayHintProvider then
            inlayhints.on_attach(client, bufnr, true)
            vim.keymap.set('n', '<space>lH', inlayhints.toggle, { noremap = true, silent = true, buffer = bufnr })
          end
        end,
      })
    end
  },

  -- {
  --   'SmiteshP/nvim-navic',
  --   config = function()
  --     vim.api.nvim_create_autocmd("LspAttach", {
  --       group = lsp,
  --       callback = function(args)
  --         if not (args.data and args.data.client_id) then
  --           return
  --         end
  -- 
  --         local bufnr = args.buf
  --         local client = vim.lsp.get_client_by_id(args.data.client_id)
  --         if client.server_capabilities.documentSymbolProvider then
  --           require("nvim-navic").attach(client, bufnr)
  --         end
  --       end,
  --     })
  --   end
  -- },

  {
    'j-hui/fidget.nvim',
    event = "LspAttach",
    tag = "legacy",
    config = function()
      require("fidget").setup({ window = { blend = 0 } })
      vim.cmd([[highlight! FidgetTask ctermfg=0 guifg=0]])
    end
  },

  {
    'neovim/nvim-lspconfig',
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      'hrsh7th/cmp-buffer',
      'hrsh7th/nvim-cmp',
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-vsnip',
      'hrsh7th/vim-vsnip',
      'williamboman/mason.nvim',
      'williamboman/mason-lspconfig.nvim',
    },
    config = function()
      vim.lsp.set_log_level("debug") -- for debug
      vim.api.nvim_create_autocmd("LspAttach", {
        group = lsp,
        callback = function(args)
          if not (args.data and args.data.client_id) then
            return
          end

          local bufnr = args.buf
          -- local client = vim.lsp.get_client_by_id(args.data.client_id)
          vim.api.nvim_buf_set_option(bufnr, 'omnifunc', 'v:lua.vim.lsp.omnifunc')

          local bufopts = { noremap = true, silent = true, buffer = bufnr }
          vim.keymap.set('n', '<space>lD', vim.lsp.buf.declaration, bufopts)
          vim.keymap.set('n', '<space>ld', vim.lsp.buf.definition, bufopts)
          vim.keymap.set('n', '<space>lh', vim.lsp.buf.hover, bufopts)
          vim.keymap.set('n', '<space>lt', vim.lsp.buf.type_definition, bufopts)
          vim.keymap.set('n', '<space>lr', vim.lsp.buf.references, bufopts)
          vim.keymap.set('n', '<space>lR', vim.lsp.buf.rename, bufopts)
          vim.keymap.set('n', '<space>la', vim.lsp.buf.code_action, bufopts)
          vim.keymap.set('n', '<space>lf', function() vim.lsp.buf.format { async = true } end, bufopts)
          vim.keymap.set('n', '<space>lI', vim.lsp.buf.implementation, bufopts)
          vim.keymap.set("n", "<space>le", vim.diagnostic.goto_next)
          vim.keymap.set("n", "<space>lE", vim.diagnostic.goto_prev)
        end,
      })
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup('lsp_attach_disable_ruff_hover', { clear = true }),
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client == nil then
            return
          end
          if client.name == 'ruff' then
            -- Disable hover in favor of Pyright
            client.server_capabilities.hoverProvider = false
          end
        end,
        desc = 'LSP: Disable hover capability from Ruff',
      })
      vim.api.nvim_create_autocmd("BufWritePre", {
        group = lsp,
        pattern = {"*.go"},
        callback = function()
          local params = vim.lsp.util.make_range_params()
          params.context = {only = {"source.organizeImports"}}
          -- buf_request_sync defaults to a 1000ms timeout. Depending on your
          -- machine and codebase, you may want longer. Add an additional
          -- argument after params if you find that you have to write the file
          -- twice for changes to be saved.
          -- E.g., vim.lsp.buf_request_sync(0, "textDocument/codeAction", params, 3000)
          local result = vim.lsp.buf_request_sync(0, "textDocument/codeAction", params)
          for cid, res in pairs(result or {}) do
            for _, r in pairs(res.result or {}) do
              if r.edit then
                local enc = (vim.lsp.get_client_by_id(cid) or {}).offset_encoding or "utf-16"
                vim.lsp.util.apply_workspace_edit(r.edit, enc)
              end
            end
          end
          vim.lsp.buf.format({async = false})
        end,
      })
      vim.api.nvim_create_autocmd("BufWritePre", {
        group = lsp,
        pattern = {"*.py" },
        callback = function()
          vim.lsp.buf.format({async = false})
        end,
      })

      local cmp = require("cmp")
      cmp.setup({
        snippet = {
          expand = function(args)
            vim.fn["vsnip#anonymous"](args.body) -- For `vsnip` users.
          end,
        },
        window = {
          completion = cmp.config.window.bordered(),
          documentation = cmp.config.window.bordered(),
        },
        mapping = cmp.mapping.preset.insert({
          ['<C-b>'] = cmp.mapping.scroll_docs( -4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          -- ['<C-Space>'] = cmp.mapping.complete(),
          ['<C-e>'] = cmp.mapping.abort(),
          ['<CR>'] = cmp.mapping.confirm({ select = false }),
          -- ['<Tab>'] = cmp.mapping.confirm({ select = true }),
        }),
        sources = cmp.config.sources({
          { name = 'nvim_lsp' },
          { name = 'buffer' },
        })
      })

      -- vim.lsp.with is deprecated; winborder applies to all floating windows
      vim.o.winborder = "rounded"

      -- local capabilities = vim.lsp.protocol.make_client_capabilities()
      local capabilities = require('cmp_nvim_lsp').default_capabilities()

      local settings = {
        ruff = {
        },
        pyright = {
          -- Using Ruff's import organizer
          disableOrganizeImports = true,
        },
        python = {
          venvPath = ".",
          pythonPath = "./.venv/bin/python",
          analysis = {
            extraPaths = {"."}
          }
        },
        ["rust-analyzer"] = {
          cargo = { allFeatures = true },
          checkOnSave = { allFeatures = true },
          diagnostics = {
            enable = true,
            disabled = {"unresolved-proc-macro"},
            enableExperimental = true,
          },
        },
        Lua = {
          runtime = { version = 'LuaJIT' },
          diagnostics = { globals = { 'vim' } },
          telemetry = { enable = false },
          hint = { enable = true },
          completion = { enable = true, showWord = "Disable" },
          workspace = { library = { os.getenv("VIMRUNTIME") } },
        },
        gopls = {
          hints = {
            assignVariableTypes = true,
            compositeLiteralFields = true,
            compositeLiteralTypes = true,
            constantValues = true,
            functionTypeParameters = true,
            parameterNames = true,
            rangeVariableTypes = true,
          },
        },
      }

      -- mason-lspconfig v2: setup_handlers was removed. Servers installed via
      -- mason are enabled automatically; shared config goes through vim.lsp.config.
      vim.lsp.config('*', {
        capabilities = capabilities,
        settings = settings,
      })

      require("mason").setup({ ui = { border = "rounded" } })
      require("mason-lspconfig").setup()
    end
  }
}