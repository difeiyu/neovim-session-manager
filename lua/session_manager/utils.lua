local config = require('session_manager.config')
local scandir = require('plenary.scandir')
local Path = require('plenary.path')
local utils = { is_session = false }

local function close_unused_lsp_clients()
  local bufs = vim.api.nvim_list_bufs()
  local lsp_clients = vim.lsp.get_active_clients()
  for _, client in pairs(lsp_clients) do
    if client.config.root_dir ~= vim.loop.cwd() then
      local active = false
      for _, bufnr in pairs(bufs) do
        if client.attached_buffers[bufnr] ~= nil then
          active = true
          break
        end
      end
      if active == false then
        vim.lsp.stop_client(client.id)
      end
    end
  end
end

---@param dir table:  Session directory
---@return table: named Session directory
function utils.addsessionname(dir)
  local sessionname = vim.api.nvim_get_var("SessionName")
  if sessionname == '' then
    vim.ui.input({ prompt = "Enter named this Session: " }, function(input)
      sessionname = input
    end)
    if dir:joinpath(sessionname):exists() then
      vim.ui.input({ prompt = " already exists!\nconfirm to replace input(y):" },
        function(input)
          if input ~= 'y' then
            sessionname = ''..os.time()
          end
        end)
    end
    vim.api.nvim_set_var("SessionName", sessionname)
  end
  dir = dir:joinpath(sessionname)
  dir.sessionname = sessionname
  return dir
end

---@param dir table:Session directory
---@return table: divide name and Session directory
function utils.split_sessionname(dir)
  local list_dir = dir:_split()
  local sessionname = table.remove(list_dir)
  dir = Path:new(list_dir)
  dir.sessionname = sessionname
  return dir
end

--- A small wrapper around `vim.notify` that adds plugin title.
---@param msg string
---@param log_level number
function utils.notify(msg, log_level) vim.notify(msg, log_level, { title = 'Session manager' }) end

---@return string?: Last used session filename.
function utils.get_last_session_filename()
  if not Path:new(config.sessions_dir):is_dir() then
    utils.notify('Sessions list is empty', vim.log.levels.INFO)
    return nil
  end

  local most_recent_filename = nil
  local most_recent_timestamp = 0
  local cwd = vim.loop.cwd()
  local now_session_filename = config.defaults.dir_to_session_filename(cwd)
  now_session_filename = now_session_filename:joinpath(vim.api.nvim_get_var("SessionName"))
  for _, session_filename in ipairs(scandir.scan_dir(tostring(config.sessions_dir))) do
    if config.session_filename_to_dir(session_filename):is_dir() then
      local timestamp = vim.fn.getftime(session_filename)
      if most_recent_timestamp < timestamp then
        if now_session_filename.filename ~= session_filename then
          most_recent_timestamp = timestamp
          most_recent_filename = session_filename
        end
      end
    end
  end
  return most_recent_filename
end

function utils.new_session(discard_current)
  if not discard_current then
    -- Ask to save files in current session before closing them.
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(buffer, 'modified') then
        local choice = vim.fn.confirm('The files in the current session have changed. Save changes?',
          '&Yes\n&No\n&Cancel')
        if choice == 3 or choice == 0 then
          return -- Cancel.
        elseif choice == 1 then
          vim.api.nvim_command('silent wall')
        end
        break
      end
    end
  end

  local current_buffer = vim.api.nvim_get_current_buf()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and buffer ~= current_buffer then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  vim.api.nvim_buf_delete(current_buffer, { force = true })
  vim.api.nvim_set_var("SessionName", '')
end

---@param filename string
---@param discard_current boolean?
function utils.load_session(filename, discard_current)
  if not discard_current then
    -- Ask to save files in current session before closing them.
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(buffer, 'modified') then
        local choice = vim.fn.confirm('The files in the current session have changed. Save changes?',
          '&Yes\n&No\n&Cancel')
        if choice == 3 or choice == 0 then
          return -- Cancel.
        elseif choice == 1 then
          vim.api.nvim_command('silent wall')
        end
        break
      end
    end
  end

  -- Scedule buffers cleanup to avoid callback issues and source the session.
  vim.schedule(function()
    -- Delete all buffers first except the current one to avoid entering buffers scheduled for deletion.
    local current_buffer = vim.api.nvim_get_current_buf()
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buffer) and buffer ~= current_buffer then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
    end
    vim.api.nvim_buf_delete(current_buffer, { force = true })

    local swapfile = vim.o.swapfile
    vim.o.swapfile = false
    utils.is_session = true
    local pathtable = Path:new(filename):_split()
    local sessionname = table.remove(pathtable)
    local shadafile = Path:new(vim.fn.stdpath('data'),'shada', table.remove(pathtable) , sessionname)
    vim.api.nvim_set_var('SessionName', sessionname)
    vim.api.nvim_exec_autocmds('User', { pattern = 'SessionLoadPre' })
    if vim.fn.filereadable(shadafile.filename)==1 then
      vim.api.nvim_command('silent clearjumps')
      vim.api.nvim_command('silent rshada! '..shadafile.filename)
    end
    vim.api.nvim_command('silent source ' .. filename)
    vim.api.nvim_exec_autocmds('User', { pattern = 'SessionLoadPost' })
    close_unused_lsp_clients()
    vim.o.swapfile = swapfile
  end)
end

---@param filename string
function utils.save_session(filename)
  local sessions_dir = Path:new(tostring(config.sessions_dir))
  if not sessions_dir:is_dir() then
    sessions_dir:mkdir()
  end

  -- Remove all non-file and utility buffers because they cannot be saved.
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and not utils.is_restorable(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end

  -- Clear all passed arguments to avoid re-executing them.
  if vim.fn.argc() > 0 then
    vim.api.nvim_command('%argdel')
  end

  utils.is_session = true
  local session_parent = Path:new(string.match(filename, '(.*)[\\/]'))
  if not (session_parent:exists() and session_parent:is_dir()) then
    session_parent:mkdir({ parents = true })
  end
  local pathtable = Path:new(filename):_split()
  local sessionname = table.remove(pathtable)
  local shadafileparent = Path:new(vim.fn.stdpath('data'), 'shada', table.remove(pathtable))
  if not (shadafileparent:exists() and shadafileparent:is_dir()) then
    shadafileparent:mkdir({ parents = true })
  end
  local shadafile = Path:new(shadafileparent.filename, sessionname)

  vim.api.nvim_exec_autocmds('User', { pattern = 'SessionSavePre' })
  vim.api.nvim_set_var('SessionName', sessionname)
  vim.api.nvim_command('silent wshada '..shadafile.filename)
  vim.api.nvim_command('mksession! ' .. filename)
  vim.api.nvim_exec_autocmds('User', { pattern = 'SessionSavePost' })
end

---@return table
function utils.get_sessions()
  local cwd = vim.loop.cwd()
  local current_session = config.dir_to_session_filename(cwd).filename
  local sessions = {}
  for _, session_filename in ipairs(scandir.scan_dir(tostring(config.sessions_dir))) do
    local dir = config.session_filename_to_dir(session_filename)
    if dir:is_dir() then
      if utils.is_session and session_filename ~= current_session then
        table.insert(sessions, { timestamp = vim.fn.getftime(session_filename), filename = session_filename, dir = dir })
      end
    else
      Path:new(session_filename):rm()
    end
  end
  table.sort(sessions, function(a, b) return a.timestamp > b.timestamp end)

  -- If we are in a session already, don't list the current session.

  -- If no sessions to list, send a notification.
  if #sessions == 0 then
    vim.notify('The only available session is your current session. Nothing to select from.', vim.log.levels.INFO)
  end

  return sessions
end

---@param buffer number: buffer ID.
---@return boolean: `true` if this buffer could be restored later on loading.
function utils.is_restorable(buffer)
  if #vim.api.nvim_buf_get_option(buffer, 'bufhidden') ~= 0 then
    return false
  end

  local buftype = vim.api.nvim_buf_get_option(buffer, 'buftype')
  if #buftype == 0 then
    -- Normal buffer, check if it listed.
    if not vim.api.nvim_buf_get_option(buffer, 'buflisted') then
      return false
    end
    -- Check if it has a filename.
    if #vim.api.nvim_buf_get_name(buffer) == 0 then
      return false
    end
  elseif buftype ~= 'terminal' then
    -- Buffers other then normal or terminal are impossible to restore.
    return false
  end

  if
      vim.tbl_contains(config.autosave_ignore_filetypes, vim.api.nvim_buf_get_option(buffer, 'filetype'))
      or vim.tbl_contains(config.autosave_ignore_buftypes, vim.api.nvim_buf_get_option(buffer, 'buftype'))
  then
    return false
  end
  return true
end

---@return boolean
function utils.is_restorable_buffer_present()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and utils.is_restorable(buffer) then
      return true
    end
  end
  return false
end

---@return boolean
function utils.is_dir_in_ignore_list()
  local cwd = vim.loop.cwd()
  -- Use `fnamemodify` to allow paths like `~/.config`.
  return vim.tbl_contains(config.autosave_ignore_dirs, cwd) or
  vim.tbl_contains(config.autosave_ignore_dirs, vim.fn.fnamemodify(cwd, ':~'))
end

--- Partially shorten path if length exceeds defined max_path_length.
---@param path table
---@return string
function utils.shorten_path(path)
  if config.max_path_length > 0 and #path.filename > config.max_path_length then
    -- Index to exclude from shortening, -1 means last
    local excludes = { -1 }

    -- Gradually increase the tailing excludes
    local shortened = path.filename
    local next_shortened = path:shorten(1, excludes)
    while #next_shortened < config.max_path_length do
      shortened = next_shortened

      -- Try new shortened path with more excludes
      excludes[#excludes + 1] = excludes[#excludes] - 1
      next_shortened = path:shorten(1, excludes)
    end

    return shortened
  end
  return path.sessionname..string.rep(' ', 20-#path.sessionname)..path.filename
end

return utils
