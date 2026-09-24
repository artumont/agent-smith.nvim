return function(t)
  local Float = require("agent-smith.ui.float")

  t.describe("float.geometry", function()
    t.it("centres a float in the editor", function()
      -- Both surfaces are centred rather than corner-pinned: the user is reading
      -- or typing in them, so they are the thing in front of the eye. The corner
      -- one is ui/panel.lua, and that is the status display's job.
      local geometry = Float.geometry(100, 30, 64, 4)
      t.eq(geometry.width, 64)
      t.eq(geometry.height, 4)
      t.eq(geometry.col, 18)
      -- One row above the geometric centre, because the border takes a row.
      t.eq(geometry.row, 12)
    end)

    t.it("clamps to a small editor instead of overflowing it", function()
      -- A float wider than its editor is an error rather than a cosmetic problem:
      -- Neovim refuses to open it, so the size has to be reduced here.
      local geometry = Float.geometry(50, 10, 64, 24)
      t.eq(geometry.width, 46)
      t.eq(geometry.height, 6)
      t.ok(geometry.col + geometry.width + 1 <= 50)
      t.ok(geometry.row + geometry.height + 1 <= 10)
    end)

    t.it("keeps a floor on the width and never goes negative", function()
      -- Clamped, centred, and still on screen when the editor is absurd.
      local geometry = Float.geometry(10, 3, 64, 4)
      t.eq(geometry.width, Float.MIN_WIDTH)
      t.eq(geometry.height, 1)
      t.eq(geometry.row, 0)
      t.eq(geometry.col, 0)
    end)

    t.it("centres what it clamped, not what it was asked for", function()
      -- Clamping after centring would place the window off-centre.
      local geometry = Float.geometry(80, 30, 400, 400)
      t.eq(geometry.col, math.floor((80 - geometry.width) / 2))
      t.eq(geometry.row, math.floor((30 - geometry.height) / 2) - 1)
    end)

    t.it("falls back to its own size when asked for none", function()
      local geometry = Float.geometry(100, 30)
      t.eq(geometry.width, Float.DEFAULT_WIDTH)
      t.eq(geometry.height, Float.DEFAULT_HEIGHT)
    end)
  end)

  t.describe("float.open", function()
    t.it("opens an entered, rounded float with a title and a border hint", function()
      local buffer = vim.api.nvim_create_buf(false, true)
      local footer = { { " q ", "Keyword" } }
      local window = Float.open({ buffer = buffer, title = " agent-smith test ", footer = footer })

      local config = vim.api.nvim_win_get_config(window)
      t.eq(config.relative, "editor")
      t.eq(config.style, "minimal")
      -- Neovim resolves a named border into its characters, so this is the box.
      t.eq(config.border[1], "╭")
      t.eq(config.title[1][1], " agent-smith test ")
      t.eq(config.title_pos, "left")
      t.eq(config.footer, footer)
      t.eq(config.footer_pos, "center")
      t.eq(config.width, Float.DEFAULT_WIDTH)
      t.eq(vim.api.nvim_win_get_buf(window), buffer)
      t.eq(vim.api.nvim_get_current_win(), window, "entered, so the user can scroll it")

      vim.api.nvim_win_close(window, true)
      vim.api.nvim_buf_delete(buffer, { force = true })
    end)

    t.it("leaves the footer fields out when there is no hint", function()
      -- `footer_pos` without `footer` is refused outright, so this is not
      -- cosmetic: sending a default footer_pos made every hint-less float fail to
      -- open.
      local buffer = vim.api.nvim_create_buf(false, true)
      local window = Float.open({ buffer = buffer })
      local config = vim.api.nvim_win_get_config(window)
      t.not_ok(config.footer and #config.footer > 0, "no footer")
      t.eq(config.footer_pos, nil, "and no position for one")

      vim.api.nvim_win_close(window, true)
      vim.api.nvim_buf_delete(buffer, { force = true })
    end)

    t.it("opens exactly where it is told to, for a docked float", function()
      -- A docked float must not be re-centred or clamped: the caller computed the
      -- rect from the window it docks inside, and this is the seam the monitor's
      -- steer input uses.
      local buffer = vim.api.nvim_create_buf(false, true)
      local at = { row = 7, col = 3, width = 40, height = 2 }
      local window = Float.open({
        buffer = buffer,
        at = at,
        border = { "", "─", "", "", "", "", "", "" },
      })

      local config = vim.api.nvim_win_get_config(window)
      t.eq({ config.row, config.col, config.width, config.height }, { 7, 3, 40, 2 })
      t.eq(config.border[2], "─", "only the top edge is drawn")
      t.eq(config.border[1], "", "and no corner beside it")

      vim.api.nvim_win_close(window, true)
      vim.api.nvim_buf_delete(buffer, { force = true })
    end)

    t.it("raises when it was not given a buffer", function()
      t.raises(function()
        Float.open({})
      end, "needs a buffer")
    end)
  end)

  t.describe("float.place", function()
    t.it("moves and resizes an open float to the current geometry", function()
      local buffer = vim.api.nvim_create_buf(false, true)
      local window = Float.open({ buffer = buffer, width = 40, height = 4 })

      t.eq(Float.place(window, 60, 10), true)
      local config = vim.api.nvim_win_get_config(window)
      t.eq(config.width, 60)
      t.eq(config.height, 10)

      vim.api.nvim_win_close(window, true)
      vim.api.nvim_buf_delete(buffer, { force = true })
    end)

    t.it("leaves the title and the border hint alone", function()
      -- The redraw that follows a resize re-places the window, so losing either
      -- would mean losing them on every terminal resize.
      local buffer = vim.api.nvim_create_buf(false, true)
      local footer = { { " q ", "Keyword" } }
      local window = Float.open({ buffer = buffer, title = " t ", footer = footer })

      Float.place(window, 50, 8)
      local config = vim.api.nvim_win_get_config(window)
      t.eq(config.title[1][1], " t ")
      t.eq(config.footer, footer)

      vim.api.nvim_win_close(window, true)
      vim.api.nvim_buf_delete(buffer, { force = true })
    end)

    t.it("reports failure rather than raising for a window that is gone", function()
      -- `nvim_win_set_config(nil)` would raise "Invalid 'win'", so every caller
      -- would have to guard before calling. Returning false is the cheaper
      -- contract, and every caller ignores the answer anyway.
      t.eq(Float.place(nil, 40, 4), false)
      t.eq(Float.place(9999, 40, 4), false)
    end)
  end)
end
