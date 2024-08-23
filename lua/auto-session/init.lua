local Lib = require "auto-session.lib"
local Config = require "auto-session.config"
local AutoCmds = require "auto-session.autocmds"

----------- Setup ----------
local AutoSession = {}

---Setup function for AutoSession
---@param config AutoSession.Config|nil Config for auto session
function AutoSession.setup(config)
  Config.setup(config)
  Lib.setup(Config.log_level)
  Lib.logger.debug("Config at start of setup", tostring(Config))
  Config.check(Lib.logger)

  -- Validate the root dir here so it's always set up correctly
  AutoSession.get_root_dir()

  -- Will also setup session lens
  AutoCmds.setup_autocmds(AutoSession)
end

local function is_enabled()
  return Config.enabled
end

local function is_allowed_dirs_enabled()
  return not vim.tbl_isempty(Config.allowed_dirs or {})
end

local function is_auto_create_enabled()
  if type(Config.auto_create) ~= "function" then
    return Config.auto_create
  end

  local result = Config.auto_create()
  Lib.logger.debug("auto_create() returned: ", result)
  return result
end

-- get the current git branch name, if any, and only if configured to do so
local function get_git_branch_name()
  if not Config.use_git_branch then
    return ""
  end

  -- WARN: this assumes you want the branch of the cwd
  local out = vim.fn.systemlist "git rev-parse --abbrev-ref HEAD"
  if vim.v.shell_error ~= 0 then
    Lib.logger.debug(string.format("git failed with: %s", table.concat(out, "\n")))
    return ""
  end
  return out[1]
end

local in_pager_mode = function()
  return vim.g.in_pager_mode == Lib._VIM_TRUE
end

---Tracks the arguments nvim was launched with. Will be set to nil if a session is restored
local launch_argv = nil

---Returns whether Auto restoring / saving is enabled for the args nvim was launched with
---@param is_save boolean Is this being called during saving or restoring
---@return boolean Whether to allow saving/restoring
local function enabled_for_command_line_argv(is_save)
  is_save = is_save or false

  -- If no args (or launch_argv has been unset, allow restoring/saving)
  if not launch_argv then
    Lib.logger.debug "launch_argv is nil, saving/restoring enabled"
    return true
  end

  local argc = #launch_argv

  Lib.logger.debug("enabled_for_command_line_argv, launch_argv: " .. vim.inspect(launch_argv))

  if argc == 0 then
    -- Launched with no args, saving is enabled
    Lib.logger.debug "No arguments, saving/restoring enabled"
    return true
  end

  -- if Config.args_allow_single_directory = true, then enable session handling if only param is a directory
  if argc == 1 and vim.fn.isdirectory(launch_argv[1]) == Lib._VIM_TRUE and Config.args_allow_single_directory then
    -- Actual session will be loaded in auto_restore_session_at_vim_enter
    Lib.logger.debug("Allowing restore when launched with a single directory argument: " .. launch_argv[1])
    return true
  end

  if not Config.args_allow_files_auto_save then
    Lib.logger.debug "args_allow_files_auto_save is false, not enabling restoring/saving"
    return false
  end

  if not is_save then
    Lib.logger.debug "Not allowing restore when launched with argument"
    return false
  end

  if type(Config.args_allow_files_auto_save) == "function" then
    local ret = Config.args_allow_files_auto_save()
    Lib.logger.debug("args_allow_files_auto_save() returned: " .. vim.inspect(ret))
    return ret
  end

  Lib.logger.debug "Allowing possible save when launched with argument"
  return true
end

local in_headless_mode = function()
  -- Allow testing in headless mode
  -- In theory, we could mock out vim.api.nvim_list_uis but that was causing
  -- downstream issues with nvim_list_wins
  if vim.env.AUTOSESSION_UNIT_TESTING then
    return false
  end

  return not vim.tbl_contains(vim.v.argv, "--embed") and not next(vim.api.nvim_list_uis())
end

local auto_save = function()
  if in_pager_mode() or in_headless_mode() or not enabled_for_command_line_argv(true) then
    Lib.logger.debug "auto_save, pager, headless, or enabled_for_command_line_argv returned false"
    return false
  end

  return Config.auto_save
end

local auto_restore = function()
  if in_pager_mode() or in_headless_mode() or not enabled_for_command_line_argv(false) then
    return false
  end

  return Config.auto_restore
end

local function bypass_save_by_filetype()
  local filetypes_to_bypass = Config.bypass_save_filetypes or {}
  local windows = vim.api.nvim_list_wins()

  for _, current_window in ipairs(windows) do
    local buf = vim.api.nvim_win_get_buf(current_window)

    -- Deprecated as 0.9.0, should update to following when we only want to support 0.9.0+
    -- local buf_ft = vim.bo[buf].filetype
    local buf_ft = vim.api.nvim_buf_get_option(buf, "filetype")

    local local_return = false
    for _, ft_to_bypass in ipairs(filetypes_to_bypass) do
      if buf_ft == ft_to_bypass then
        local_return = true
        break
      end
    end

    if local_return == false then
      Lib.logger.debug "bypass_save_by_filetype: false"
      return false
    end
  end

  Lib.logger.debug "bypass_save_by_filetype: true"
  return true
end

local function suppress_session(session_dir)
  local dirs = Config.suppressed_dirs or {}

  -- If session_dir is set, use that otherwise use cwd
  -- session_dir will be set when loading a session from a directory at lauch (i.e. from argv)
  local cwd = session_dir or vim.fn.getcwd()

  if Lib.find_matching_directory(cwd, dirs) then
    Lib.logger.debug "suppress_session found a match, suppressing"
    return true
  end

  Lib.logger.debug "suppress_session didn't find a match, returning false"
  return false
end

local function is_allowed_dir()
  if not is_allowed_dirs_enabled() then
    return true
  end

  local dirs = Config.allowed_dirs or {}
  local cwd = vim.fn.getcwd()

  if Lib.find_matching_directory(cwd, dirs) then
    Lib.logger.debug "is_allowed_dir found a match, allowing"
    return true
  end

  Lib.logger.debug "is_allowed_dir didn't find a match, returning false"
  return false
end

---Gets the file name for a session name.
---If no filename is passed it, will generate one using the cwd and, if enabled, the git
---branchname.
---@param session_name string|nil The session name to use or nil
---@param legacy? boolean Generate a legacy filename (default: false)
---@return string Returns the escaped version of the name with .vim appended.
local function get_session_file_name(session_name, legacy)
  if not session_name or session_name == "" then
    session_name = vim.fn.getcwd()
    Lib.logger.debug("get_session_file_name no session_name, using cwd: " .. session_name)

    local git_branch_name = get_git_branch_name()
    if git_branch_name and git_branch_name ~= "" then
      -- NOTE: By including it in the session name, there's the possibility of a collision
      -- with an actual directory named session_name|branch_name. Meaning, that if someone
      -- created a session in session_name (while branch_name is checked out) and then also
      -- went to edit in a directory literally called session_name|branch_name. the sessions
      -- would collide. Obviously, that's not perfect but I think it's an ok price to pay to
      -- get branch specific sessions and still have a cwd derived text key to identify sessions
      -- that can be used everywhere, incuding :SessionRestore
      if legacy then
        session_name = session_name .. "_" .. git_branch_name
      else
        -- now that we're percent encoding, we can pick a less likely character, even if it doesn't
        -- avoid the problem entirely
        session_name = session_name .. "|" .. git_branch_name
      end
    end
  end

  local escaped_session_name
  if legacy then
    escaped_session_name = Lib.legacy_escape_session_name(session_name)
  else
    escaped_session_name = Lib.escape_session_name(session_name)
  end

  -- Always add extension to session name
  escaped_session_name = escaped_session_name .. ".vim"

  return escaped_session_name
end

local function auto_save_conditions_met()
  if not is_enabled() then
    Lib.logger.debug "auto_save_conditions_met: is_enabled() is false, returning false"
    return false
  end

  if not auto_save() then
    Lib.logger.debug "auto_save_conditions_met: auto_save() is false, returning false"
    return false
  end

  if suppress_session() then
    Lib.logger.debug "auto_save_conditions_met: suppress_session() is true, returning false"
    return false
  end

  if not is_allowed_dir() then
    Lib.logger.debug "auto_save_conditions_met: is_allowed_dir() is false, returning false"
    return false
  end

  if bypass_save_by_filetype() then
    Lib.logger.debug "auto_save_conditions_met: bypass_save_by_filetype() is true, returning false"
    return false
  end

  Lib.logger.debug "auto_save_conditions_met: returning true"
  return true
end

---Quickly checks if a session file exists for the current working directory.
---This is useful for starter plugins which don't want to display 'restore session'
---unless a session for the current working directory exists.
---@return boolean True if a session exists for the cwd
function AutoSession.session_exists_for_cwd()
  local session_file = get_session_file_name(vim.fn.getcwd())
  if vim.fn.filereadable(AutoSession.get_root_dir() .. session_file) ~= 0 then
    return true
  end

  -- Check legacy sessions
  session_file = get_session_file_name(vim.fn.getcwd(), true)
  return vim.fn.filereadable(AutoSession.get_root_dir() .. session_file) ~= 0
end

---AutoSaveSession
---Function called by auto_session to trigger auto_saving sessions, for example on VimExit events.
---@return boolean True if a session was saved
function AutoSession.AutoSaveSession()
  if not auto_save_conditions_met() then
    Lib.logger.debug "Auto save conditions not met"
    return false
  end

  if not is_auto_create_enabled() then
    local session_file_name = get_session_file_name()
    if vim.fn.filereadable(AutoSession.get_root_dir() .. session_file_name) == 0 then
      Lib.logger.debug "Create not enabled and no existing session, not creating session"
      return false
    end
  end

  if Config.close_unsupported_windows then
    -- Wrap in pcall in case there's an error while trying to close windows
    local success, result = pcall(Lib.close_unsupported_windows)
    if not success then
      Lib.logger.debug("Error closing unsupported windows: " .. result)
    end
  end

  -- Don't try to show a message as we're exiting
  return AutoSession.SaveSession(nil, false)
end

---@private
---Gets the root directory of where to save the sessions.
---By default this resolves to `vim.fn.stdpath "data" .. "/sessions/"`
---@param with_trailing_separator? boolean whether to incude the trailing separator. A few places (telescope picker don't expect a trailing separator) (Defaults to true)
---@return string
function AutoSession.get_root_dir(with_trailing_separator)
  if with_trailing_separator == nil then
    with_trailing_separator = true
  end

  if not AutoSession.validated then
    Config.root_dir = Lib.validate_root_dir(Config.root_dir)
    Lib.logger.debug("Root dir set to: " .. Config.root_dir)
    AutoSession.validated = true
  end

  if with_trailing_separator then
    return Config.root_dir
  end

  return Lib.remove_trailing_separator(Config.root_dir)
end

---@private
---Get the hook commands from the config and run them
---@param hook_name string
---@return table Results of the commands
function AutoSession.run_cmds(hook_name)
  local cmds = Config[hook_name .. "_cmds"]
  return Lib.run_hook_cmds(cmds, hook_name)
end

---Calls a hook to get any user/extra commands and if any, saves them to *x.vim
---@param session_path string The path of the session file to save the extra params for
---@return boolean Returns whether extra commands were saved
local function save_extra_cmds_new(session_path)
  local data = AutoSession.run_cmds "save_extra"
  if not data then
    return false
  end

  local extra_file = string.gsub(session_path, "%.vim$", "x.vim")
  if vim.fn.writefile(data, extra_file) ~= 0 then
    return false
  end

  return true
end

---@private
---Handler for when a session is picked from the UI, either via Telescope or via AutoSession.select_session
---Save the current session if the session we're loading isn't also for the cwd (if autosave allows)
---and then restore the selected session
---@param session_name string The session name to restore
---@return boolean Was the session restored successfully
function AutoSession.autosave_and_restore(session_name)
  local cwd_session_name = Lib.escaped_session_name_to_session_name(get_session_file_name())
  if cwd_session_name ~= session_name then
    Lib.logger.debug("Autosaving before restoring", { cwd = cwd_session_name, session_name = session_name })
    AutoSession.AutoSaveSession()
  else
    Lib.logger.debug("Not autosaving, cwd == session_name for: ", session_name)
  end

  return AutoSession.RestoreSession(session_name)
end

local function write_to_session_control_json(session_file_name)
  local control_dir = Config.session_lens.session_control.control_dir
  local control_file = Config.session_lens.session_control.control_filename
  session_file_name = Lib.expand(session_file_name)

  -- expand the path
  control_dir = vim.fn.expand(control_dir)
  Lib.init_dir(control_dir)

  -- Get the full path
  local session_control_file_path = control_dir .. control_file

  -- Load existing data, if it exists
  local session_control = Lib.load_session_control_file(session_control_file_path)
  Lib.logger.debug("Loaded session control data: ", session_control)

  -- If there's existing data
  if session_control.current then
    if session_control.current == session_file_name then
      Lib.logger.debug(
        "Not writing to session control file, current is same as session_file_name: " .. session_file_name
      )
      return
    end
    session_control.alternate = session_control.current
  end

  session_control.current = session_file_name

  Lib.logger.debug("Saving session control", session_control)

  local json_to_save = vim.json.encode(session_control)

  vim.fn.writefile({ json_to_save }, session_control_file_path)
end

---Function called by AutoSession when automatically restoring a session.
---@param session_name? string An optional session to load
---@return boolean boolean returns whether restoring the session was successful or not.
function AutoSession.AutoRestoreSession(session_name)
  -- WARN: should this be checking is_allowed_dir as well?
  if not is_enabled() or not auto_restore() or suppress_session(session_name) then
    return false
  end

  return AutoSession.RestoreSession(session_name, false)
end

---@private
---Called at VimEnter (after Lazy is done) to see if we should automatically restore a session
---If launched with a single directory parameter and Config.args_allow_single_directory is true, pass
---that in as the session_dir. Handles both 'nvim .' and 'nvim some/dir'
---Also make sure to call no_restore if no session was restored
---@return boolean Was a session restored
function AutoSession.auto_restore_session_at_vim_enter()
  -- Save the launch args here as restoring a session will replace vim.fn.argv. We clear
  -- launch_argv in restore session so it's only used for the session launched from the command
  -- line
  launch_argv = vim.fn.argv()

  -- Is there exactly one argument and is it a directory?
  if
    Config.args_allow_single_directory
    and #launch_argv == 1
    and vim.fn.isdirectory(launch_argv[1]) == Lib._VIM_TRUE
  then
    -- Get the full path of the directory and make sure it doesn't have a trailing path_separator
    -- to make sure we find the session
    local session_name = Lib.remove_trailing_separator(vim.fn.fnamemodify(launch_argv[1], ":p"))
    Lib.logger.debug("Launched with single directory, using as session_dir: " .. session_name)

    if AutoSession.AutoRestoreSession(session_name) then
      return true
    end

    -- We failed to load a session for the other directory. Unless session name matches cwd, we don't
    -- want to enable autosaving since it might replace the session for the cwd
    if vim.fn.getcwd() ~= session_name then
      Lib.logger.debug "Not enabling autosave because launch argument didn't load session and doesn't match cwd"
      Config.auto_save = false
    end
  else
    if AutoSession.AutoRestoreSession() then
      return true
    end

    -- Check to see if the last session feature is on
    if Config.auto_restore_last_lession then
      Lib.logger.debug "Last session is enabled, checking for session"

      local last_session_name = Lib.get_latest_session(AutoSession.get_root_dir())
      if last_session_name then
        Lib.logger.debug("Found last session: " .. last_session_name)
        if AutoSession.RestoreSession(last_session_name, false) then
          return true
        end
      end
      Lib.logger.debug "Failed to load last session"
    end
  end

  -- No session was restored, dispatch no-restore hook
  Lib.logger.debug "No session restored, call no_restore hooks"
  AutoSession.run_cmds "no_restore"

  return false
end

---Saves a session to the dir specified in the config. If no optional
---session name is passed in, it uses the cwd as the session name
---@param session_name? string|nil Optional session name
---@param show_message? boolean Optional, whether to show a message on save (true by default)
---@return boolean
function AutoSession.SaveSession(session_name, show_message)
  return AutoSession.SaveSessionToDir(AutoSession.get_root_dir(), session_name, show_message)
end

---Saves a session to the passed in directory. If no optional
---session name is passed in, it uses the cwd as the session name
---@param session_dir string Directory to write the session file to
---@param session_name? string|nil Optional session name
---@param show_message? boolean Optional, whether to show a message on save (true by default)
---@return boolean
function AutoSession.SaveSessionToDir(session_dir, session_name, show_message)
  Lib.logger.debug("SaveSessionToDir start", { session_dir, session_name, show_message })

  -- Canonicalize and create session_dir if needed
  session_dir = Lib.validate_root_dir(session_dir)
  Lib.logger.debug("SaveSessionToDir validated session_dir: ", session_dir)

  local escaped_session_name = get_session_file_name(session_name)

  Lib.logger.debug("SaveSessionToDir escaped session name: " .. escaped_session_name)

  local session_path = session_dir .. escaped_session_name

  AutoSession.run_cmds "pre_save"

  -- We don't want to save arguments to the session as that can cause issues
  -- with buffers that can't be removed from the session as they keep being
  -- added back through an argadd
  vim.cmd "%argdelete"

  Lib.logger.debug("SaveSessionToDir writing session to: " .. session_path)

  -- Vim cmds require escaping any % with a \ but we don't want to do that
  -- for direct filesystem operations (like in save_extra_cmds_new) so we
  -- that here, as late as possible and only for this operation
  local vim_session_path = Lib.escape_string_for_vim(session_path)
  vim.cmd("mks! " .. vim_session_path)

  save_extra_cmds_new(session_path)

  AutoSession.run_cmds "post_save"

  -- session_name might be nil (e.g. when using cwd), unescape escaped_session_name instead
  Lib.logger.debug("Saved session: " .. Lib.unescape_session_name(escaped_session_name))
  if show_message == nil or show_message then
    vim.notify("Saved session: " .. Lib.get_session_display_name(escaped_session_name))
  end

  return true
end

---Restores a session from the passed in directory. If no optional session name
---is passed in, it uses the cwd as the session name
---@param session_name? string|nil Optional session name
---@param show_message? boolean Optional, whether to show a message on restore (true by default)
function AutoSession.RestoreSession(session_name, show_message)
  return AutoSession.RestoreSessionFromDir(AutoSession.get_root_dir(), session_name, show_message)
end

---Restores a session from the passed in directory. If no optional session name
---is passed in, it uses the cwd as the session name
---@param session_dir string Directory to write the session file to
---@param session_name? string|nil Optional session name
---@param show_message? boolean Optional, whether to show a message on restore (true by default)
function AutoSession.RestoreSessionFromDir(session_dir, session_name, show_message)
  Lib.logger.debug("RestoreSessionFromDir start", { session_dir, session_name })
  -- Canonicalize and create session_dir if needed
  session_dir = Lib.validate_root_dir(session_dir)
  Lib.logger.debug("RestoreSessionFromDir validated session_dir: ", session_dir)

  local escaped_session_name = get_session_file_name(session_name)

  Lib.logger.debug("RestoreSessionFromDir escaped session name: " .. escaped_session_name)

  local session_path = session_dir .. escaped_session_name

  if vim.fn.filereadable(session_path) ~= 1 then
    Lib.logger.debug("RestoreSessionFromDir session does not exist: " .. session_path)

    -- NOTE: This won't work for legacy window session names containing dashes because
    -- information was lost (i.e. was the dash part of the original parth or was it
    -- a parth separator).
    local legacy_escaped_session_name = get_session_file_name(session_name, true)
    local legacy_session_path = session_dir .. legacy_escaped_session_name

    if vim.fn.filereadable(legacy_session_path) ~= 1 then
      if show_message == nil or show_message then
        vim.notify("Could not restore session: " .. Lib.get_session_display_name(escaped_session_name))
      end
      return false
    end

    Lib.logger.debug("RestoreSessionFromDir renaming legacy session: " .. legacy_escaped_session_name)
    ---@diagnostic disable-next-line: undefined-field
    if not vim.loop.fs_rename(legacy_session_path, session_path) then
      Lib.logger.debug(
        "RestoreSessionFromDir rename failed!",
        { session_path = session_path, legacy_session_path = legacy_session_path }
      )
      return false
    end

    -- Check for user commands
    local legacy_user_commands_path = legacy_session_path:gsub("%.vim", "x.vim")
    local user_commands_path = session_path:gsub("%.vim", "x.vim")

    -- If there is a legacy commands file and it's not actually a session and there is already a user commands file,
    -- then migrate
    if vim.fn.filereadable(legacy_user_commands_path) == 1 and not Lib.is_session_file(legacy_user_commands_path) then
      if vim.fn.filereadable(user_commands_path) == 0 then
        Lib.logger.debug("RestoreSessionFromDir Renaming legacy user commands" .. legacy_user_commands_path)
        vim.loop.fs_rename(legacy_user_commands_path, user_commands_path)
      end
    end
  end

  return AutoSession.RestoreSessionFile(session_path, show_message)
end

---Restores a session from a specific file
---@param session_path string The session file to load
---@param show_message? boolean Optional, whether to show a message on restore (true by default)
---@return boolean Was a session restored
function AutoSession.RestoreSessionFile(session_path, show_message)
  AutoSession.run_cmds "pre_restore"

  Lib.logger.debug("RestoreSessionFile restoring session from: " .. session_path)

  -- Vim cmds require escaping any % with a \ but we don't want to do that
  -- for direct filesystem operations (like in save_extra_cmds_new) so we
  -- that here, as late as possible and only for this operation
  local vim_session_path = Lib.escape_string_for_vim(session_path)
  local cmd = "source " .. vim_session_path

  -- Set restore_in_progress here so we won't also try to save/load the session if
  -- cwd_change_handling = true and the session contains a cd command
  -- The session file will also set SessionLoad so we'll check that too but feels
  -- safer to have our own flag as well, in case the vim flag changes
  AutoSession.restore_in_progress = true

  -- Clear the buffers and jumps
  vim.cmd "%bw!"
  vim.cmd "clearjumps"

  ---@diagnostic disable-next-line: param-type-mismatch
  local success, result = pcall(vim.cmd, "silent " .. cmd)

  -- normal restore failed, source again but with silent! to restore as much as possible
  if not success and Config.continue_restore_on_error then
    vim.cmd "%bw!"
    vim.cmd "clearjumps"

    -- don't capture return values as we'll use success and result from the first call
    ---@diagnostic disable-next-line: param-type-mismatch
    pcall(vim.cmd, "silent! " .. cmd)
  end

  AutoSession.restore_in_progress = false

  -- Clear any saved command line args since we don't need them anymore
  launch_argv = nil

  if not success then
    Lib.logger.error([[
Error restoring session, disabling auto save.
Error: ]] .. result)
    Config.auto_save = false
    return false
  end

  local session_name = Lib.escaped_session_name_to_session_name(vim.fn.fnamemodify(session_path, ":t"))
  Lib.logger.debug("Restored session: " .. session_name)
  if show_message == nil or show_message then
    vim.notify("Restored session: " .. session_name)
  end

  AutoSession.run_cmds "post_restore"

  write_to_session_control_json(session_path)
  return true
end

---Deletes a session from the config session dir. If no optional session name
---is passed in, it uses the cwd as the session name
---@param session_name? string|nil Optional session name
function AutoSession.DeleteSession(session_name)
  return AutoSession.DeleteSessionFromDir(AutoSession.get_root_dir(), session_name)
end

---Deletes a session from the passed in directory. If no optional session
---name is passed in, it uses the cwd as the session name
---@param session_dir string Directory to delete the session from
---@param session_name? string|nil Optional session name
function AutoSession.DeleteSessionFromDir(session_dir, session_name)
  Lib.logger.debug("DeleteSessionFromDir start", { session_dir, session_name })

  -- Canonicalize and create session_dir if needed
  session_dir = Lib.validate_root_dir(session_dir)
  Lib.logger.debug("DeleteSessionFromDir validated session_dir ", session_dir)

  local escaped_session_name = get_session_file_name(session_name)

  Lib.logger.debug("DeleteSessionFromDir escaped session name: " .. escaped_session_name)

  local session_path = session_dir .. escaped_session_name

  if vim.fn.filereadable(session_path) ~= 1 then
    Lib.logger.debug("DeleteSessionFromDir session does not exist: " .. session_path)

    -- Check for a legacy session to delete
    local legacy_escaped_session_name = get_session_file_name(session_name, true)
    local legacy_session_path = session_dir .. legacy_escaped_session_name

    if vim.fn.filereadable(legacy_session_path) ~= 1 then
      vim.notify("Session does not exist: " .. Lib.get_session_display_name(escaped_session_name))
      return false
    end
    Lib.logger.debug("DeleteSessionFromDir using legacy session: " .. legacy_escaped_session_name)
    session_path = legacy_session_path
  end

  -- session_name could be nil, so get name from escaped_session_name
  return AutoSession.DeleteSessionFile(session_path, Lib.get_session_display_name(escaped_session_name))
end

---Delete a session file
---@param session_path string The filename to delete
---@param session_name string Session name being deleted, just use to display messages
---@return boolean Was the session file delted
function AutoSession.DeleteSessionFile(session_path, session_name)
  AutoSession.run_cmds "pre_delete"

  Lib.logger.debug("DeleteSessionFile deleting: " .. session_path)

  local result = vim.fn.delete(Lib.expand(session_path)) == 0

  if not result then
    Lib.logger.error("DeleteSessionFile Failed to delete session: " .. session_name)
  else
    if vim.fn.fnamemodify(vim.v.this_session, ":t") == vim.fn.fnamemodify(session_path, ":t") then
      -- session_name might be nil (e.g. when using cwd), unescape escaped_session_name instead
      Lib.logger.info("Auto saving disabled because the current session was deleted: " .. session_name)
      vim.v.this_session = ""
      Config.auto_save = false
    else
      Lib.logger.debug("DeleteSessionFile Session deleted: " .. session_name)
      vim.notify("Session deleted: " .. session_name)
    end
  end

  -- check for extra user commands
  local extra_commands_path = session_path:gsub("%.vim$", "x.vim")
  if vim.fn.filereadable(extra_commands_path) == 1 and not Lib.is_session_file(extra_commands_path) then
    vim.fn.delete(extra_commands_path)
    Lib.logger.debug("DeleteSessionFile deleting extra user commands: " .. extra_commands_path)
  end

  AutoSession.run_cmds "post_delete"
  return result
end

---Disables autosave. Enables autosave if enable is true
---@param enable? boolean Optional paramter to enable autosaving
---@return boolean Whether autosaving is enabled or not
function AutoSession.DisableAutoSave(enable)
  Config.auto_save = enable or false
  if Config.auto_save then
    vim.notify "Session auto-save enabled"
  else
    vim.notify "Session auto-save disabled"
  end
  return Config.auto_save
end

return AutoSession
