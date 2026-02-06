-- luacheck: globals vim
-- Buffer rendering

local config = require("buffer-sticks.config")
local state = require("buffer-sticks.state")
local buffers_mod = require("buffer-sticks.buffers")
local window = require("buffer-sticks.window")
local fuzzy = require("buffer-sticks.fuzzy")

local M = {}

---Right-align lines within a given width by padding with spaces
---@param lines string[] Lines to align
---@param width number Target width for alignment
---@return string[] aligned_lines Right-aligned lines
local function right_align_lines(lines, width)
	local aligned_lines = {}
	for _, line in ipairs(lines) do
		local content_width = vim.fn.strwidth(line)
		local padding = width - content_width
		local aligned_line = string.rep(" ", math.max(0, config.padding.left + padding))
			.. line
			.. string.rep(" ", math.max(0, config.padding.right))
		table.insert(aligned_lines, aligned_line)
	end
	return aligned_lines
end

---Apply vertical padding (top and bottom) to lines
---@param lines string[] Lines to add vertical padding to
---@return string[] padded_lines Lines with top and bottom padding applied
local function vertical_align_lines(lines)
	local padded_lines = {}

	for _ = 1, config.padding.top do
		table.insert(padded_lines, lines[1] and string.rep(" ", vim.fn.strwidth(lines[1])) or "")
	end

	for _, line in ipairs(lines) do
		table.insert(padded_lines, line)
	end

	for _ = 1, config.padding.bottom do
		table.insert(padded_lines, lines[1] and string.rep(" ", vim.fn.strwidth(lines[1])) or "")
	end

	return padded_lines
end

---Apply fuzzy filter to buffers based on current filter input
---@param buffers table[] List of buffers to filter
---@param display_paths table<integer, string> Map of buffer.id to display path
---@return integer[] filtered_indices Indices of matched buffers
function M.apply_fuzzy_filter(buffers, display_paths)
	local candidates = {}
	for _, buffer in ipairs(buffers) do
		local display_name = display_paths[buffer.id] or vim.fn.fnamemodify(buffer.name, ":t")
		table.insert(candidates, display_name)
	end

	local filter_config = config.list and config.list.filter or {}
	local cutoff = filter_config.fuzzy_cutoff or 100
	local _, filtered_indices = fuzzy.filtersort(state.filter_input, candidates, cutoff)
	return filtered_indices
end

---Sort buffers based on configured sort option
---@param buffers table[] List of buffers to sort
---@param display_paths table<integer, string> Map of buffer.id to display path
---@return table[] sorted_buffers Sorted buffers
local function sort_buffers(buffers, display_paths)
	local sort_config = config.list and config.list.sort or nil
	if not sort_config then
		return buffers
	end

	local sort_field = sort_config.field or "filename"
	local ascending = sort_config.ascending ~= false -- 默认升序

	-- Create a copy to avoid modifying the original buffers
	local sorted_buffers = vim.deepcopy(buffers)

	table.sort(sorted_buffers, function(a, b)
		local a_value, b_value
		if sort_field == "id" then
			a_value = a.id
			b_value = b.id
		elseif sort_field == "filename" then
			a_value = display_paths[a.id] or vim.fn.fnamemodify(a.name, ":t")
			b_value = display_paths[b.id] or vim.fn.fnamemodify(b.name, ":t")
		elseif sort_field == "label" then
			a_value = a.label or ""
			b_value = b.label or ""
		else
			--- If the field is not supported, keep the original order
			return false
		end

		if ascending then
			return a_value < b_value
		else
			return a_value > b_value
		end
	end)

	return sorted_buffers
end

---Get the stick character for a buffer
---@param buffer table Buffer info
---@return string char The stick character
---@return string hl_group The highlight group
local function get_stick_char(buffer)
	local char, hl_group
	if buffer.is_modified then
		if buffer.is_current then
			char = config.active_modified_char
			hl_group = "BufferSticksActiveModified"
		elseif buffer.is_alternate then
			char = config.alternate_modified_char
			hl_group = "BufferSticksAlternateModified"
		else
			char = config.inactive_modified_char
			hl_group = "BufferSticksInactiveModified"
		end
	else
		if buffer.is_current then
			char = config.active_char
			hl_group = "BufferSticksActive"
		elseif buffer.is_alternate then
			char = config.alternate_char
			hl_group = "BufferSticksAlternate"
		else
			char = config.inactive_char
			hl_group = "BufferSticksInactive"
		end
	end
	return char, hl_group
end

---Render buffer indicators in the floating window
function M.render()
	local current_tab = vim.api.nvim_get_current_tabpage()
	local win = state.wins[current_tab]

	if not vim.api.nvim_buf_is_valid(state.buf) or not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local buffers = buffers_mod.get_buffer_list()
	local lines = {}

	local display_paths = buffers_mod.get_display_paths(buffers)

	local filtered_buffers = buffers
	local filtered_indices = {}
	if state.filter_mode and state.filter_input ~= "" then
		filtered_indices = M.apply_fuzzy_filter(buffers, display_paths)
		filtered_buffers = {}
		for _, idx in ipairs(filtered_indices) do
			table.insert(filtered_buffers, buffers[idx])
		end
	else
		for i = 1, #buffers do
			table.insert(filtered_indices, i)
		end
	end

	-- 在应用过滤后进行排序
	filtered_buffers = sort_buffers(filtered_buffers, display_paths)

	local has_two_char = buffers_mod.has_two_char_label(filtered_buffers)

	if state.filter_mode then
		local filter_config = config.list and config.list.filter or {}
		local filter_title = #state.filter_input > 0 and (filter_config.title or "Filter: ")
			or (filter_config.title_empty or "Filter:   ")
		local padding = has_two_char and "   " or "  "
		local filter_prompt = filter_title .. state.filter_input .. padding
		table.insert(lines, filter_prompt)
	end

	for buffer_idx, buffer in ipairs(filtered_buffers) do
		local line_content
		local should_show_char = false

		local is_filter_selected = state.filter_mode and buffer_idx == state.filter_selected_index
		local is_list_selected = state.list_mode
			and not state.filter_mode
			and buffer_idx == state.list_mode_selected_index

		if config.label and config.label.show == "always" then
			should_show_char = true
		elseif config.label and config.label.show == "list" and state.list_mode then
			should_show_char = true
		end

		if state.list_mode and config.list and config.list.show then
			local show_filename = vim.list_contains(config.list.show, "filename")
			local show_space = vim.list_contains(config.list.show, "space")
			local show_label = vim.list_contains(config.list.show, "label")
			local show_stick = vim.list_contains(config.list.show, "stick")

			local parts = {}

			if show_stick then
				local stick_char = get_stick_char(buffer)
				table.insert(parts, stick_char)
			end

			if show_filename then
				local filename = display_paths[buffer.id] or vim.fn.fnamemodify(buffer.name, ":t")
				table.insert(parts, filename)
			end

			if show_label then
				local label_display = (#buffer.label == 1 and has_two_char) and " " .. buffer.label or buffer.label
				if state.filter_mode then
					if is_filter_selected then
						local fc = config.list and config.list.filter or {}
						local indicator = fc.active_indicator or "•"
						local padding_needed = #label_display - vim.fn.strwidth(indicator)
						table.insert(parts, indicator .. string.rep(" ", math.max(0, padding_needed)))
					else
						table.insert(parts, string.rep(" ", #label_display))
					end
				elseif is_list_selected then
					local lc = config.list or {}
					local indicator = lc.active_indicator or "•"
					local indicator_display = has_two_char and " " .. indicator or indicator
					table.insert(parts, indicator_display)
				else
					table.insert(parts, label_display)
				end
			end

			if show_space and #parts > 1 then
				line_content = table.concat(parts, " ")
			else
				line_content = table.concat(parts, "")
			end
		elseif should_show_char then
			local stick_char = get_stick_char(buffer)
			line_content = stick_char .. " " .. buffer.label
		else
			line_content = get_stick_char(buffer)
		end
		table.insert(lines, line_content)
	end

	local window_width = window.calculate_required_width()
	local aligned_lines = right_align_lines(lines, window_width)
	local final_lines = vertical_align_lines(aligned_lines)

	local ns_id = vim.api.nvim_create_namespace("BufferSticks")
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, final_lines)

	if state.filter_mode then
		local filter_line_idx = config.padding.top
		vim.hl.range(state.buf, ns_id, "BufferSticksFilterTitle", { filter_line_idx, 0 }, { filter_line_idx, -1 })
	end

	local line_offset = state.filter_mode and 1 or 0
	for i, buffer in ipairs(filtered_buffers) do
		local line_idx = i - 1 + config.padding.top + line_offset
		local line_content = final_lines[i + config.padding.top + line_offset]

		local is_filter_selected = state.filter_mode and i == state.filter_selected_index
		local is_list_selected = state.list_mode and not state.filter_mode and i == state.list_mode_selected_index

		if state.list_mode and config.list and config.list.show then
			local show_filename = vim.list_contains(config.list.show, "filename")
			local show_space = vim.list_contains(config.list.show, "space")
			local show_label = vim.list_contains(config.list.show, "label")
			local show_stick = vim.list_contains(config.list.show, "stick")

			local col_offset = 0
			local padding_match = line_content:match("^( *)")
			if padding_match then
				col_offset = #padding_match
			end

			if show_stick then
				local stick_char, hl_group = get_stick_char(buffer)
				if is_filter_selected then
					hl_group = "BufferSticksFilterSelected"
				elseif is_list_selected then
					hl_group = "BufferSticksListSelected"
				end
				local stick_width = vim.fn.strwidth(stick_char)
				vim.hl.range(
					state.buf,
					ns_id,
					hl_group,
					{ line_idx, col_offset },
					{ line_idx, col_offset + stick_width }
				)
				col_offset = col_offset + stick_width
			end

			if show_filename then
				local filename = display_paths[buffer.id] or vim.fn.fnamemodify(buffer.name, ":t")
				local filename_width = vim.fn.strwidth(filename)
				local hl_group
				if is_filter_selected then
					hl_group = "BufferSticksFilterSelected"
				elseif is_list_selected then
					hl_group = "BufferSticksListSelected"
				else
					local _
					_, hl_group = get_stick_char(buffer)
				end
				vim.hl.range(
					state.buf,
					ns_id,
					hl_group,
					{ line_idx, col_offset },
					{ line_idx, col_offset + filename_width }
				)
				col_offset = col_offset + filename_width

				if show_space and show_label then
					col_offset = col_offset + 1
				end
			elseif show_stick and show_space and show_label then
				col_offset = col_offset + 1
			end

			if show_label then
				if state.filter_mode then
					if is_filter_selected then
						local fc = config.list and config.list.filter or {}
						local indicator = fc.active_indicator or "•"
						local content_start = line_content:sub(col_offset + 1)
						local indicator_start_pos = content_start:find(vim.pesc(indicator))
						if indicator_start_pos then
							local byte_start = col_offset + indicator_start_pos - 1
							local byte_end = byte_start + #indicator
							vim.hl.range(
								state.buf,
								ns_id,
								"BufferSticksFilterSelected",
								{ line_idx, byte_start },
								{ line_idx, byte_end }
							)
						end
					end
				elseif is_list_selected then
					local lc = config.list or {}
					local indicator = lc.active_indicator or "•"
					local content_start = line_content:sub(col_offset + 1)
					local indicator_start_pos = content_start:find(vim.pesc(indicator))
					if indicator_start_pos then
						local byte_start = col_offset + indicator_start_pos - 1
						local byte_end = byte_start + #indicator
						vim.hl.range(
							state.buf,
							ns_id,
							"BufferSticksListSelected",
							{ line_idx, byte_start },
							{ line_idx, byte_end }
						)
					end
				else
					local content_start = line_content:sub(col_offset + 1)
					local label_start_pos = content_start:find(vim.pesc(buffer.label))

					if label_start_pos then
						local byte_start = col_offset + label_start_pos - 1
						local byte_end = byte_start + #buffer.label
						vim.hl.range(
							state.buf,
							ns_id,
							"BufferSticksLabel",
							{ line_idx, byte_start },
							{ line_idx, byte_end }
						)
					end
				end
			end
		else
			local hl_group
			if is_filter_selected then
				hl_group = "BufferSticksFilterSelected"
			elseif is_list_selected then
				hl_group = "BufferSticksListSelected"
			else
				local _
				_, hl_group = get_stick_char(buffer)
			end
			vim.hl.range(state.buf, ns_id, hl_group, { line_idx, 0 }, { line_idx, -1 })
		end
	end
end

return M
