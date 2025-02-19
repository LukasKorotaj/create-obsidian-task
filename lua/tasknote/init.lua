local date_util = require("tasknote.date_util")

local TaskNote = {}

-- Default configuration
TaskNote.config = {
	global_filter = "#task", -- used when building the output string
	keymaps = {
		handle_input = { "<CR>" }, -- key(s) for field input
		submit = { "<C-s>" }, -- key(s) for submitting the form
	},
}
function TaskNote.setup(opts)
	TaskNote.config = vim.tbl_deep_extend("force", TaskNote.config, opts or {})

	-- Create commands for each status with proper closure
	for _, status in ipairs(TaskNote.config.statuses) do
		vim.api.nvim_create_user_command(status.command, function()
			TaskNote.toggle_status(status)
		end, {})
	end
end

function TaskNote.toggle_status(status)
	local line = vim.api.nvim_get_current_line()

	-- Updated pattern to handle indentation and capture components
	local pre, symbol, content = line:match("^(%s*%- %[)(.)(%].*)$")
	if not pre then
		return
	end

	local new_line = pre .. status.symbol .. content

	-- Handle metadata appending
	if status.append and status.append ~= "" then
		-- Replace date placeholders
		local processed = status.append:gsub("today", function()
			return date_util.parse_date("today") or os.date("%Y-%m-%d")
		end)

		-- Extract metadata key
		local key = processed:match("%[([^%:]*)::")
		if key then
			-- Remove existing metadata with same key
			new_line = new_line:gsub("%[" .. key .. "::.-%]", "")
			-- Add new metadata and clean up spaces
			new_line = new_line .. " " .. processed
		end
	end

	-- Capture the indentation (leading whitespace)
	local indent = new_line:match("^(%s*)") or ""
	-- Process the rest of the line without affecting the indent
	local con = new_line:sub(#indent + 1)
	local processed = con
		:gsub("%s+", " ") -- Collapse multiple spaces into one
		:gsub("%s+$", "") -- Remove trailing spaces
		:gsub("%s*%]%s*", "] ") -- Clean up spaces around closing bracket
	-- Concatenate the indent with the processed content
	local final_line = indent .. processed

	vim.api.nvim_set_current_line(final_line)
end

local defaults = {
	height = 12,
	width = 60,
	border = "single",
}

local fields = {
	{ name = "description", type = "string" },
	{ name = "priority", type = "select", options = { "none", "lowest", "low", "medium", "high", "highest" } },
	{ name = "repeat", type = "string" },
	{ name = "created", type = "date" },
	{ name = "start", type = "date" },
	{ name = "scheduled", type = "date" },
	{ name = "due", type = "date" },
}

-- Store state for editing
TaskNote.origin_buf = nil
TaskNote.origin_win = nil
TaskNote.edit_lnum = nil -- Line number being edited (nil for new tasks)

-- Parse existing task line into data table
function TaskNote.parse_line(line)
	local data = {}

	-- First extract the entire task part after the global filter
	local task_part = line:match(TaskNote.config.global_filter .. "%s+(.*)")
	if not task_part then
		return data
	end

	-- Split into description and metadata fields
	local description, metadata_str = task_part:match("^(.-)%s*([%[].-::.*)$")

	-- If no metadata found, use entire task_part as description
	if not description then
		description = task_part
	end

	-- Clean up description: remove trailing whitespace and any orphaned brackets
	description = description:gsub("%s+$", ""):gsub("%s*%[%s*$", "")
	data.description = description ~= "" and description or nil

	-- Extract metadata fields using more precise pattern
	for key, value in (metadata_str or ""):gmatch("%[([%w_]+):: ([^%]]*)%]") do
		key = key:lower():gsub("%s+", "")
		value = value:gsub("^%s*(.-)%s*$", "%1")
		if value ~= "" then
			data[key] = value
		end
	end

	return data
end

function TaskNote.create()
	-- Save original context
	TaskNote.origin_buf = vim.api.nvim_get_current_buf()
	TaskNote.origin_win = vim.api.nvim_get_current_win()
	local current_line = vim.api.nvim_get_current_line()

	-- Check if we're editing an existing task
	local is_edit = current_line:find(TaskNote.config.global_filter, 1, true)
	local edit_data = {}
	TaskNote.edit_lnum = nil

	if is_edit then
		TaskNote.edit_lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-based
		edit_data = TaskNote.parse_line(current_line)
	end

	-- Create and configure buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("readonly", false, { buf = buf })

	-- Create window
	vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = defaults.width,
		height = defaults.height,
		col = (vim.o.columns - defaults.width) / 2,
		row = (vim.o.lines - defaults.height) / 2,
		style = "minimal",
		border = defaults.border,
	})

	-- Populate initial content
	local lines = {}
	for _, field in ipairs(fields) do
		local value = edit_data[field.name] or ""
		if field.type == "select" then
			value = value == "none" and "" or value
		end
		table.insert(lines, field.name .. ": " .. value)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Key mappings
	for _, key in ipairs(TaskNote.config.keymaps.handle_input) do
		vim.api.nvim_buf_set_keymap(
			buf,
			"n",
			key,
			'<cmd>lua require("tasknote").handle_input()<CR>',
			{ noremap = true, silent = true }
		)
		vim.api.nvim_buf_set_keymap(
			buf,
			"i",
			key,
			'<cmd>lua require("tasknote").handle_input()<CR>',
			{ noremap = true, silent = true }
		)
	end

	for _, key in ipairs(TaskNote.config.keymaps.submit) do
		vim.api.nvim_buf_set_keymap(
			buf,
			"n",
			key,
			'<cmd>lua require("tasknote").submit()<CR>',
			{ noremap = true, silent = true }
		)
		vim.api.nvim_buf_set_keymap(
			buf,
			"i",
			key,
			'<cmd>lua require("tasknote").submit()<CR>',
			{ noremap = true, silent = true }
		)
	end

	-- Auto-enter insert mode
	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = buf,
		callback = function()
			vim.cmd("startinsert")
		end,
		once = true,
	})
end

function TaskNote.handle_input()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local field = fields[row]
	local current_line = vim.api.nvim_get_current_line()

	if field.type == "select" then
		vim.ui.select(field.options, {
			prompt = "Select " .. field.name .. ":",
			format_item = function(item)
				return item:upper()
			end,
		}, function(choice)
			if choice then
				local new_line = field.name .. ": " .. (choice ~= "none" and choice or "")
				vim.api.nvim_buf_set_lines(0, row - 1, row, false, { new_line })
			end
		end)
	elseif field.type == "date" then
		vim.ui.input({
			prompt = "Enter date (today/tomorrow/yesterday/Monday/mon/tue/wed/etc): ",
			default = current_line:match(": (.*)") or "",
		}, function(input)
			if input then
				local date = date_util.parse_date(input)
				if date then
					vim.api.nvim_buf_set_lines(0, row - 1, row, false, { field.name .. ": " .. date })
				end
			end
		end)
	elseif field.type == "string" then
		vim.ui.input({
			prompt = "Enter " .. field.name .. ": ",
			default = current_line:match(": (.*)") or "",
		}, function(input)
			if input then
				vim.api.nvim_buf_set_lines(0, row - 1, row, false, { field.name .. ": " .. input })
			end
		end)
	end
end

function TaskNote.submit()
	-- Get the lines from the popup buffer
	local popup_buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)

	-- Parse each line "field: value"
	local data = {}
	for _, line in ipairs(lines) do
		local key, value = line:match("^(.-):%s*(.*)$")
		if key then
			data[key] = value
		end
	end

	-- Build the output string
	local parts = { "- [ ]" }
	if data["description"] and data["description"] ~= "" then
		table.insert(parts, TaskNote.config.global_filter .. " " .. data["description"])
	end
	if data["priority"] and data["priority"] ~= "" then
		table.insert(parts, string.format("[priority:: %s]", data["priority"]))
	end
	if data["repeat"] and data["repeat"] ~= "" then
		table.insert(parts, string.format("[repeat:: %s]", data["repeat"]))
	end
	if data["created"] and data["created"] ~= "" then
		table.insert(parts, string.format("[created:: %s]", data["created"]))
	end
	if data["start"] and data["start"] ~= "" then
		table.insert(parts, string.format("[start:: %s]", data["start"]))
	end
	if data["scheduled"] and data["scheduled"] ~= "" then
		table.insert(parts, string.format("[scheduled:: %s]", data["scheduled"]))
	end
	if data["due"] and data["due"] ~= "" then
		table.insert(parts, string.format("[due:: %s]", data["due"]))
	end

	local output = table.concat(parts, "  ")

	-- Update the original buffer
	vim.api.nvim_set_current_win(TaskNote.origin_win)

	if TaskNote.edit_lnum then
		-- Replace existing line in edit mode
		vim.api.nvim_buf_set_lines(TaskNote.origin_buf, TaskNote.edit_lnum, TaskNote.edit_lnum + 1, false, { output })
	else
		-- Insert new line in create mode
		local cursor_pos = vim.api.nvim_win_get_cursor(TaskNote.origin_win)
		vim.api.nvim_buf_set_lines(TaskNote.origin_buf, cursor_pos[1], cursor_pos[1], false, { output })
	end

	-- Cleanup
	TaskNote.edit_lnum = nil
	local popup_win = vim.fn.bufwinid(popup_buf)
	if popup_win and popup_win ~= -1 then
		vim.api.nvim_win_close(popup_win, true)
	end
end

-- Create command for task creation/editing
vim.api.nvim_create_user_command("TaskCreateOrEdit", function()
	TaskNote.create()
end, {})

return TaskNote
