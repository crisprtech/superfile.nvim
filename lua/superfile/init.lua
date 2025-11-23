-- lua/superfile/init.lua
-- Superfile.nvim V2 — Full-featured Neovim-native file manager

local api = vim.api
local fn = vim.fn
local uv = vim.loop

local M = {
  state = {
    buf = nil,
    win = nil,
    preview_buf = nil,
    preview_win = nil,
    cwd = fn.getcwd(),
    items = {},
    marks = {},
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
    trash_cmd = "trash-put",
    session_file = fn.stdpath("data") .. "/superfile/session.json",
    cache_ttl = 5,
  },
}

-- Utilities
local function devicon_for(file)
  local ok, icons = pcall(require, "nvim-web-devicons")
  if not ok then return "" end
  local name, ext = file:match("(.+)%.([^.]+)$")
  return icons.get_icon(file, ext, { default = true }) or ""
end

local function path_join(a, b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

-- Async scandir with cache
local function async_scandir(path, callback)
  if M.state.cache[path] then
    local entry = M.state.cache[path]
    if (os.time() - (entry._time or 0)) < M.cfg.cache_ttl then
      callback(entry.items)
      return
    end
  end

  local items = {}
  local req, err = uv.fs_scandir(path)
  if req then
    while true do
      local name, t = uv.fs_scandir_next(req)
      if not name then break end
      table.insert(items, { name = name, is_dir = (t == "directory") })
    end
  end

  table.sort(items, function(a, b)
    if a.is_dir ~= b.is_dir then return a.is_dir end
    return a.name:lower() < b.name:lower()
  end)

  M.state.cache[path] = { items = items, _time = os.time() }
  callback(items)
end

-- Git status map
local function git_status_map(dir, cb)
  if not M.cfg.git or fn.executable("git") == 0 then
    cb({})
    return
  end
  local ok, lines = pcall(fn.systemlist,
    "git -C " .. fn.fnameescape(dir) .. " status --porcelain=v1 --untracked-files=no")
  local map = {}
  if ok then
    for _, ln in ipairs(lines) do
      local status = ln:sub(1, 2)
      local file = ln:sub(4)
      map[file] = status
    end
  end
  cb(map)
end

-- Render explorer buffer
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
  if M.state.win and api.nvim_win_is_valid(M.state.win) then
    api.nvim_win_set_cursor(M.state.win, { M.state.cursor, 0 })
  end
end

-- Preview pane
local function open_preview(entry_name)
  if not M.cfg.preview then return end
  local fp = path_join(M.state.cwd, entry_name)
  local stat = uv.fs_stat(fp)
  if not stat or stat.type == "directory" then
    if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
      api.nvim_win_close(M.state.preview_win, true)
      M.state.preview_win = nil
      M.state.preview_buf = nil
    end
    return
  end

  if not (M.state.preview_buf and api.nvim_buf_is_valid(M.state.preview_buf)) then
    M.state.preview_buf = api.nvim_create_buf(false, true)
  end
  local cols, lines = vim.o.columns, vim.o.lines
  local width, height = math.floor(cols * 0.3), math.floor(lines * 0.8)
  local row, col = math.floor((lines - height) / 2), math.floor(cols * 0.7) - 2

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
  local ok, content = pcall(fn.readfile, fp)
  api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, ok and content or { "[Cannot preview file]" })
  api.nvim_buf_set_option(M.state.preview_buf, "modifiable", false)
end

-- Open entry
local function open_entry(idx)
  local item = M.state.items[idx]
  if not item then return end
  local full = path_join(M.state.cwd, item.name)
  if item.is_dir then
    M.state.cwd = fn.fnamemodify(full, ":p")
    M.state.cursor = 1
    M.state.items = {}
    render()
    async_scandir(M.state.cwd, function(items)
      git_status_map(M.state.cwd, function(gmap)
        for _, it in ipairs(items) do
          it.git = gmap[it.name] and (" " .. gmap[it.name]) or ""
        end
        M.state.items = items
        render()
      end)
    end)
    vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
  else
    M.close()
    vim.cmd("edit " .. fn.fnameescape(full))
  end
end

-- Go up
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
        it.git = gmap[it.name] and (" " .. gmap[it.name]) or ""
      end
      M.state.items = items
      render()
    end)
  end)
  vim.cmd("lcd " .. fn.fnameescape(M.state.cwd))
end

-- Marks
local function toggle_mark(idx)
  M.state.marks[idx] = not M.state.marks[idx] and true or nil
  render()
end

local function get_marked_paths()
  local out = {}
  for idx, _ in pairs(M.state.marks) do
    if M.state.items[idx] then table.insert(out, path_join(M.state.cwd, M.state.items[idx].name)) end
  end
  return out
end

-- File operations
local function copy_marked(dest)
  local marked = get_marked_paths()
  if #marked == 0 then
    vim.notify("No files marked", vim.log.levels.INFO)
    return
  end
  for _, src in ipairs(marked) do
    local dst = path_join(dest, fn.fnamemodify(src, ":t"))
    local ok = pcall(fn.copy, src, dst)
    if not ok then fn.system({ "cp", "-r", src, dst }) end
  end
  vim.notify("Copied " .. #marked .. " files.", vim.log.levels.INFO)
end

local function move_marked(dest)
  local marked = get_marked_paths()
  if #marked == 0 then
    vim.notify("No files marked", vim.log.levels.INFO)
    return
  end
  for _, src in ipairs(marked) do
    local dst = path_join(dest, fn.fnamemodify(src, ":t"))
    local ok = pcall(fn.rename, src, dst)
    if not ok then fn.system({ "mv", src, dst }) end
  end
  vim.notify("Moved " .. #marked .. " files.", vim.log.levels.INFO)
  async_scandir(M.state.cwd, function(items)
    M.state.items = items; render()
  end)
end

local function delete_marked()
  local marked = get_marked_paths()
  if #marked == 0 then
    vim.notify("No files marked", vim.log.levels.INFO)
    return
  end
  local trash = M.cfg.trash_cmd
  if fn.executable(trash) == 1 then
    for _, p in ipairs(marked) do fn.system({ trash, p }) end
    vim.notify("Moved " .. #marked .. " to trash.", vim.log.levels.INFO)
  else
    if fn.confirm("Permanently delete " .. #marked .. " files?", "&Yes\n&No") == 1 then
      for _, p in ipairs(marked) do fn.delete(p, "rf") end
      vim.notify("Deleted " .. #marked .. " files.", vim.log.levels.INFO)
    end
  end
  async_scandir(M.state.cwd, function(items)
    M.state.items = items; render()
  end)
end

-- Bookmarks
local function save_session()
  local file = M.cfg.session_file
  local obj = { cwd = M.state.cwd, bookmarks = M.state.bookmarks }
  local ok, text = pcall(fn.json_encode, obj)
  if ok then
    local fh = io.open(file, "w"); if fh then
      fh:write(text); fh:close()
    end
  end
end

local function load_bookmarks()
  local file = M.cfg.session_file
  if fn.filereadable(file) == 1 then
    local ok, data = pcall(fn.readfile, file)
    if ok and data then
      local ok2, tbl = pcall(fn.json_decode, table.concat(data, "\n"))
      if ok2 and tbl and tbl.bookmarks then M.state.bookmarks = tbl.bookmarks end
    end
  end
end

local function add_bookmark()
  table.insert(M.state.bookmarks, M.state.cwd); save_session(); vim.notify("Bookmarked: " .. M.state.cwd,
    vim.log.levels.INFO)
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

-- Key handlers
local function on_enter() open_entry(api.nvim_win_get_cursor(M.state.win)[1]) end
local function on_preview()
  local item = M.state.items[api.nvim_win_get_cursor(M.state.win)[1]]; if item and not item.is_dir then open_preview(
    item.name) end
end
local function on_up() go_up() end
local function on_mark() toggle_mark(api.nvim_win_get_cursor(M.state.win)[1]) end

-- Keymaps
local function set_buffer_keymaps()
  local buf = M.state.buf
  local function nmap(lhs, rhs) api.nvim_buf_set_keymap(buf, "n", lhs, rhs,
      { silent = true, noremap = true, nowait = true }) end
  nmap("<CR>", ":lua require'superfile'._enter()<CR>")
  nmap("l", ":lua require'superfile'._enter()<CR>")
  nmap("h", ":lua require'superfile'._up()<CR>")
  nmap("<BS>", ":lua require'superfile'._up()<CR>")
  nmap("q", ":lua require'superfile'.close()<CR>")
  nmap("<Esc>", ":lua require'superfile'.close()<CR>")
  nmap(" ", ":lua require'superfile'._preview()<CR>")
  nmap("Tab", ":lua require'superfile'._mark()<CR>")
  nmap("y", ":lua require'superfile'._copy_prompt()<CR>")
  nmap("d", ":lua require'superfile'._delete_confirm()<CR>")
  nmap("m", ":lua require'superfile'._move_prompt()<CR>")
  nmap("b", ":lua require'superfile'._bookmark_add()<CR>")
  nmap("B", ":lua require'superfile'._bookmark_list()<CR>")
end

-- Public interface
function M.open()
  if M.state.win and api.nvim_win_is_valid(M.state.win) then
    api.nvim_set_current_win(M.state.win); return
  end
  local cols, lines = vim.o.columns, vim.o.lines
  local w, h = math.floor(M.cfg.float.width * cols), math.floor(M.cfg.float.height * lines)
  local row, col = math.floor((lines - h) / 2), math.floor((cols - w) / 2)
  M.state.buf = api.nvim_create_buf(false, true)
  M.state.win = api.nvim_open_win(M.state.buf, true,
    { relative = "editor", style = "minimal", row = row, col = col, width = w, height = h, border = M.cfg.float.border })
  M.state.cursor, M.state.marks = 1, {}
  api.nvim_buf_set_option(M.state.buf, "buftype", "nofile")
  api.nvim_buf_set_option(M.state.buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(M.state.buf, "modifiable", false)
  api.nvim_buf_set_option(M.state.buf, "filetype", "superfile")
  set_buffer_keymaps()
  load_bookmarks()
  async_scandir(M.state.cwd, function(items)
    git_status_map(M.state.cwd, function(gmap)
      for _, it in ipairs(items) do it.git = gmap[it.name] and (" " .. gmap[it.name]) or "" end
      M.state.items = items; render()
    end)
  end)
end

function M.close()
  if M.state.preview_win and api.nvim_win_is_valid(M.state.preview_win) then
    api.nvim_win_close(M.state.preview_win, true); M.state.preview_win = nil
  end
  if M.state.win and api.nvim_win_is_valid(M.state.win) then
    api.nvim_win_close(M.state.win, true); M.state.win = nil
  end
  M.state.buf = nil
  save_session()
end

M._enter = on_enter
M._preview = on_preview
M._up = on_up
M._mark = on_mark
M._bookmark_add = add_bookmark
M._bookmark_list = list_bookmarks

function M._copy_prompt()
  local dest = fn.input("Copy to (dir): ", M.state.cwd .. "/")
  if dest and #dest > 0 then copy_marked(dest) end
end

function M._move_prompt()
  local dest = fn.input("Move to (dir): ", M.state.cwd .. "/")
  if dest and #dest > 0 then move_marked(dest) end
end

function M._delete_confirm()
  if fn.confirm("Delete marked files?", "&Yes\n&No") == 1 then delete_marked() end
end

function M.search()
  local pat = fn.input("Filter> ")
  if #pat == 0 then
    async_scandir(M.state.cwd, function(items)
      M.state.items = items; render()
    end); return
  end
  local res = {}
  for _, it in ipairs(M.state.items) do if it.name:lower():find(pat:lower()) then table.insert(res, it) end end
  M.state.items = res; render()
end

function M.setup(opts)
  opts = opts or {}
  for k, v in pairs(opts) do M.cfg[k] = v end
  if M.cfg.key then
    vim.keymap.set({ "n", "t" }, M.cfg.key, function()
      if M.state.win and api.nvim_win_is_valid(M.state.win) then M.close() else M.open() end
    end, { desc = "Toggle Superfile", silent = true })
  end
end

-- Auto-restore session
do
  local file = M.cfg.session_file
  if fn.filereadable(file) == 1 then
    local ok, data = pcall(fn.readfile, file)
    if ok and data then
      local ok2, tbl = pcall(fn.json_decode, table.concat(data, "\n"))
      if ok2 and tbl and tbl.cwd then
        M.state.cwd = tbl.cwd
        M.state.bookmarks = tbl.bookmarks or {}
      end
    end
  end
end

return M
