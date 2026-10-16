-- Host half: the Herdr sidebar block (machines, spaces, agents, menu) and the tab strip block that
-- sits above the sidebar's terminal. Both draw natively and drive the linked terminal pane.

local common = require("./common")
local keymap = require("./keymap")
local ui = tern.ui

local POLL_MS = 1500

local DOT = { blocked = "●", working = "●", done = "●", idle = "○", unknown = "?", offline = "?" }

-- The rail receives direct configured herd keys even when native attach is unavailable.
local herd_bindings = keymap.load(common.herdr_config()).bindings
local function herd_step(key: Key): number?
	for _, binding in herd_bindings do
		if binding.action == "previous_herd" or binding.action == "next_herd" then
			for _, spec in binding.keys do
				if not string.find(spec, ">", 1, true) then
					local name = string.match(spec, "([^+]+)$")
					if name == key.name and (string.find(spec, "ctrl+", 1, true) ~= nil) == key.ctrl
						and (string.find(spec, "alt+", 1, true) ~= nil) == key.alt
						and (string.find(spec, "shift+", 1, true) ~= nil) == key.shift
						and ((string.find(spec, "cmd+", 1, true) ~= nil) or (string.find(spec, "super+", 1, true) ~= nil)) == key.meta then
						return binding.action == "next_herd" and 1 or -1
					end
				end
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Shared

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function el(tag: string, class: string, text: string?, children: { Node }?, click: string?): Node
	local props: { [string]: any } = { class = class }
	if text then
		props.text = text
	end
	if click then
		props.actions = { click = click }
	end
	return ui.el(tag, props, children)
end

local function dot(status: string): Node
	local node = el("span", "hs-dot", DOT[status] or "·")
	local p = node.p :: { [string]: any }
	p.attrs = { ["data-state"] = status }
	return node
end

local function linked_term(link: string): number?
	local term = tern.kv.get("link:" .. link)
	if type(term) == "number" and alive(term) then
		return term
	end
	return nil
end

local function err_text(res: any): string
	local ok, doc = pcall(tern.json.decode, res.stdout)
	if ok and type(doc) == "table" and doc.error then
		return tostring(doc.error.message or doc.error)
	end
	return (string.gsub(res.stderr .. res.stdout, "%s+$", ""))
end

-- Runs `herdr ARGS` on `machine`; `done` gets the decoded result.
local function herdr(cx: EffectCx, machine: string, args: { string }, done: ((any) -> ())?)
	tern.process.run(common.argv(machine, args), { timeout_ms = 10000 }, function(res)
		local ok, doc = pcall(tern.json.decode, res.stdout)
		if res.status ~= 0 or not ok or type(doc) ~= "table" or doc.error then
			cx:toast("error", "herdr " .. args[1] .. " " .. (args[2] or "") .. " failed", err_text(res))
			return
		end
		if done then
			done(doc.result)
		end
	end)
end

-- Shows a Herdr terminal in the link's pane, splitting one off `beside` when there is none.
local function show_terminal(cx: EffectCx, link: string, beside: number, machine: string, terminal_id: string)
	local profile = common.machine(machine)
	if not profile or not profile.attach_supported then
		cx:toast("error", "Cannot attach to this Herdr terminal",
			profile and (profile.label .. " needs local Herdr scoped-terminal-attach-v2") or "Saved machine profile is unavailable")
		return
	end
	local term = linked_term(link)
	common.retarget(link, machine, terminal_id)
	if term then
		return
	end
	local argv = { common.tern, "split", tostring(beside), "right", "--json", "--", "sh",
		tern.plugin.dir .. "/follow.sh", common.target_file(link), common.herdr }
	tern.process.run(argv, { timeout_ms = 10000 }, function(res)
		if res.status ~= 0 then
			cx:toast("error", "Could not open a terminal", err_text(res))
			return
		end
		local ok, doc = pcall(tern.json.decode, res.stdout)
		local pane = ok and type(doc) == "table" and (doc.block or doc.pane)
		if type(pane) == "number" then
			tern.kv.set("link:" .. link, pane)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Sidebar

type SidebarState = {
	link: string,
	pane: number,
	machine: string,
	machines: { common.Machine },
	herd: number,
	herd_count: number,
	org_error: string?,
	snaps: { [string]: common.Snapshot },
	snap: common.Snapshot?,
	collapsed: { [string]: boolean },
	last: { [string]: string }, -- herd number as JSON object key -> "profile|terminal"
	last_profile: { [string]: string },
	desired: string?,
	external_selection: string?,
	sel: number,
	split: number,
	menu: boolean,
	confirm: string?,
	integrations: { common.Integration }?,
	ticks: number,
	closed: boolean,
}

local function agents(state: SidebarState): { common.Agent }
	return state.snap and state.snap.agents or {}
end

local function shown(state: SidebarState): (string?, string?)
	return common.link_target(state.link)
end

local function observed_selection(): (number?, string?, string?)
	local herd = tern.kv.get("herd:selected")
	if type(herd) ~= "number" then
		return nil, nil, nil
	end
	local remembered = tern.kv.get("herd:last:" .. herd)
	local key = type(remembered) == "string" and remembered or nil
	return herd, key, tostring(herd) .. "|" .. (key or "")
end

local function clamp(state: SidebarState)
	state.sel = math.clamp(state.sel, 1, math.max(1, #agents(state)))
end

local function select_terminal(state: SidebarState, terminal_id: string)
	for i, a in agents(state) do
		if a.terminal_id == terminal_id then
			state.sel = i
		end
	end
end

local function attach_agent(state: SidebarState, cx: EffectCx, a: common.Agent)
	local profile = common.machine(a.machine)
	if a.terminal_id == "" or not profile or not profile.attach_supported
		or (state.snaps[a.machine] and state.snaps[a.machine].err) then
		if profile and not profile.attach_supported then
			cx:toast("error", "Herdr terminal attach unavailable", "Local Herdr needs scoped-terminal-attach-v2; inventory only")
		end
		return
	end
	state.machine = a.machine
	state.snap = state.snaps[a.machine]
	state.last[tostring(state.herd)] = a.machine .. "|" .. a.terminal_id
	tern.kv.set("herd:selected", state.herd)
	tern.kv.set("herd:last:" .. state.herd, a.machine .. "|" .. a.pane_id)
	state.last_profile[a.machine] = a.terminal_id
	show_terminal(cx, state.link, state.pane, a.machine, a.terminal_id)
	cx:save()
end

local function tab_pane(snap: common.Snapshot, tab_id: string): common.Pane?
	local panes = common.panes_of(snap, tab_id)
	for _, p in panes do
		if p.focused then return p end
	end
	return panes[1]
end

local function space_pane(snap: common.Snapshot, w: common.Workspace): common.Pane?
	local tabs = common.tabs_of(snap, w.id)
	for _, tab in tabs do
		if tab.id == w.active_tab then
			return tab_pane(snap, tab.id)
		end
	end
	return tabs[1] and tab_pane(snap, tabs[1].id)
end

local function attach_space(state: SidebarState, cx: EffectCx, machine: string, workspace_id: string)
	local snap = state.snaps[machine]
	if not snap or snap.err then
		return
	end
	local profile = common.machine(machine)
	if not profile or not profile.attach_supported then
		cx:toast("error", "Herdr viewer unavailable", "Local HERDR_BIN needs scoped-terminal-attach-v2; inventory only")
		return
	end
	for _, w in snap.workspaces do
		if w.id == workspace_id then
			local p = space_pane(snap, w)
			if p and p.terminal_id ~= "" then
				state.machine = machine
				state.snap = snap
				state.last[tostring(state.herd)] = machine .. "|" .. p.terminal_id
				state.last_profile[machine] = p.terminal_id
				tern.kv.set("herd:selected", state.herd)
				tern.kv.set("herd:last:" .. state.herd, p.key)
				select_terminal(state, p.terminal_id)
				show_terminal(cx, state.link, state.pane, machine, p.terminal_id)
				cx:save()
			end
			return
		end
	end
end

-- The space the sidebar's terminal shows, else the focused one.
local function current_space(state: SidebarState): common.Workspace?
	local snap = state.snap
	if not snap then
		return nil
	end
	local machine, terminal = shown(state)
	local pane = machine == snap.machine and terminal and common.pane_by_terminal(snap, terminal)
	for _, w in snap.workspaces do
		if (pane and w.id == pane.workspace_id) or (not pane and w.focused) then
			return w
		end
	end
	return snap.workspaces[1]
end

local function space_cwd(state: SidebarState, w: common.Workspace?): string?
	local snap = state.snap
	if not snap or not w then
		return nil
	end
	for _, t in common.tabs_of(snap, w.id) do
		local p = common.panes_of(snap, t.id)[1]
		if p then
			return p.cwd
		end
	end
	return nil
end

-- Worktree and repo grouping comes from Herdr workspace metadata, never a git subprocess.
local INTEGRATIONS_EVERY = 40 -- polls between integration checks (about a minute)

local function check_integrations(state: SidebarState, cx: BlockCx)
	local machine = state.machine
	common.integrations(machine, function(list)
		if state.machine == machine and list then
			state.integrations = list
			pcall(cx.render, cx)
		end
	end)
end

local function install(state: SidebarState, cx: BlockCx, name: string)
	local machine = state.machine
	local profile = common.machine(machine)
	cx:toast("info", "Installing the " .. name .. " integration" .. (profile and (" on " .. profile.label) or ""))
	tern.process.run(common.argv(machine, { "integration", "install", name }), { timeout_ms = 60000 }, function(res)
		local out = string.gsub(res.stderr .. res.stdout, "%s+$", "")
		if res.status == 0 then
			cx:toast("success", name .. " integration installed", out)
		else
			cx:toast("error", name .. " integration failed", out)
		end
		check_integrations(state, cx)
	end)
end

local function needs_integrations(state: SidebarState): boolean
	for _, i in state.integrations or {} do
		if common.needs_install(i) then
			return true
		end
	end
	return false
end

local function select_herd(state: SidebarState, cx: BlockCx, herd: number, preferred: string?)
	if herd < 0 or herd >= state.herd_count then
		return
	end
	state.herd = herd
	tern.kv.set("herd:selected", herd)
	-- This selection originated here; an older shared last-pane key must not
	-- immediately redirect a newly chosen machine on the next poll.
	local _, _, observed = observed_selection()
	state.external_selection = observed
	state.desired = nil
	local previous = state.last[tostring(herd)]
	if preferred then
		local terminal = state.last_profile[preferred]
		previous = terminal and (preferred .. "|" .. terminal) or nil
	end
	if previous then
		local machine, terminal = string.match(previous, "^(.-)|(.+)$")
		local snap = machine and state.snaps[machine]
		local profile = machine and common.machine(machine)
		if profile and profile.herd == herd then
			state.machine, state.snap = machine, snap
			local p = snap and not snap.err and common.pane_by_terminal(snap, terminal)
			if p and p.terminal_id ~= "" and profile.attach_supported then
				select_terminal(state, terminal)
				show_terminal(cx, state.link, state.pane, machine, terminal)
				tern.kv.set("herd:last:" .. herd, p.key)
				cx:save()
				return
			elseif snap and snap.err then
				cx:toast("error", profile.label .. " unavailable", snap.err)
				cx:save()
				return
			elseif not snap then
				state.desired = previous
				cx:save()
				return
			end
		end
	end
	for _, profile in state.machines do
		if profile.herd == herd and (not preferred or profile.id == preferred) then
			state.machine = profile.id
			state.snap = state.snaps[profile.id]
			if not state.snap then
				state.desired = profile.id .. "|"
			end
			if state.snap and not state.snap.err and profile.attach_supported then
				for _, w in state.snap.workspaces do
					local p = space_pane(state.snap, w)
					if p and p.terminal_id ~= "" then
						state.last[tostring(herd)] = profile.id .. "|" .. p.terminal_id
						state.last_profile[profile.id] = p.terminal_id
						select_terminal(state, p.terminal_id)
						tern.kv.set("herd:last:" .. herd, p.key)
						show_terminal(cx, state.link, state.pane, profile.id, p.terminal_id)
						break
					end
				end
			end
			break
		end
	end
	cx:save()
end

local function poll(state: SidebarState, cx: BlockCx, again: boolean)
	if state.closed or not alive(state.pane) then
		state.closed = true
		return
	end
	local count, _, _, err = common.organization()
	state.herd_count, state.org_error = count, err
	state.machines = common.machines()
	local requested, key, selection = observed_selection()
	if not err and requested and requested >= 0 and requested < count then
		if selection ~= state.external_selection then
			state.external_selection = selection
			local machine = type(key) == "string" and string.match(key, "^(.-)|") or nil
			local profile = machine and common.machine(machine)
			if profile and profile.herd == requested then
				state.herd, state.machine = requested, machine
				state.snap = state.snaps[machine]
				state.desired = key
				cx:save()
			elseif requested ~= state.herd then
				select_herd(state, cx, requested)
			end
		end
	end
	state.herd = math.min(state.herd, count - 1)
	local selected = common.machine(state.machine)
	if not selected or (not err and selected.herd ~= state.herd) then
		local found = false
		for _, profile in state.machines do
			if profile.herd == state.herd then
				state.machine = profile.id
				found = true
				break
			end
		end
		if not found then
			state.snap = nil
		end
	end
	local active = {}
	for _, profile in state.machines do
		if err or profile.herd == state.herd then
			table.insert(active, profile)
		end
	end
	local pending = #active
	for _, profile in active do
			common.snapshot(profile.id, function(snap)
				if state.closed then
					return
				end
				state.snaps[profile.id] = snap
				if state.machine == profile.id then
					local selected_agent = agents(state)[state.sel]
					local selected_terminal = selected_agent and selected_agent.terminal_id
					state.snap = snap
					local desired = state.desired
					local desired_profile, wanted = nil, nil
					if desired then
						desired_profile, wanted = string.match(desired, "^(.-)|(.*)$")
					end
					if desired_profile == profile.id and wanted and not snap.err and profile.attach_supported then
						local pane = wanted ~= "" and (snap.panes[wanted] or common.pane_by_terminal(snap, wanted))
						if not pane then
							for _, w in snap.workspaces do
								pane = space_pane(snap, w)
								if pane and pane.terminal_id ~= "" then break end
							end
						end
						if pane and pane.terminal_id ~= "" then
							state.last[tostring(state.herd)] = profile.id .. "|" .. pane.terminal_id
							state.last_profile[profile.id] = pane.terminal_id
							tern.kv.set("herd:last:" .. state.herd, pane.key)
							select_terminal(state, pane.terminal_id)
							show_terminal(cx, state.link, state.pane, profile.id, pane.terminal_id)
							cx:save()
						end
						state.desired = nil
					elseif selected_terminal then
						select_terminal(state, selected_terminal)
					end
					clamp(state)
				end
				pcall(cx.render, cx)
				pending -= 1
				if pending == 0 and again then
					tern.timer(POLL_MS, function()
						poll(state, cx, true)
					end)
				end
			end)
	end
	if state.ticks % INTEGRATIONS_EVERY == 0 then
		check_integrations(state, cx)
	end
	state.ticks += 1
	if #active == 0 then
		pcall(cx.render, cx)
		if again then
			tern.timer(POLL_MS, function()
				poll(state, cx, true)
			end)
		end
	end
end

local function switch_machine(state: SidebarState, cx: BlockCx, machine: string)
	local profile = common.machine(machine)
	if not profile then
		return
	end
	if state.org_error then
		state.machine, state.snap = machine, state.snaps[machine]
		cx:save()
		return
	end
	state.herd = profile.herd
	state.machine = machine
	state.snap = state.snaps[machine]
	state.integrations = nil
	state.ticks = 0
	select_herd(state, cx, profile.herd, machine)
	poll(state, cx, false)
end

-- Menu and bar actions. Destructive ones need a second click.
local function act(state: SidebarState, cx: BlockCx, name: string, value: string?)
	local machine = state.machine
	local profile = common.machine(state.machine)
	if (name == "new_space" or name == "new_tab" or name == "close_space" or name == "install")
		and (not profile or profile.herd ~= state.herd or (state.snap and state.snap.err)
			or (name ~= "install" and not profile.attach_supported)) then
		cx:toast("error", "Herdr action unavailable", state.snap and state.snap.err or "No reachable profile selected in this herd")
		return
	end
	local w = current_space(state)
	if name == "new_space" then
		local args = { "workspace", "create", "--no-focus" }
		local cwd = space_cwd(state, w)
		if cwd then
			table.insert(args, "--cwd")
			table.insert(args, cwd)
		end
		herdr(cx, machine, args, function(r)
			if r.root_pane and r.root_pane.terminal_id then
				show_terminal(cx, state.link, state.pane, machine, r.root_pane.terminal_id)
			end
			poll(state, cx, false)
		end)
	elseif name == "new_tab" and w then
		local args = { "tab", "create", "--workspace", w.id, "--no-focus" }
		local cwd = space_cwd(state, w)
		if cwd then
			table.insert(args, "--cwd")
			table.insert(args, cwd)
		end
		herdr(cx, machine, args, function(r)
			if r.root_pane and r.root_pane.terminal_id then
				show_terminal(cx, state.link, state.pane, machine, r.root_pane.terminal_id)
			end
			poll(state, cx, false)
		end)
	elseif name == "close_space" and w then
		if state.confirm ~= "close_space" then
			state.confirm = "close_space"
			return
		end
		herdr(cx, machine, { "workspace", "close", w.id }, function()
			poll(state, cx, false)
		end)
	elseif name == "view_ansi" or name == "view_native" then
		local shown_machine, shown_terminal = common.link_target(state.link)
		if shown_machine and shown_terminal then
			local shown_profile = common.machine(shown_machine)
			if not shown_profile or not shown_profile.attach_supported then
				cx:toast("error", "Herdr viewer unavailable", "Upgrade local HERDR_BIN to scoped-terminal-attach-v2; inventory only")
				return
			end
			common.set_view_mode(shown_machine, shown_terminal, if name == "view_ansi" then "ansi" else "native")
			common.retarget(state.link, shown_machine, shown_terminal)
		end
	elseif name == "machine" and value then
		switch_machine(state, cx, value)
	elseif name == "herd" and value then
		if not state.org_error then
			select_herd(state, cx, tonumber(value) or -1)
			poll(state, cx, false)
		end
	elseif name == "group" and value then
		state.collapsed[value] = not state.collapsed[value]
		cx:save()
	elseif name == "install" and value then
		install(state, cx, value)
	elseif name == "mirror" then
		if tern.kv.get("mirror") ~= nil then
			tern.kv.set("mirror_stop", true)
		else
			tern.kv.set("mirror", {})
		end
	elseif name == "refresh" then
		state.ticks = 0
		poll(state, cx, false)
	elseif name == "up" then
		state.split = math.max(0.1, state.split - 0.1)
		cx:save()
	elseif name == "down" then
		state.split = math.min(0.9, state.split + 0.1)
		cx:save()
	end
	state.confirm = nil
	state.menu = false
end

-- Herdr's repo_key (not a cwd prefix) defines a repo/worktree group.
local function space_rows(state: SidebarState, snap: common.Snapshot): { Node }
	local machine, terminal = shown(state)
	local rows: { any } = {}
	local groups: { [string]: { common.Workspace } } = {}
	local function workspace(w: common.Workspace, nested: boolean): { Node }
		local out: { Node } = {}
		local pane: common.Pane? = nil
		if machine == snap.machine and terminal then
			pane = common.pane_by_terminal(snap, terminal)
		end
		local on = pane ~= nil and pane.workspace_id == w.id
		local wt = w.worktree
		local label = wt and wt.is_linked_worktree and ("↳ " .. w.label) or w.label
		table.insert(out, el("div", "hs-row" .. (nested and " hs-nested" or "") .. (on and " hs-on" or ""),
			nil, { el("div", "hs-line", nil, { dot(snap.err and "offline" or w.status),
				el("span", "hs-name", label), el("span", "hs-id", w.id) }) },
			"space=" .. snap.machine .. "|" .. w.id))
		if on and not snap.err then
			local chips = {}
			for _, t in common.tabs_of(snap, w.id) do
				table.insert(chips, el("span", "hs-tab" .. (pane and t.id == pane.tab_id and " hs-tab-on" or ""),
					nil, { dot(t.status), el("span", "", t.label) }, "tab=" .. snap.machine .. "|" .. t.id))
			end
			table.insert(chips, el("span", "hs-tab hs-tab-new", "+", nil, "new_tab"))
			table.insert(out, el("div", "hs-tabs", nil, chips))
		end
		return out
	end
	for _, w in snap.workspaces do
		local wt = w.worktree
		if wt and wt.repo_key and wt.repo_key ~= "" then
			if not groups[wt.repo_key] then
				groups[wt.repo_key] = {}
				table.insert(rows, { key = wt.repo_key, name = wt.repo_name or common.basename(wt.repo_root or ""), children = groups[wt.repo_key] })
			end
			table.insert(groups[wt.repo_key], w)
		else
			table.insert(rows, w)
		end
	end
	local result: { Node } = {}
	for _, item in rows do
		if item.key then
			local key = snap.machine .. "|" .. item.key
			local collapsed = state.collapsed[key] == true
			table.insert(result, el("div", "hs-head hs-group hs-btn", nil, {
				el("span", "hs-arrow", collapsed and "▸" or "▾"),
				el("span", "hs-name", item.name),
				el("span", "hs-id", tostring(#item.children)),
			}, "group=" .. key))
			if not collapsed then
				for _, w in item.children do
					for _, row in workspace(w, true) do
						table.insert(result, row)
					end
				end
			end
		else
			for _, row in workspace(item, false) do
				table.insert(result, row)
			end
		end
	end
	return result
end

local function agent_rows(state: SidebarState, snap: common.Snapshot): { Node }
	local machine, terminal = shown(state)
	local rows: { Node } = {}
	for _, a in snap.agents do
		local w: common.Workspace? = nil
		for _, entry in snap.workspaces do
			if entry.id == a.workspace_id then
				w = entry
				break
			end
		end
		local group = w and w.worktree and w.worktree.repo_key
		if not group or not state.collapsed[snap.machine .. "|" .. group] then
			local class = "hs-row hs-agent"
			if machine == a.machine and terminal == a.terminal_id then
				class ..= " hs-on"
			end
			if snap.machine == state.machine and agents(state)[state.sel] == a then
				class ..= " hs-sel"
			end
			local row = el("div", class, nil, {
				el("div", "hs-line", nil, { dot(snap.err and "offline" or a.status),
					el("span", "hs-name", w and w.label or common.basename(a.cwd)),
					el("span", "hs-id", a.workspace_id) }),
				el("div", "hs-sub", a.agent .. (a.title ~= "" and (" · " .. a.title) or "")),
			}, "pick=" .. snap.machine .. "|" .. a.terminal_id)
			local p = row.p :: { [string]: any }
			p.title = common.label(a) .. " (" .. (snap.err and "offline" or a.status) .. ")"
			table.insert(rows, row)
		end
	end
	return rows
end

local function menu_view(state: SidebarState): Node
	local w = current_space(state)
	local items: { Node } = {}
	local function item(label: string, click: string, class: string?)
		table.insert(items, el("div", "hs-mi" .. (class and (" " .. class) or ""), label, nil, click))
	end
	local profile = common.machine(state.machine)
	if profile and profile.attach_supported and profile.herd == state.herd and state.snap and not state.snap.err then
		item("New space", "new_space")
	end
	if w and profile and profile.attach_supported and profile.herd == state.herd and state.snap and not state.snap.err then
		item("New tab in " .. w.label, "new_tab")
		if state.confirm == "close_space" then
			item("Click again to close " .. w.label, "close_space", "hs-danger")
		else
			item("Close space " .. w.label .. "…", "close_space")
		end
	end
	local shown_machine, shown_terminal, shown_mode = common.link_target(state.link)
	if shown_machine and shown_terminal then
		item((shown_mode == "ansi" and "● " or "○ ") .. "Use ANSI screen", "view_ansi")
		item((shown_mode == "native" and "● " or "○ ") .. "Use Native TSP", "view_native")
	end
	table.insert(items, el("div", "hs-msep", ""))
	if state.integrations then
		local installed = 0
		for _, i in state.integrations do
			if common.needs_install(i) then
				local verb = i.state == "outdated" and "Update" or "Install"
				item("● " .. verb .. " " .. i.name .. " integration", "install=" .. i.name, "hs-attn")
			elseif i.state == "current" then
				installed += 1
			end
		end
		local profile = common.machine(state.machine)
		table.insert(items, el("div", "hs-mnote", installed .. " integrations installed" .. (profile and (" on " .. profile.label) or "")))
		table.insert(items, el("div", "hs-msep", ""))
	end
	if #state.machines > 1 then
		for _, m in state.machines do
			item((m.id == state.machine and "● " or "○ ") .. m.label .. (state.org_error and " · membership unknown" or (" · herd " .. m.herd)), "machine=" .. m.id)
		end
		table.insert(items, el("div", "hs-msep", ""))
	end
	item(tern.kv.get("mirror") ~= nil and "Close Tern tabs (mirror off)" or "Open as Tern tabs (mirror on)", "mirror")
	item("Refresh", "refresh")
	item("Close menu", "menu")
	return el("div", "hs-menu", nil, items)
end

local sidebar: BlockDef<SidebarState> = {
	init = function(cx, args, saved)
		local link = (saved and saved.link) or args[1] or common.new_link()
		local machines = common.machines()
		local count, selected, _, org_error = common.organization()
		local requested_machine = if args[2] ~= "" then args[2] else nil
		local machine = (saved and saved.machine) or requested_machine or "local/default"
		local profile = common.machine(machine)
		if not profile then
			machine = "local/default"
			profile = common.machine(machine)
		end
		local herd = profile and profile.herd >= 0 and profile.herd or selected
		if saved and type(saved.herd) == "number" and saved.herd >= 0 and saved.herd < count then
			herd = saved.herd
		elseif not requested_machine and not (saved and saved.machine) then
			local requested_herd = tonumber(args[3])
			herd = if requested_herd and requested_herd >= 0 and requested_herd < count
				then requested_herd else selected
		end
		local last = saved and saved.last or {}
		local last_profile = saved and saved.last_profile or {}
		local linked_machine, linked_terminal = common.link_target(link)
		if linked_machine and linked_terminal then
			local linked_profile = common.machine(linked_machine)
			if linked_profile then
				last[tostring(linked_profile.herd)] = linked_machine .. "|" .. linked_terminal
				last_profile[linked_machine] = linked_terminal
			end
		end
		local _, _, observed = observed_selection()
		local state: SidebarState = {
			link = link,
			pane = cx.pane,
			machine = machine,
			machines = machines,
			herd = herd,
			herd_count = count,
			external_selection = observed,
			org_error = org_error,
			snaps = {},
			snap = nil,
			collapsed = saved and saved.collapsed or common.collapsed(),
			last = last,
			last_profile = last_profile,
			sel = 1,
			split = saved and saved.split or 0.5,
			menu = false,
			confirm = nil,
			integrations = nil,
			ticks = 0,
			closed = false,
		}
		local links = tern.kv.get("links") or {}
		links[tostring(cx.pane)] = link
		tern.kv.set("links", links)
		common.refresh_attach_support(function()
			if not state.closed then
				state.machines = common.machines()
				pcall(cx.render, cx)
			end
		end)
		-- The host registers this pane only after init returns.
		tern.timer(1, function()
			poll(state, cx, true)
		end)
		return state
	end,

	save = function(state)
		return { link = state.link, machine = state.machine, herd = state.herd,
			split = state.split, collapsed = state.collapsed, last = state.last, last_profile = state.last_profile }
	end,

	title = function(state)
		local snap = state.snap
		local c = common.counts(snap and not snap.err and snap.agents or {})
		local profile = common.machine(state.machine)
		local name = "herdr · " .. (profile and profile.label or "herd " .. state.herd)
		return c.blocked and (name .. " · " .. c.blocked .. " blocked") or name
	end,

	view = function(state, _cx)
		local body: { Node } = {}
		local tabs: { Node } = {}
		if state.org_error then
			table.insert(tabs, el("span", "hs-chip hs-chip-on", "membership unknown"))
		else
			for herd = 0, state.herd_count - 1 do
				table.insert(tabs, el("span", "hs-chip" .. (herd == state.herd and " hs-chip-on" or ""),
					"herd " .. herd, nil, "herd=" .. herd))
			end
		end
		table.insert(body, el("div", "hs-herds", nil, tabs))
		if state.org_error then
			table.insert(body, el("div", "hs-err", "Herdr herd membership unavailable: " .. state.org_error))
		end
		local native = common.machine("local/default")
		if not native or not native.attach_supported then
			table.insert(body, el("div", "hs-err", "Local HERDR_BIN needs scoped-terminal-attach-v2; inventory only"))
		end
		local spaces: { Node } = { el("div", "hs-head", "spaces") }
		local list: { Node } = { el("div", "hs-head", "agents") }
		local found = false
		for _, profile in state.machines do
			if state.org_error or profile.herd == state.herd then
				found = true
				local snap = state.snaps[profile.id]
				local machine_title = profile.label .. (profile.target ~= "local" and profile.session ~= "default" and (" · " .. profile.session) or "")
				local status = snap and (snap.err and "offline" or (snap.agents[1] and snap.agents[1].status or "unknown")) or "unknown"
				local heading = el("div", "hs-machine hs-btn" .. (profile.id == state.machine and " hs-machine-on" or ""),
					nil, { dot(status), el("span", "hs-name", machine_title) }, "machine=" .. profile.id)
				table.insert(spaces, heading)
				table.insert(list, el("div", "hs-machine", nil, { dot(status), el("span", "hs-name", machine_title) }))
				if snap then
					if snap.err then
						table.insert(spaces, el("div", "hs-err", "offline · " .. snap.err))
					end
					for _, row in space_rows(state, snap) do
						table.insert(spaces, row)
					end
					for _, row in agent_rows(state, snap) do
						table.insert(list, row)
					end
				else
					table.insert(spaces, el("div", "hs-sub", "loading " .. profile.label .. "…"))
				end
			end
		end
		if not found then
			table.insert(spaces, el("div", "hs-sub", "No saved machines in herd " .. state.herd))
		end
		local pct = math.floor(state.split * 10 + 0.5) * 10
		table.insert(body, el("div", "hs-spaces hs-h" .. pct, nil, spaces))
		table.insert(body, el("div", "hs-bar", nil, {
			el("span", (native and native.attach_supported) and "hs-btn" or "hs-disabled",
				"new", nil, (native and native.attach_supported) and "new_space" or nil),
			el("span", "hs-grow", ""),
			el("span", "hs-btn hs-arrow", "▴", nil, "up"),
			el("span", "hs-btn hs-arrow", "▾", nil, "down"),
			el("span", "hs-grow", ""),
			el("span", "hs-btn hs-menu-btn" .. (needs_integrations(state) and " hs-attn" or ""), "menu", nil, "menu"),
		}))
		if state.menu then
			table.insert(body, menu_view(state))
		end
		table.insert(body, el("div", "hs-agents", nil, list))
		return { main = ui.col({ el("div", "hs", nil, body) }) }
	end,

	key = function(state, key, cx)
		local name = key.name
		local step = herd_step(key)
		if step then
			if not state.org_error and state.herd_count > 1 then
				select_herd(state, cx, (state.herd + step + state.herd_count) % state.herd_count)
				poll(state, cx, false)
			end
			return true
		end
		-- A premature attempt to type into the switching terminal can land on
		-- this rail. Never turn those printable keys into backend commands.
		local desired_machine, desired_terminal, desired_mode = common.link_target(state.link)
		if desired_machine and desired_terminal then
			local attached_machine, attached_terminal, attached_mode = common.attached_link_target(state.link)
			if attached_machine ~= desired_machine or attached_terminal ~= desired_terminal or attached_mode ~= desired_mode then
				if name == "escape" then
					state.menu = false
					state.confirm = nil
				elseif name == "down" then
					state.sel += 1
					clamp(state)
				elseif name == "up" then
					state.sel -= 1
					clamp(state)
				end
				return true
			end
		end
		if state.menu then
			if name == "escape" then
				state.menu = false
				state.confirm = nil
				return true
			end
			return false
		end
		if name == "down" or name == "j" then
			state.sel += 1
		elseif name == "up" or name == "k" then
			state.sel -= 1
		elseif name == "[" then
			act(state, cx, "up")
		elseif name == "]" then
			act(state, cx, "down")
		elseif name == "m" then
			state.menu = true
		elseif name == "n" then
			act(state, cx, "new_space")
		elseif name == "r" then
			act(state, cx, "refresh")
			return false
		elseif name == "enter" or name == "space" then
			local a = agents(state)[state.sel]
			if a then
				attach_agent(state, cx, a)
			end
		else
			return false
		end
		clamp(state)
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		local name, value = ev.act, ev.value
		if (name == "pick" or name == "space" or name == "tab") and value then
			local machine, id = string.match(value, "^(.-)|(.+)$")
			local snap = machine and state.snaps[machine]
			if not snap or snap.err then
				return
			end
			if name == "pick" then
				for _, a in snap.agents do
					if a.terminal_id == id then
						state.machine, state.snap = machine, snap
						select_terminal(state, id)
						attach_agent(state, cx, a)
						break
					end
				end
			elseif name == "space" then
				attach_space(state, cx, machine, id)
			elseif name == "tab" then
				local p = common.panes_of(snap, id)[1]
				local profile = common.machine(machine)
				if not profile or not profile.attach_supported then
					cx:toast("error", "Herdr viewer unavailable", "Local HERDR_BIN needs scoped-terminal-attach-v2; inventory only")
					return
				end
				if p and p.terminal_id ~= "" then
					state.machine, state.snap = machine, snap
					state.last[tostring(state.herd)] = machine .. "|" .. p.terminal_id
					state.last_profile[machine] = p.terminal_id
					tern.kv.set("herd:last:" .. state.herd, p.key)
					show_terminal(cx, state.link, state.pane, machine, p.terminal_id)
					cx:save()
				end
			end
		elseif name == "menu" then
			state.menu = not state.menu
			state.confirm = nil
		else
			act(state, cx, name, value)
		end
	end,
}

tern.block.define("sidebar", sidebar)

---------------------------------------------------------------------------------------------------
-- Tab strip: the shown space's Herdr tabs ("1 2 +") above the sidebar's terminal.

type StripState = {
	link: string,
	pane: number,
	snap: common.Snapshot?,
	closed: boolean,
}

-- The machine and Herdr pane the link's terminal shows.
local function strip_place(state: StripState): (string?, common.Pane?)
	local machine, terminal = common.link_target(state.link)
	local snap = state.snap
	if not machine or not terminal or not snap or snap.err or snap.machine ~= machine then
		return machine, nil
	end
	return machine, common.pane_by_terminal(snap, terminal)
end

local function strip_poll(state: StripState, cx: BlockCx)
	if state.closed or not alive(state.pane) then
		state.closed = true
		return
	end
	local machine = common.link_target(state.link)
	if not machine then
		tern.timer(POLL_MS, function()
			strip_poll(state, cx)
		end)
		return
	end
	common.snapshot(machine, function(snap)
		state.snap = snap
		if not pcall(cx.render, cx) then
			state.closed = true
			return
		end
		tern.timer(POLL_MS, function()
			strip_poll(state, cx)
		end)
	end)
end

local strip: BlockDef<StripState> = {
	init = function(cx, args, saved)
		local state: StripState = {
			link = args[1] or (saved and saved.link) or "",
			pane = cx.pane,
			snap = nil,
			closed = false,
		}
		strip_poll(state, cx)
		return state
	end,

	save = function(state)
		return { link = state.link }
	end,

	title = function(_state)
		return "herdr tabs"
	end,

	view = function(state, _cx)
		local machine, pane = strip_place(state)
		local chips: { Node } = {}
		if pane and state.snap then
			for _, t in common.tabs_of(state.snap, pane.workspace_id) do
				local on = t.id == pane.tab_id
				table.insert(chips, el("span", "ht-tab" .. (on and " ht-on" or ""), nil, {
					dot(t.status),
					el("span", "", t.label),
				}, "tab=" .. t.id))
			end
			table.insert(chips, el("span", "ht-tab ht-new", "+", nil, "new"))
			if machine and machine ~= "local/default" then
				local profile = common.machine(machine)
				table.insert(chips, el("span", "hs-grow", ""))
				table.insert(chips, el("span", "ht-machine", profile and profile.label or machine))
			end
		end
		if state.snap and state.snap.err then
			table.insert(chips, el("span", "hs-err", "offline · " .. state.snap.err))
		end
		return { main = ui.col({ el("div", "ht", nil, chips) }) }
	end,

	event = function(state, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		local machine, pane = strip_place(state)
		local snap = state.snap
		if not machine or not pane or not snap then
			return
		end
		local profile = common.machine(machine)
		if not profile or not profile.attach_supported then
			cx:toast("error", "Herdr terminal attach unavailable",
				profile and "Local Herdr needs scoped-terminal-attach-v2; inventory only" or machine)
			return
		end
		if ev.act == "tab" and ev.value then
			local target = common.panes_of(snap, ev.value)[1]
			if target then
				common.retarget(state.link, machine, target.terminal_id)
			end
		elseif ev.act == "new" then
			herdr(cx, machine, { "tab", "create", "--workspace", pane.workspace_id, "--cwd", pane.cwd, "--no-focus" }, function(r)
				if r.root_pane and r.root_pane.terminal_id then
					common.retarget(state.link, machine, r.root_pane.terminal_id)
				end
			end)
		end
	end,
}

tern.block.define("tabs", strip)
