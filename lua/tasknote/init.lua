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

-- Allow users to override config
function TaskNote.setup(opts)
	TaskNote.config = vim.tbl_deep_extend("force", TaskNote.config, opts or {})
end

local defaults = {
	height = 12,
	width = 60,
	border = "single",
}

local fields = {
	{ name = "description", type = "string" },
	{ name = "priority", type = "select", options = { "none", "lowest", "low", "medium", "high", "highest" } },
	{ name = "created", type = "date" },
	{ name = "start", type = "date" },
	{ name = "scheduled", type = "date" },
	{ name = "due", type = "date" },
}

-- We'll store the original buffer and window here.
TaskNote.origin_buf = nil
TaskNote.origin_win = nil

function TaskNote.create()
	-- Save the original buffer and window.
	TaskNote.origin_buf = vim.api.nvim_get_current_buf()
	TaskNote.origin_win = vim.api.nvim_get_current_win()

	-- Create a scratch buffer for the popup.
	local buf = vim.api.nvim_create_buf(false, true)

	-- Set buffer options using nvim_set_option_value().
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_set_option_value("readonly", false, { buf = buf })

	vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = defaults.width,
		height = defaults.height,
		col = (vim.o.columns - defaults.width) / 2,
		row = (vim.o.lines - defaults.height) / 2,
		style = "minimal",
		border = defaults.border,
	})

	-- Initial content: one line per field.
	local lines = {}
	for _, field in ipairs(fields) do
		table.insert(lines, field.name .. ": ")
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Set key mappings using configured keys.
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

	-- Auto-enter insert mode for the description field.
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
			prompt = "Enter date (today/tomorrow/yesterday/Monday/etc): ",
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
	-- Get the lines from the popup buffer.
	local popup_buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)

	-- Parse each line "field: value".
	local data = {}
	for _, line in ipairs(lines) do
		local key, value = line:match("^(.-):%s*(.*)$")
		if key then
			data[key] = value
		end
	end

	-- Build the output string using the global filter from config.
	local parts = { "- [ ]" }
	if data["description"] and data["description"] ~= "" then
		table.insert(parts, TaskNote.config.global_filter .. " " .. data["description"])
	end
	if data["priority"] and data["priority"] ~= "" then
		table.insert(parts, string.format("[priority:: %s]", data["priority"]))
	end

	table.insert(parts, "[repeat:: never]") -- fixed value; adjust as needed.

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

	-- Switch back to the original window and insert the output.
	vim.api.nvim_set_current_win(TaskNote.origin_win)
	local cursor_pos = vim.api.nvim_win_get_cursor(TaskNote.origin_win)
	vim.api.nvim_buf_set_lines(TaskNote.origin_buf, cursor_pos[1], cursor_pos[1], false, { output })

	-- Close the popup window.
	local popup_win = vim.fn.bufwinid(popup_buf)
	if popup_win and popup_win ~= -1 then
		vim.api.nvim_win_close(popup_win, true)
	end
end

-- Create a command for launching the task creator.
vim.api.nvim_create_user_command("TaskCreate", function()
	require("tasknote").create()
end, {})

return TaskNote
