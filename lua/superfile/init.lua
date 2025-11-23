-- lua/superfile/init.lua
-- Superfile.nvim V2 — Full-featured Neovim-native file manager (single-file drop-in)
-- Features: floating UI, async dir scan, preview, multi-select, batch ops, bookmarks, git status, theming.

local api  = vim.api
local fn   = vim.fn
local uv   = vim.loop
local json = vim.fn.json_encode and vim.fn or nil

local M    = {
  state = {
    buf = nil,
    win = nil,
    preview_buf = nil,
    preview_win = nil,
    cwd = fn.getcwd(),
    items = {}, -- {name=, is_dir=, icon=, git=}
    marks = {}, -- marked file indices
    cursor = 1,
    cache = {},
    bookmarks = {},
  },
  cfg = {
    key = "<C-s>",
    float = { width = 0.8, height = 0.8, border = "rounded" },
    preview = true,
    git = true,
    use_devicons = true,
    trash_cmd = "trash-put", -- fallback to rm if not present
    session_file = fn.stdpath("data") .. "/superfile/session.json",
    cache_ttl = 5,           -- seconds
  },
}

-- util
local function use_devicons()
  return M.cfg.use_devicons and pcall(require, "nvim-web-devicons")
end

local function devicon_for(file)
  if not pcall(require, "nvim-web-devicons") then return "" end
  local icons = require("nvim-web-devicons")
  local name, ext = file:match("(.+)%.([^.]+)$")
  local icon = icons.get_icon(file, ext, { default = true })
  return icon or ""
end

local function path_join(a, b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

-- async scandir with caching (uses uv.fs_scandir)
local function async_scandir(path, callback)
  if M.state.cache[path] then
    local entry = M.state.cache[path]
    -- check TTL
    if (os.time() - (entry._time or 0)) < M.cfg.cache_ttl then
      callback(entry.items)
      return
    end
  end

  local items = {}
  local req, err = uv.fs_scandir(path)
  if not req then
    callback(items)
    return
  end

  while true do
    local name, t = uv.fs_scandir_next(req)
    if not name then break end
    table.insert(items, { name = name, is_dir = (t == "directory") })
  end
  -- lua/superfile/init.lua
  -- Superfile.nvim V2 — Full-featured Neovim-native file manager (single-file drop-in)
  -- Features: floating UI, async dir scan, preview, multi-select, batch ops, bookmarks, git status, theming.

  local api  = vim.api
  local fn   = vim.fn
  local uv   = vim.loop
  local json = vim.fn.json_encode and vim.fn or nil

  local M    = {
    state = {
      buf = nil,
      win = nil,
      preview_buf = nil,
      preview_win = nil,
      cwd = fn.getcwd(),
      items = {}, -- {name=, is_dir=, icon=, git=}
      marks = {}, -- marked file indices
      cursor = 1,
      cache = {},
      bookmarks = {},
    },
    cfg = {
      key = "<C-s>",
      float = { width = 0.8, height = 0.8, border = "rounded" },
      preview = true,
      git = true,
      use_devicons = true,
      trash_cmd = "trash-put", -- fallback to rm if not present
      session_file = fn.stdpath("data") .. "/superfile/session.json",
      cache_ttl = 5,         -- seconds
    },
  }

  -- util
  local function use_devicons()
    return M.cfg.use_devicons and pcall(require, "nvim-web-devicons")
  end

  local function devicon_for(file)
    if not pcall(require, "nvim-web-devicons") then return "" end
    local icons = require("nvim-web-devicons")
    local name, ext = file:match("(.+)%.([^.]+)$")
    local icon = icons.get_icon(file, ext, { default = true })
    return icon or ""
  end

  local function path_join(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
  end

  -- async scandir with caching (uses uv.fs_scandir)
  local function async_scandir(path, callback)
    if M.state.cache[path] then
      local entry = M.state.cache[path]
      -- check TTL
      if (os.time() - (entry._time or 0)) < M.cfg.cache_ttl then
        callback(entry.items)
        return
      end
    end

    local items = {}
    local req, err = uv.fs_scandir(path)
    if not req then
      callback(items)
      return
    end

    while true do
      local name, t = uv.fs_scandir_next(req)
      if not name then break end
      table.insert(items, { name = name, is_dir = (t == "directory") })
    end

    table.sort(items, function(a, b)
      if a.is_dir ~= b.is_dir then return a.is_dir end
      return a.name:lower() < b.name:lower()
    end)

    -- cache
    M.state.cache[path] = { items = items, _time = os.time() }

    callback(items)
  end

  -- get git status map for a directory using git porcelain
  local function git_status_map(dir, cb)
    if not M.cfg.git then
      cb({})
      return
    end
    if fn.executable("git") == 0 then
      cb({})
      return
    end

    local cmd = { "git", "-C", dir, "status", "--porcelain=v1", "--untracked-files=no" }
    local stdout = {}
    local handle
    local stdin = nil
    handle = uv.spawn("git",
      { args = { "-C", dir, "status", "--porcelain=v1", "--untracked-files=no" }, stdio = { nil, nil, nil } },
      function(code, sig)
        -- noop; we will call shell-based fallback
      end
    )
    -- simple fallback using systemlist (synchronous but acceptable for small repos)
    local ok, lines = pcall(fn.systemlist, table.concat(cmd, " "))
    local map = {}
    if ok and #lines > 0 then
      for _, ln in ipairs(lines) do
        local status = ln:sub(1, 2)
        local file = ln:sub(4)
        map[file] = status
      end
    end
    cb(map)
  end

  -- render buffer lines from M.state.items
  local function render()
    if not (M.state.buf and api.nvim_buf_is_valid(M.state.buf)) then return end
    local lines = {}
    for i, item in ipairs(M.state.items) do
      local icon = item.is_dir and "" or (M.cfg.use_devicons and devicon_for(item.name) or "󰈔")
      local git_marker = item.git and (" " .. item.git) or ""
      local mark = M.state.marks[i] and "[x] " or "    "
      table.insert(lines, string.format("%s%s %s%s", mark, icon, item.name, git_marker))
    end
    api.nvim_buf_set_option(M.state.buf, "modifiable", true)
    api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
    api.nvim_buf_set_option(M.state.buf, "modifiable", false)
    -- place cursor
    local win = M.state.win
    if win and api.nvim_win_is_valid(win) then
      api.nvim_win_set_cursor(win, { M.state.cursor, 0 })
    end
  end

  -- open preview pane (right side)
  local function open_preview(entry_name)
    if not M.cfg.preview then return end
    local fp = path_join(M.state.cwd, entry_name)
    local stat = uv.fs_stat(fp)
    if not stat or stat.type == "directory" then
      -- close preview if exists
      if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
        api.nvim_win_close(M.state.preview_win, true)
        M.state.preview_win = nil
        M.state.preview_buf = nil
      end
      return
    end

    -- create preview buffer and window
    if not (M.state.preview_buf and api.nvim_buf_is_valid(M.state.preview_buf)) then
      M.state.preview_buf = api.nvim_create_buf(false, true)
    end
    local cols = vim.o.columns
    local lines = vim.o.lines
    local width = math.floor(cols * 0.30)
    local height = math.floor(lines * 0.8)
    local row = math.floor((lines - height) / 2)
    local col = math.floor(cols * (1 - 0.30)) - 2

    if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
      api.nvim_win_set_buf(M.state.preview_win, M.state.preview_buf)
    else
      M.state.preview_win = api.nvim_open_win(M.state.preview_buf, false, {
        relative = "editor",
        style = "minimal",
        row = row,
        col = col,
        width = width,
        height = height,
        border = "rounded",
      })
    end

    api.nvim_buf_set_option(M.state.preview_buf, "buftype", "nofile")
    api.nvim_buf_set_option(M.state.preview_buf, "bufhidden", "wipe")
    api.nvim_buf_set_option(M.state.preview_buf, "modifiable", true)

    -- load file content (safely)
    local ok, lines = pcall(fn.readfile, fp)
    if ok then
      api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, lines)
    else
      api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, { "[Cannot preview file]" })
    end
    api.nvim_buf_set_option(M.state.preview_buf, "modifiable", false)
  end

  -- open file (edit) or cd into directory
  local function open_entry(idx)
    local item = M.state.items[idx]
    if not item then return end
    local full = path_join(M.state.cwd, item.name)
    if item.is_dir then
      -- change cwd
      M.state.cwd = fn.fnamemodify(full, ":p")
      M.state.cursor = 1
      M.state.items = {} -- clear while loading
      render()
      -- async load new dir
      async_scandir(M.state.cwd, function(items)
        -- enrich with git map
        git_status_map(M.state.cwd, function(gmap)
          for _, it in ipairs(items) do
            local git_marker = gmap and gmap[it.name]
            it.git = git_marker and (" " .. git_marker) or ""
          end
          M.state.items = items
          render()
        end)
      end)
      -- apply Neovim cwd
      vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
    else
      -- open file for editing, close explorer
      M.close()
      vim.cmd("edit " .. fn.fnameescape(full))
    end
  end

  -- go up directory
  local function go_up()
    local parent = fn.fnamemodify(M.state.cwd, ":h")
    if parent == M.state.cwd then return end
    M.state.cwd = parent
    M.state.cursor = 1
    M.state.items = {}
    render()
    async_scandir(M.state.cwd, function(items)
      git_status_map(M.state.cwd, function(gmap)
        for _, it in ipairs(items) do
          local git_marker = gmap and gmap[it.name]
          it.git = git_marker and (" " .. git_marker) or ""
        end
        M.state.items = items
        render()
      end)
    end)
    vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
  end

  -- mark/unmark (multi-select)
  local function toggle_mark(idx)
    if M.state.marks[idx] then
      M.state.marks[idx] = nil
    else
      M.state.marks[idx] = true
    end
    render()
  end

  -- get marked file paths
  local function get_marked_paths()
    local out = {}
    for idx, _ in pairs(M.state.marks) do
      if M.state.items[idx] then
        table.insert(out, path_join(M.state.cwd, M.state.items[idx].name))
      end
    end
    return out
  end

  -- copy marked files to dest (simple implementation)
  local function copy_marked(dest)
    local marked = get_marked_paths()
    if #marked == 0 then
      vim.notify("No files marked", vim.log.levels.INFO); return
    end
    for _, src in ipairs(marked) do
      local base = fn.fnamemodify(src, ":t")
      local dst = path_join(dest, base)
      local ok, err = pcall(fn.copy, src, dst)
      if not ok then
        -- fallback to system cp
        fn.system({ "cp", "-r", src, dst })
      end
    end
    vim.notify("Copied " .. #marked .. " files.", vim.log.levels.INFO)
  end

  -- delete marked (use trash if available)
  local function delete_marked()
    local marked = get_marked_paths()
    if #marked == 0 then
      vim.notify("No files marked", vim.log.levels.INFO); return
    end
    local trash = M.cfg.trash_cmd
    if fn.executable(trash) == 1 then
      for _, p in ipairs(marked) do
        fn.system({ trash, p })
      end
      vim.notify("Moved " .. #marked .. " to trash.", vim.log.levels.INFO)
    else
      -- confirm destructive delete
      local ok = fn.confirm("Permanently delete " .. #marked .. " files?", "&Yes\n&No") == 1
      if not ok then return end
      for _, p in ipairs(marked) do
        fn.delete(p, "rf")
      end
      vim.notify("Deleted " .. #marked .. " files.", vim.log.levels.INFO)
    end
    -- refresh directory
    async_scandir(M.state.cwd, function(items)
      M.state.items = items
      render()
    end)
  end

  -- move marked to destination
  local function move_marked(dest)
    local marked = get_marked_paths()
    if #marked == 0 then
      vim.notify("No files marked", vim.log.levels.INFO); return
    end
    for _, src in ipairs(marked) do
      local base = fn.fnamemodify(src, ":t")
      local dst = path_join(dest, base)
      local ok, err = pcall(fn.rename, src, dst)
      if not ok then
        fn.system({ "mv", src, dst })
      end
    end
    vim.notify("Moved " .. #marked .. " files.", vim.log.levels.INFO)
    async_scandir(M.state.cwd, function(items)
      M.state.items = items; render()
    end)
  end

  -- bookmarks: store in disk
  local function load_bookmarks()
    local file = M.cfg.session_file
    if fn.filereadable(file) == 1 then
      local ok, data = pcall(fn.readfile, file)
      if ok and data and #data > 0 then
        local ok2, tbl = pcall(fn.json_decode, table.concat(data, "\n"))
        if ok2 and type(tbl) == "table" and tbl.bookmarks then
          M.state.bookmarks = tbl.bookmarks
        end
      end
    end
  end

  local function save_session()
    local file = M.cfg.session_file
    local obj = { cwd = M.state.cwd, bookmarks = M.state.bookmarks }
    local ok, text = pcall(fn.json_encode, obj)
    if ok then
      local fh = io.open(file, "w")
      if fh then
        fh:write(text); fh:close()
      end
    end
  end

  local function add_bookmark()
    table.insert(M.state.bookmarks, M.state.cwd)
    save_session()
    vim.notify("Bookmarked: " .. M.state.cwd, vim.log.levels.INFO)
  end

  local function list_bookmarks()
    if #M.state.bookmarks == 0 then
      vim.notify("No bookmarks", vim.log.levels.INFO); return
    end
    local choices = {}
    for i, v in ipairs(M.state.bookmarks) do table.insert(choices, string.format("%d. %s", i, v)) end
    local pick = fn.inputlist(choices)
    if pick >= 1 and pick <= #M.state.bookmarks then
      M.state.cwd = M.state.bookmarks[pick]
      async_scandir(M.state.cwd, function(items)
        M.state.items = items; render()
      end)
      vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
    end
  end

  -- keymap handlers
  local function on_enter()
    local line = api.nvim_win_get_cursor(M.state.win)[1]
    open_entry(line)
  end

  local function on_preview()
    local line = api.nvim_win_get_cursor(M.state.win)[1]
    local item = M.state.items[line]
    if not item then return end
    if not item.is_dir then open_preview(item.name) end
  end

  local function on_up()
    go_up()
  end

  local function on_mark()
    local line = api.nvim_win_get_cursor(M.state.win)[1]
    toggle_mark(line)
  end

  -- Setup keymaps inside explorer buffer
  local function set_buffer_keymaps()
    local buf = M.state.buf
    local function nmap(lhs, rhs, desc)
      api.nvim_buf_set_keymap(buf, "n", lhs, rhs, { silent = true, noremap = true, nowait = true })
      if desc then -- store as extmap? Not necessary
      end
    end
    nmap("<CR>", ":lua require'superfile'._enter()<CR>")
    nmap("l", ":lua require'superfile'._enter()<CR>")
    nmap("h", ":lua require'superfile'._up()<CR>")
    nmap("<BS>", ":lua require'superfile'._up()<CR>")
    nmap("q", ":lua require'superfile'.close()<CR>")
    nmap("<Esc>", ":lua require'superfile'.close()<CR>")
    nmap(" ", ":lua require'superfile'._preview()<CR>")
    nmap("j", "j")
    nmap("k", "k")
    nmap("J", "5j")
    nmap("K", "5k")
    nmap("Tab", ":lua require'superfile'._mark()<CR>")
    nmap("y", ":lua require'superfile'._copy_prompt()<CR>")
    nmap("d", ":lua require'superfile'._delete_confirm()<CR>")
    nmap("m", ":lua require'superfile'._move_prompt()<CR>")
    nmap("b", ":lua require'superfile'._bookmark_add()<CR>")
    nmap("B", ":lua require'superfile'._bookmark_list()<CR>")
    nmap("/", ":lua require'superfile'.search()<CR>")
  end

  -- open floating window and initialize
  function M.open()
    if M.state.win and api.nvim_win_is_valid(M.state.win) then
      api.nvim_set_current_win(M.state.win)
      return
    end

    -- create buffer and window
    local cols = vim.o.columns
    local lines = vim.o.lines
    local w = math.floor((M.cfg.float.width or 0.8) * cols)
    local h = math.floor((M.cfg.float.height or 0.8) * lines)
    local row = math.floor((lines - h) / 2)
    local col = math.floor((cols - w) / 2)

    local buf = api.nvim_create_buf(false, true)
    local win = api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      row = row,
      col = col,
      width = w,
      height = h,
      border = M.cfg.float.border or "rounded",
    })

    M.state.buf = buf
    M.state.win = win
    M.state.cursor = 1
    M.state.marks = {}

    api.nvim_buf_set_option(buf, "buftype", "nofile")
    api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    api.nvim_buf_set_option(buf, "modifiable", false)
    api.nvim_buf_set_option(buf, "filetype", "superfile")

    set_buffer_keymaps()

    -- load bookmarks and session
    load_bookmarks()

    -- load directory
    async_scandir(M.state.cwd, function(items)
      git_status_map(M.state.cwd, function(gmap)
        for _, it in ipairs(items) do
          local key = it.name
          it.git = gmap and gmap[it.name] or nil
        end
        M.state.items = items
        render()
      end)
    end)
  end

  -- close
  function M.close()
    if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
      api.nvim_win_close(M.state.preview_win, true)
      M.state.preview_win = nil
    end
    if M.state.win and api.nvim_win_is_valid(M.state.win) then
      api.nvim_win_close(M.state.win, true)
      M.state.win = nil
    end
    M.state.buf = nil
    save_session()
  end

  -- public wrappers for wired keymaps
  M._enter = function() on_enter() end
  M._preview = function() on_preview() end
  M._up = function() on_up() end
  M._mark = function() on_mark() end
  M._bookmark_add = add_bookmark
  M._bookmark_list = list_bookmarks

  -- prompts for copy and move
  function M._copy_prompt()
    local dest = fn.input("Copy to (dir): ", M.state.cwd .. "/")
    if dest and #dest > 0 then copy_marked(dest) end
  end

  function M._move_prompt()
    local dest = fn.input("Move to (dir): ", M.state.cwd .. "/")
    if dest and #dest > 0 then move_marked(dest) end
  end

  function M._delete_confirm()
    local ok = fn.confirm("Delete marked files?", "&Yes\n&No") == 1
    if ok then delete_marked() end
  end

  -- search hook: if user provided opts.search_cmd, use it; otherwise quick filter
  function M.search()
    if M.cfg.search_cmd then
      -- fallback to external command (user provided), results expected as newline-separated paths
      local cmd = vim.split(M.cfg.search_cmd, " ")
      local pop = fn.input("Search> ")
      if #pop == 0 then return end
      -- naive sync call; advanced usage should integrate with telescope/fzf
      local fullcmd = table.concat(cmd, " ") .. " " .. fn.shellescape(pop)
      local ok, lines = pcall(fn.systemlist, fullcmd)
      if ok and #lines > 0 then
        -- jump to first result inside cwd if any
        local first = lines[1]
        -- if relative, make absolute
        local rel = fn.fnamemodify(first, ":p")
        local dir = fn.fnamemodify(rel, ":h")
        if dir and #dir > 0 then
          M.state.cwd = dir
          async_scandir(M.state.cwd, function(items)
            M.state.items = items; render()
          end)
        end
      else
        vim.notify("No results", vim.log.levels.INFO)
      end
    else
      local pat = fn.input("Filter> ")
      if #pat == 0 then
        async_scandir(M.state.cwd, function(items)
          M.state.items = items; render()
        end)
        return
      end
      local res = {}
      for _, it in ipairs(M.state.items) do
        if it.name:lower():find(pat:lower()) then table.insert(res, it) end
      end
      M.state.items = res
      render()
    end
  end

  -- setup
  function M.setup(opts)
    opts = opts or {}
    for k, v in pairs(opts) do M.cfg[k] = v end
    -- keymap to toggle
    if M.cfg.key then
      vim.keymap.set({ "n", "t" }, M.cfg.key, function()
        if M.state.win and api.nvim_win_is_valid(M.state.win) then
          M.close()
        else
          M.open()
        end
      end, { desc = "Toggle Superfile", silent = true })
    end
  end

  -- auto-restore session on require if available
  do
    -- try to load session silently
    local file = M.cfg.session_file
    if fn.filereadable(file) == 1 then
      local ok, data = pcall(fn.readfile, file)
      if ok and data and #data > 0 then
        local ok2, tbl = pcall(fn.json_decode, table.concat(data, "\n"))
        if ok2 and tbl and tbl.cwd then
          M.state.cwd = tbl.cwd
          M.state.bookmarks = tbl.bookmarks or {}
        end
      end
    end
  end

  return M
  table.sort(items, function(a, b)
    if a.is_dir ~= b.is_dir then return a.is_dir end
    return a.name:lower() < b.name:lower()
  end)

  -- cache
  M.state.cache[path] = { items = items, _time = os.time() }

  callback(items)
end

-- get git status map for a directory using git porcelain
local function git_status_map(dir, cb)
  if not M.cfg.git then
    cb({})
    return
  end
  if fn.executable("git") == 0 then
    cb({})
    return
  end

  local cmd = { "git", "-C", dir, "status", "--porcelain=v1", "--untracked-files=no" }
  local stdout = {}
  local handle
  local stdin = nil
  handle = uv.spawn("git",
    { args = { "-C", dir, "status", "--porcelain=v1", "--untracked-files=no" }, stdio = { nil, nil, nil } },
    function(code, sig)
      -- noop; we will call shell-based fallback
    end
  )
  -- simple fallback using systemlist (synchronous but acceptable for small repos)
  local ok, lines = pcall(fn.systemlist, table.concat(cmd, " "))
  local map = {}
  if ok and #lines > 0 then
    for _, ln in ipairs(lines) do
      local status = ln:sub(1, 2)
      local file = ln:sub(4)
      map[file] = status
    end
  end
  cb(map)
end

-- render buffer lines from M.state.items
local function render()
  if not (M.state.buf and api.nvim_buf_is_valid(M.state.buf)) then return end
  local lines = {}
  for i, item in ipairs(M.state.items) do
    local icon = item.is_dir and "" or (M.cfg.use_devicons and devicon_for(item.name) or "󰈔")
    local git_marker = item.git and (" " .. item.git) or ""
    local mark = M.state.marks[i] and "[x] " or "    "
    table.insert(lines, string.format("%s%s %s%s", mark, icon, item.name, git_marker))
  end
  api.nvim_buf_set_option(M.state.buf, "modifiable", true)
  api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
  api.nvim_buf_set_option(M.state.buf, "modifiable", false)
  -- place cursor
  local win = M.state.win
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_set_cursor(win, { M.state.cursor, 0 })
  end
end

-- open preview pane (right side)
local function open_preview(entry_name)
  if not M.cfg.preview then return end
  local fp = path_join(M.state.cwd, entry_name)
  local stat = uv.fs_stat(fp)
  if not stat or stat.type == "directory" then
    -- close preview if exists
    if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
      api.nvim_win_close(M.state.preview_win, true)
      M.state.preview_win = nil
      M.state.preview_buf = nil
    end
    return
  end

  -- create preview buffer and window
  if not (M.state.preview_buf and api.nvim_buf_is_valid(M.state.preview_buf)) then
    M.state.preview_buf = api.nvim_create_buf(false, true)
  end
  local cols = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(cols * 0.30)
  local height = math.floor(lines * 0.8)
  local row = math.floor((lines - height) / 2)
  local col = math.floor(cols * (1 - 0.30)) - 2

  if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
    api.nvim_win_set_buf(M.state.preview_win, M.state.preview_buf)
  else
    M.state.preview_win = api.nvim_open_win(M.state.preview_buf, false, {
      relative = "editor",
      style = "minimal",
      row = row,
      col = col,
      width = width,
      height = height,
      border = "rounded",
    })
  end

  api.nvim_buf_set_option(M.state.preview_buf, "buftype", "nofile")
  api.nvim_buf_set_option(M.state.preview_buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(M.state.preview_buf, "modifiable", true)

  -- load file content (safely)
  local ok, lines = pcall(fn.readfile, fp)
  if ok then
    api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, lines)
  else
    api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, { "[Cannot preview file]" })
  end
  api.nvim_buf_set_option(M.state.preview_buf, "modifiable", false)
end

-- open file (edit) or cd into directory
local function open_entry(idx)
  local item = M.state.items[idx]
  if not item then return end
  local full = path_join(M.state.cwd, item.name)
  if item.is_dir then
    -- change cwd
    M.state.cwd = fn.fnamemodify(full, ":p")
    M.state.cursor = 1
    M.state.items = {} -- clear while loading
    render()
    -- async load new dir
    async_scandir(M.state.cwd, function(items)
      -- enrich with git map
      git_status_map(M.state.cwd, function(gmap)
        for _, it in ipairs(items) do
          local git_marker = gmap and gmap[it.name]
          it.git = git_marker and (" " .. git_marker) or ""
        end
        M.state.items = items
        render()
      end)
    end)
    -- apply Neovim cwd
    vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
  else
    -- open file for editing, close explorer
    M.close()
    vim.cmd("edit " .. fn.fnameescape(full))
  end
end

-- go up directory
local function go_up()
  local parent = fn.fnamemodify(M.state.cwd, ":h")
  if parent == M.state.cwd then return end
  M.state.cwd = parent
  M.state.cursor = 1
  M.state.items = {}
  render()
  async_scandir(M.state.cwd, function(items)
    git_status_map(M.state.cwd, function(gmap)
      for _, it in ipairs(items) do
        local git_marker = gmap and gmap[it.name]
        it.git = git_marker and (" " .. git_marker) or ""
      end
      M.state.items = items
      render()
    end)
  end)
  vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
end

-- mark/unmark (multi-select)
local function toggle_mark(idx)
  if M.state.marks[idx] then
    M.state.marks[idx] = nil
  else
    M.state.marks[idx] = true
  end
  render()
end

-- get marked file paths
local function get_marked_paths()
  local out = {}
  for idx, _ in pairs(M.state.marks) do
    if M.state.items[idx] then
      table.insert(out, path_join(M.state.cwd, M.state.items[idx].name))
    end
  end
  return out
end

-- copy marked files to dest (simple implementation)
local function copy_marked(dest)
  local marked = get_marked_paths()
  if #marked == 0 then
    vim.notify("No files marked", vim.log.levels.INFO); return
  end
  for _, src in ipairs(marked) do
    local base = fn.fnamemodify(src, ":t")
    local dst = path_join(dest, base)
    local ok, err = pcall(fn.copy, src, dst)
    if not ok then
      -- fallback to system cp
      fn.system({ "cp", "-r", src, dst })
    end
  end
  vim.notify("Copied " .. #marked .. " files.", vim.log.levels.INFO)
end

-- delete marked (use trash if available)
local function delete_marked()
  local marked = get_marked_paths()
  if #marked == 0 then
    vim.notify("No files marked", vim.log.levels.INFO); return
  end
  local trash = M.cfg.trash_cmd
  if fn.executable(trash) == 1 then
    for _, p in ipairs(marked) do
      fn.system({ trash, p })
    end
    vim.notify("Moved " .. #marked .. " to trash.", vim.log.levels.INFO)
  else
    -- confirm destructive delete
    local ok = fn.confirm("Permanently delete " .. #marked .. " files?", "&Yes\n&No") == 1
    if not ok then return end
    for _, p in ipairs(marked) do
      fn.delete(p, "rf")
    end
    vim.notify("Deleted " .. #marked .. " files.", vim.log.levels.INFO)
  end
  -- refresh directory
  async_scandir(M.state.cwd, function(items)
    M.state.items = items
    render()
  end)
end

-- move marked to destination
local function move_marked(dest)
  local marked = get_marked_paths()
  if #marked == 0 then
    vim.notify("No files marked", vim.log.levels.INFO); return
  end
  for _, src in ipairs(marked) do
    local base = fn.fnamemodify(src, ":t")
    local dst = path_join(dest, base)
    local ok, err = pcall(fn.rename, src, dst)
    if not ok then
      fn.system({ "mv", src, dst })
    end
  end
  vim.notify("Moved " .. #marked .. " files.", vim.log.levels.INFO)
  async_scandir(M.state.cwd, function(items)
    M.state.items = items; render()
  end)
end

-- bookmarks: store in disk
local function load_bookmarks()
  local file = M.cfg.session_file
  if fn.filereadable(file) == 1 then
    local ok, data = pcall(fn.readfile, file)
    if ok and data and #data > 0 then
      local ok2, tbl = pcall(fn.json_decode, table.concat(data, "\n"))
      if ok2 and type(tbl) == "table" and tbl.bookmarks then
        M.state.bookmarks = tbl.bookmarks
      end
    end
  end
end

local function save_session()
  local file = M.cfg.session_file
  local obj = { cwd = M.state.cwd, bookmarks = M.state.bookmarks }
  local ok, text = pcall(fn.json_encode, obj)
  if ok then
    local fh = io.open(file, "w")
    if fh then
      fh:write(text); fh:close()
    end
  end
end

local function add_bookmark()
  table.insert(M.state.bookmarks, M.state.cwd)
  save_session()
  vim.notify("Bookmarked: " .. M.state.cwd, vim.log.levels.INFO)
end

local function list_bookmarks()
  if #M.state.bookmarks == 0 then
    vim.notify("No bookmarks", vim.log.levels.INFO); return
  end
  local choices = {}
  for i, v in ipairs(M.state.bookmarks) do table.insert(choices, string.format("%d. %s", i, v)) end
  local pick = fn.inputlist(choices)
  if pick >= 1 and pick <= #M.state.bookmarks then
    M.state.cwd = M.state.bookmarks[pick]
    async_scandir(M.state.cwd, function(items)
      M.state.items = items; render()
    end)
    vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
  end
end

-- keymap handlers
local function on_enter()
  local line = api.nvim_win_get_cursor(M.state.win)[1]
  open_entry(line)
end

local function on_preview()
  local line = api.nvim_win_get_cursor(M.state.win)[1]
  local item = M.state.items[line]
  if not item then return end
  if not item.is_dir then open_preview(item.name) end
end

local function on_up()
  go_up()
end

local function on_mark()
  local line = api.nvim_win_get_cursor(M.state.win)[1]
  toggle_mark(line)
end

-- Setup keymaps inside explorer buffer
local function set_buffer_keymaps()
  local buf = M.state.buf
  local function nmap(lhs, rhs, desc)
    api.nvim_buf_set_keymap(buf, "n", lhs, rhs, { silent = true, noremap = true, nowait = true })
    if desc then -- store as extmap? Not necessary
    end
  end
  nmap("<CR>", ":lua require'superfile'._enter()<CR>")
  nmap("l", ":lua require'superfile'._enter()<CR>")
  nmap("h", ":lua require'superfile'._up()<CR>")
  nmap("<BS>", ":lua require'superfile'._up()<CR>")
  nmap("q", ":lua require'superfile'.close()<CR>")
  nmap("<Esc>", ":lua require'superfile'.close()<CR>")
  nmap(" ", ":lua require'superfile'._preview()<CR>")
  nmap("j", "j")
  nmap("k", "k")
  nmap("J", "5j")
  nmap("K", "5k")
  nmap("Tab", ":lua require'superfile'._mark()<CR>")
  nmap("y", ":lua require'superfile'._copy_prompt()<CR>")
  nmap("d", ":lua require'superfile'._delete_confirm()<CR>")
  nmap("m", ":lua require'superfile'._move_prompt()<CR>")
  nmap("b", ":lua require'superfile'._bookmark_add()<CR>")
  nmap("B", ":lua require'superfile'._bookmark_list()<CR>")
  nmap("/", ":lua require'superfile'.search()<CR>")
end

-- open floating window and initialize
function M.open()
  if M.state.win and api.nvim_win_is_valid(M.state.win) then
    api.nvim_set_current_win(M.state.win)
    return
  end

  -- create buffer and window
  local cols = vim.o.columns
  local lines = vim.o.lines
  local w = math.floor((M.cfg.float.width or 0.8) * cols)
  local h = math.floor((M.cfg.float.height or 0.8) * lines)
  local row = math.floor((lines - h) / 2)
  local col = math.floor((cols - w) / 2)

  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    row = row,
    col = col,
    width = w,
    height = h,
    border = M.cfg.float.border or "rounded",
  })

  M.state.buf = buf
  M.state.win = win
  M.state.cursor = 1
  M.state.marks = {}

  api.nvim_buf_set_option(buf, "buftype", "nofile")
  api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(buf, "modifiable", false)
  api.nvim_buf_set_option(buf, "filetype", "superfile")

  set_buffer_keymaps()

  -- load bookmarks and session
  load_bookmarks()

  -- load directory
  async_scandir(M.state.cwd, function(items)
    git_status_map(M.state.cwd, function(gmap)
      for _, it in ipairs(items) do
        local key = it.name
        it.git = gmap and gmap[it.name] or nil
      end
      M.state.items = items
      render()
    end)
  end)
end

-- close
function M.close()
  if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
    api.nvim_win_close(M.state.preview_win, true)
    M.state.preview_win = nil
  end
  if M.state.win and api.nvim_win_is_valid(M.state.win) then
    api.nvim_win_close(M.state.win, true)
    M.state.win = nil
  end
  M.state.buf = nil
  save_session()
end

-- public wrappers for wired keymaps
M._enter = function() on_enter() end
M._preview = function() on_preview() end
M._up = function() on_up() end
M._mark = function() on_mark() end
M._bookmark_add = add_bookmark
M._bookmark_list = list_bookmarks

-- prompts for copy and move
function M._copy_prompt()
  local dest = fn.input("Copy to (dir): ", M.state.cwd .. "/")
  if dest and #dest > 0 then copy_marked(dest) end
end

function M._move_prompt()
  local dest = fn.input("Move to (dir): ", M.state.cwd .. "/")
  if dest and #dest > 0 then move_marked(dest) end
end

function M._delete_confirm()
  local ok = fn.confirm("Delete marked files?", "&Yes\n&No") == 1
  if ok then delete_marked() end
end

-- search hook: if user provided opts.search_cmd, use it; otherwise quick filter
function M.search()
  if M.cfg.search_cmd then
    -- fallback to external command (user provided), results expected as newline-separated paths
    local cmd = vim.split(M.cfg.search_cmd, " ")
    local pop = fn.input("Search> ")
    if #pop == 0 then return end
    -- naive sync call; advanced usage should integrate with telescope/fzf
    local fullcmd = table.concat(cmd, " ") .. " " .. fn.shellescape(pop)
    local ok, lines = pcall(fn.systemlist, fullcmd)
    if ok and #lines > 0 then
      -- jump to first result inside cwd if any
      local first = lines[1]
      -- if relative, make absolute
      local rel = fn.fnamemodify(first, ":p")
      local dir = fn.fnamemodify(rel, ":h")
      if dir and #dir > 0 then
        M.state.cwd = dir
        async_scandir(M.state.cwd, function(items)
          M.state.items = items; render()
        end)
      end
    else
      vim.notify("No results", vim.log.levels.INFO)
    end
  else
    local pat = fn.input("Filter> ")
    if #pat == 0 then
      async_scandir(M.state.cwd, function(items)
        M.state.items = items; render()
      end)
      return
    end
    local res = {}
    for _, it in ipairs(M.state.items) do
      if it.name:lower():find(pat:lower()) then table.insert(res, it) end
    end
    M.state.items = res
    render()
  end
end

-- setup
function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do M.cfg[k] = v end
  -- keymap to toggle
  if M.cfg.key then
    vim.keymap.set({ "n", "t" }, M.cfg.key, function()
      if M.state.win and api.nvim_win_is_valid(M.state.win) then
        M.close()
      else
        M.open()
      end
    end, { desc = "Toggle Superfile", silent = true })
  end
end

-- auto-restore session on require if available
do
  -- try to load session silently
  local file = M.cfg.session_file
  if fn.filereadable(file) == 1 then
    local ok, data = pcall(fn.readfile, file)
    if ok and data and #data > 0 then
      local ok2, tbl = pcall(fn.json_decode, table.concat(data, "\n"))
      if ok2 and tbl and tbl.cwd then
        M.state.cwd = tbl.cwd
        M.state.bookmarks = tbl.bookmarks or {}
      end
    end
  end
end

return M
