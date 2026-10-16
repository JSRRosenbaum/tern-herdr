-- Herdr's prefix keymap (its defaults overlaid with the user's config.toml) as Tern key sequences.

local M = {}

-- Herdr's defaults for the actions this plugin implements (`herdr --default-config`).
local DEFAULTS: { [string]: string } = {
	workspace_picker = "prefix+w",
	goto = "prefix+g",
	detach = "prefix+q",
	new_workspace = "prefix+shift+n",
	close_workspace = "prefix+shift+d",
	previous_workspace = "",
	next_workspace = "",
	switch_workspace = "",
	previous_agent = "",
	previous_herd = "",
	next_herd = "",
	next_agent = "",
	new_tab = "prefix+c",
	rename_tab = "prefix+shift+t",
	previous_tab = "prefix+p",
	next_tab = "prefix+n",
	switch_tab = "prefix+1..9",
	close_tab = "prefix+shift+x",
	focus_pane_left = "prefix+h",
	focus_pane_down = "prefix+j",
	focus_pane_up = "prefix+k",
	focus_pane_right = "prefix+l",
	cycle_pane_next = "prefix+tab",
	cycle_pane_previous = "prefix+shift+tab",
	last_pane = "",
	split_vertical = "prefix+v",
	split_horizontal = "prefix+minus",
	close_pane = "prefix+x",
	zoom = "prefix+z",
	toggle_sidebar = "prefix+b",
}

-- Herdr key names that Tern spells differently.
local NAMES: { [string]: string } = { minus = "-", plus = "+", equal = "=", comma = ",", period = ".", slash = "/" }

-- The character a shifted key types on a US layout, and back. Terminals report either form.
local SHIFTED: { [string]: string } = {
	["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%", ["6"] = "^", ["7"] = "&",
	["8"] = "*", ["9"] = "(", ["0"] = ")", ["-"] = "_", ["="] = "+", ["'"] = '"', [";"] = ":",
	[","] = "<", ["."] = ">", ["/"] = "?", ["["] = "{", ["]"] = "}", ["\\"] = "|", ["`"] = "~",
}
local UNSHIFTED: { [string]: string } = {}
for k, v in SHIFTED do
	UNSHIFTED[v] = k
end

export type Binding = { action: string, chord: string, keys: { string }, n: number? }

-- Every Tern spelling of one Herdr key spec after the prefix ("shift+n", "%", "minus").
local function spellings(spec: string): { string }
	local mods, key = {}, spec
	while true do
		local mod, rest = string.match(key, "^(%a+)%+(.+)$")
		if mod and (mod == "ctrl" or mod == "shift" or mod == "alt" or mod == "cmd" or mod == "super") then
			table.insert(mods, mod)
			key = rest
		else
			break
		end
	end
	key = NAMES[key] or key
	local shift = table.find(mods, "shift") ~= nil
	local out = { table.concat(mods, "+") .. (#mods > 0 and "+" or "") .. key }
	if shift and SHIFTED[key] then
		-- shift+5 also arrives as "%".
		local others = {}
		for _, m in mods do
			if m ~= "shift" then
				table.insert(others, m)
			end
		end
		table.insert(out, table.concat(others, "+") .. (#others > 0 and "+" or "") .. SHIFTED[key])
	elseif #mods == 0 and UNSHIFTED[key] then
		-- "%" also arrives as shift+5.
		table.insert(out, "shift+" .. UNSHIFTED[key])
	end
	return out
end

-- Reads `[keys]` from Herdr's config.toml text: `name = "value"` lines only.
local function read_keys(toml: string): { [string]: string }
	local keys, section = {}, ""
	for line in string.gmatch(toml .. "\n", "([^\n]*)\n") do
		local trimmed = string.match(line, "^%s*(.-)%s*$")
		local header = string.match(trimmed, "^%[([^%]]+)%]")
		if header then
			section = header
		elseif section == "keys" and not string.match(trimmed, "^#") then
			local name, value = string.match(trimmed, '^([%w_]+)%s*=%s*"(.-)"%s*$')
			if name then
				keys[name] = (string.gsub(value, '\\"', '"'))
			end
		end
	end
	return keys
end

-- The byte a ctrl+letter prefix sends.
local function ctrl_byte(prefix: string): string?
	if prefix == "ctrl+space" then
		return "\0"
	end
	local letter = string.match(prefix, "^ctrl%+(%a)$")
	if letter then
		return string.char(string.byte(string.lower(letter)) - 96)
	end
	return nil
end

function M.load(toml: string): { prefix: string, prefix_byte: string?, bindings: { Binding } }
	local user = read_keys(toml)
	local prefix = user.prefix or "ctrl+b"
	local bindings = {}
	for action, default in DEFAULTS do
		local spec = user[action] or default
		local rest = string.match(spec, "^prefix%+(.+)$")
		local chord_prefix = rest and (prefix .. ">") or ""
		rest = rest or spec
		if rest ~= "" then
			local base, from, to = string.match(rest, "^(.-)(%d)%.%.(%d)$")
			if base then
				for n = tonumber(from) :: number, tonumber(to) :: number do
					local keys = {}
					for _, s in spellings(base .. n) do
						table.insert(keys, chord_prefix .. s)
					end
					table.insert(bindings, { action = action, chord = keys[1], keys = keys, n = n })
				end
			else
				local keys = {}
				for _, s in spellings(rest) do
					table.insert(keys, chord_prefix .. s)
				end
				table.insert(bindings, { action = action, chord = keys[1], keys = keys })
			end
		end
	end
	table.sort(bindings, function(a, b)
		return a.chord < b.chord
	end)
	return { prefix = prefix, prefix_byte = ctrl_byte(prefix), bindings = bindings }
end

-- Build an opt-in user-layer overlay from Tern's effective keymap, not guessed defaults.
-- `effective` comes from cx.actions:keys() before this overlay is installed. Preserve
-- every pre-existing action as a fallback when the Herdr command is unavailable.
function M.proposal(bindings: { Binding }, prefix: string, effective: { [string]: { string } },
	user: { [string]: string | { string } }): { keybinds: { [string]: string | { string } }, blocked: { string } }
	local keybinds = table.clone(user)
	local blocked = {}
	local occupied_prefix = effective[prefix]
	if occupied_prefix and #occupied_prefix > 0 then
		table.insert(blocked, prefix .. " already runs a single-chord action; sequences cannot share it")
	end

	local requested: { [string]: string } = {}
	local function add(chord: string, action: string)
		local previous = requested[chord]
		if previous and previous ~= action then
			table.insert(blocked, chord .. " has two Herdr actions: " .. previous .. " and " .. action)
			return
		end
		requested[chord] = action
		local prior = user[chord]
		if prior == "unbind" or (type(prior) == "table" and #prior == 0) then
			-- An explicit user unbind is intentional; do not silently undo it.
			return
		end
		local actions = { action }
		local fallback = prior or effective[chord] or {}
		if type(fallback) == "string" then
			fallback = { fallback }
		end
		for _, candidate in fallback do
			if candidate ~= action and not string.match(candidate, "^plugin%.herdr%.key_") then
				table.insert(actions, candidate)
			end
		end
		keybinds[chord] = actions
	end

	for _, b in bindings do
		for _, chord in b.keys do
			add(chord, "plugin.herdr.key_" .. b.action .. (b.n and ("_" .. b.n) or ""))
		end
	end
	add(prefix .. ">" .. prefix, "plugin.herdr.key_send_prefix")
	return { keybinds = keybinds, blocked = blocked }
end

function M.title(action: string): string
	local words = {}
	for word in string.gmatch(action, "[^_]+") do
		table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
	end
	return table.concat(words, " ")
end

return M
