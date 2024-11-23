local util = require "obsidian.util"
local log = require "obsidian.log"
local Path = require "obsidian.path"
local ts_utils = require "nvim-treesitter.ts_utils"
local ts = vim.treesitter
local api = vim.api

---@return string|nil
local function read_file(file_path)
  local file = io.open(file_path, "r") -- Open the file in read mode
  if not file then
    print("Error: Cannot open file " .. file_path)
    return nil
  end

  local content = file:read "*a" -- Read the entire file content
  file:close() -- Close the file
  return content
end

---@param buf number
---@param path string
local function write_buffer(buf, path)
  -- Get all lines from the buffer
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Open the file in write mode
  local file = io.open(path, "w")
  if not file then
    print("Failed to open file: " .. path)
    return
  end

  -- Write each line to the file
  for _, line in ipairs(lines) do
    file:write(line .. "\n") -- Write each line followed by a newline
  end
  file:flush()
  file:close()
end

---@param buf number
---@return [string] | nil
local function get_unfinished_tasks(buf)
  local parser = vim.treesitter.get_parser(buf, "markdown") -- Ensure the right language parser is used

  if not parser then
    print "Tree-sitter parser not found for this buffer."
    return nil
  end

  local root = parser:parse()[1]:root() -- Parse the buffer and get the root node

  -- Tree-sitter query to match '- [ ]'
  local query = vim.treesitter.query.parse(
    "markdown",
    [[
    (task_list_marker_unchecked) @item
    ]]
  )
  local matches = {}
  local empty = true
  for _, match in query:iter_matches(root, buf) do
    empty = false
    local node = match[1]
    local start_row, start_col, end_row, end_col = node:range() -- Get the range for this node

    -- Get the full line text from the buffer
    local line_text = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1]
    table.insert(matches, line_text)
  end
  -- TODO: clean 
  if empty then
    return nil
  end
  return matches
end

---@param buf number
---@param unfinished_tasks [string]
local function append_to_tasks_section(buf, unfinished_tasks)
  local parser = vim.treesitter.get_parser(buf, "markdown")
  local tree = parser:parse()[1]
  local root = tree:root()

  -- Define the Tree-sitter query to find the '# Tasks' heading
  local query = vim.treesitter.query.parse(
    "markdown",
    [[
      (atx_heading
        (atx_h1_marker)
        (inline) @heading_text)
    ]]
  )

  -- Iterate over each heading node
  for _, match, _ in query:iter_matches(root, bufnr) do
    local node = match[1] -- The captured node (heading text)
    local start_row, _, _, _ = node:range()

    -- Get the heading text and check if it's '# Tasks'
    local line_text = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1]
    if line_text:match "^# Tasks" then
      -- Insert the new line below the '# Tasks' heading
      vim.api.nvim_buf_set_lines(buf, start_row + 1, start_row + 1, false, unfinished_tasks)
      return -- Exit after adding the line
    end
  end

  print "Could not find the '# Tasks' section."
end

---@param client obsidian.Client
return function(client, data)
  local offset_days = 0
  local arg = util.string_replace(data.args, " ", "")

  if string.len(arg) > 0 then
    local offset = tonumber(arg)
    if not offset then
      log.err "Invalid argument, expected an integer offset"
      return
    else
      offset_days = offset
    end
  end

  local todays_note = client:daily(offset_days)
  local yesterday_note = client:yesterday()

  local yesterday_note_content = read_file(yesterday_note.path.filename)
  if yesterday_note_content == nil then
    return
  end
  local todays_note_content = read_file(todays_note.path.filename)
  if todays_note_content == nil then
    return
  end

  local buf = api.nvim_create_buf(false, true)

  -- Set the content of the buffer
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(yesterday_note_content, "\n"))

  local buf_today = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf_today, 0, -1, false, vim.split(todays_note_content, "\n"))

  local unfinished_tasks = {}

  -- TODO: clean 
  local yesterdays_unfinished_tasks = get_unfinished_tasks(buf)
  if yesterdays_unfinished_tasks ~= nil then
    local todays_unfinished_tasks = get_unfinished_tasks(buf_today)
    if todays_unfinished_tasks ~= nil then
      for idx, yesterday_task in pairs(yesterdays_unfinished_tasks) do
        local found = false
        for idx, today_task in pairs(todays_unfinished_tasks) do
          if yesterday_task ~= today_task then
            found = true
            break
          end
        end
        if found then
          table.insert(unfinished_tasks, yesterday_task)
        end
      end
    else
      unfinished_tasks = yesterdays_unfinished_tasks
    end
  end

  -- Append those tasks to the task section in the markdown file
  append_to_tasks_section(buf_today, unfinished_tasks)

  -- save buffer content to file
  write_buffer(buf_today, todays_note.path.filename)


  client:open_note(todays_note)
end
