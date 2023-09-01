local config = require('session_manager.config')
local AutoloadMode = require('session_manager.config').AutoloadMode
local utils = require('session_manager.utils')
local Path = require('plenary.path')
local session_manager = {}

--- Apply user settings.
---@param values table
function session_manager.setup(values)
  setmetatable(config, { __index = vim.tbl_extend('force', config.defaults, values) })

  vim.api.nvim_set_var("SessionName", "")
  config.session_filename_to_dir = function(cwd)
    return utils.split_sessionname(config.defaults.session_filename_to_dir(cwd))
  end
  config.dir_to_session_filename = function(cwd)
    return utils.addsessionname(config.defaults.dir_to_session_filename(cwd))
  end
end

--- Selects a session a loads it.
---@param discard_current boolean: If `true`, do not check for unsaved buffers.
function session_manager.load_session(discard_current)
  local sessions = utils.get_sessions()
  vim.ui.select(sessions, {
    prompt = 'Load Session',
    format_item = function(item) return utils.shorten_path(item.dir) end,
  }, function(item)
    if item then
      session_manager.autosave_session()
      utils.load_session(item.filename, discard_current)
    end
  end)
end

--- Loads saved used session.
---@param discard_current boolean?: If `true`, do not check for unsaved buffers.
function session_manager.load_last_session(discard_current)
  local last_session = utils.get_last_session_filename()
  if last_session then
    if vim.api.nvim_get_var("SessionName") ~= '' then
      session_manager.autosave_session()
    end
    utils.load_session(last_session, discard_current)
  end
end

function session_manager.new_session(discard_current)
  session_manager.save_current_session()
  utils.new_session(discard_current)
end

--- Saves a session for the current working directory.
function session_manager.save_current_session()
  local cwd = vim.loop.cwd()
  if cwd then
    utils.save_session(config.dir_to_session_filename(cwd).filename)
  end
end

--- Loads a session based on settings. Executed after starting the editor.
function session_manager.autoload_session()
  if config.autoload_mode ~= AutoloadMode.Disabled and vim.fn.argc() == 0 and not vim.g.started_with_stdin then
    if config.autoload_mode == AutoloadMode.CurrentDir then
      session_manager.load_current_dir_session()
    elseif config.autoload_mode == AutoloadMode.LastSession then
      session_manager.load_last_session()
    end
  end
end

function session_manager.delete_session()
  local sessions = utils.get_sessions()
  vim.ui.select(sessions, {
    prompt = 'Delete Session',
    format_item = function(item) return utils.shorten_path(item.dir) end,
  }, function(item)
    if item then
      local sessionfile = Path:new(item.filename)
      local shadafile = Path:new(item.filename):_split()
      table.remove(shadafile, #shadafile-2)
      table.insert(shadafile, #shadafile-1, 'shada')
      shadafile = Path:new(shadafile)
      sessionfile:rm()
      shadafile:rm()
      local cwd = vim.loop.cwd()
      if utils.is_session and cwd and item.filename == config.dir_to_session_filename(cwd).filename then
        utils.is_session = false
      end
      session_manager.delete_session()
    end
  end)
end

--- Saves a session based on settings. Executed before exiting the editor.
function session_manager.autosave_session()
  if not config.autosave_last_session then
    return
  end

  if config.autosave_only_in_session and not utils.is_session then
    return
  end

  if config.autosave_ignore_dirs and utils.is_dir_in_ignore_list() then
    return
  end

  if not config.autosave_ignore_not_normal or utils.is_restorable_buffer_present() then
    session_manager.save_current_session()
  end
end

return session_manager
