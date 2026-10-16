-- Shared helpers for both halves: locating binaries, talking to Herdr on this machine or over ssh,
-- reading its state, and the links between Tern panes and the Herdr terminals they show.

local M = {}

local home = tern.getenv("HOME") or ""

local function find(env: string, candidates: { string }, fallback: string): string
	local override = tern.getenv(env)
	if override and override ~= "" then
		return override
	end
	for _, path in candidates do
		local ok, exists = pcall(tern.fs.exists, path)
		if ok and exists then
			return path
		end
	end
	return fallback
end

-- Tern windows and the daemon start from launchd, so PATH rarely holds ~/.local/bin.
M.herdr = find("HERDR_BIN", {
	home .. "/.local/bin/herdr",
	"/opt/homebrew/bin/herdr",
	"/usr/local/bin/herdr",
	home .. "/.cargo/bin/herdr",
}, "herdr")

M.tern = find("TERN_BIN", {
	"/Applications/Tern.app/Contents/MacOS/tern",
	home .. "/.local/bin/tern",
	"/usr/local/bin/tern",
	"/usr/bin/tern",
}, "tern")

local function config_dir(): string
	local base = tern.getenv("XDG_CONFIG_HOME")
	if not base or base == "" then
		base = home .. "/.config"
	end
	return base
end

local function read(path: string): string
	local ok, text = pcall(tern.fs.read, path)
	return ok and text or ""
end

-- Herdr's config.toml text, or "" when there is none.
function M.herdr_config(): string
	return read(config_dir() .. "/herdr/config.toml")
end

---------------------------------------------------------------------------------------------------
-- Saved Herdr endpoints, not SSH hostnames: profiles on one host can name different sessions.
-- Herdr owns endpoints.json and client-shell state; this plugin only reads them.

export type Machine = { id: string, label: string, session: string, target: string, herd: number, attach_supported: boolean }

local function decode_file(path: string): any?
	local text = read(path)
	if text == "" then
		return nil
	end
	local ok, doc = pcall(tern.json.decode, text)
	return ok and type(doc) == "table" and doc or nil
end

local function shell_state(): (any?, string?)
	local override = tern.getenv("TERN_HERDR_CLIENT_STATE")
	if override and override ~= "" then
		return decode_file(override), override
	end
	local dir = (tern.getenv("XDG_STATE_HOME") or (home .. "/.local/state")) .. "/herdr/client-shell"
	local ok, names = pcall(tern.fs.list, dir)
	if not ok then
		return nil, "Herdr client state not found; set TERN_HERDR_CLIENT_STATE to its client-shell/local-*.json"
	end
	local found = {}
	for _, name in names do
		if string.match(name, "^local%-[%w%-]+%.json$") then
			table.insert(found, dir .. "/" .. name)
		end
	end
	if #found ~= 1 then
		return nil, "Expected one Herdr client-shell/local-*.json; set TERN_HERDR_CLIENT_STATE to select yours"
	end
	local doc = decode_file(found[1])
	return doc, doc and nil or ("Could not read Herdr client state " .. found[1])
end

function M.organization(): (number, number, { [string]: number }, string?)
	local doc, err = shell_state()
	if not doc then
		return 1, 0, {}, err
	end
	local count = math.max(1, tonumber(doc.herd_count) or 1)
	local selected = math.clamp(tonumber(doc.selected_herd) or 0, 0, count - 1)
	local memberships = {}
	for _, entry in doc.machine_herds or {} do
		local id = if entry.profile_id == nil then "local/default" else entry.profile_id
		if type(id) == "string" and type(entry.herd) == "number" then
			memberships[id] = entry.herd
		end
	end
	return count, selected, memberships, nil
end

function M.collapsed(): { [string]: boolean }
	local doc = shell_state()
	local result = {}
	if doc then
		for _, key in doc.collapsed_groups or {} do
			result["local/default|" .. key] = true
		end
		for _, remote in doc.remote_collapsed_groups or {} do
			for _, key in remote.collapsed_groups or {} do
				result[remote.profile_id .. "|" .. key] = true
			end
		end
	end
	return result
end

local machine_cache: { Machine }? = nil
local machine_cache_at = 0

-- The local follower needs both native transport and the scoped-input/ready ABI.
-- Probe local help only; older clients remain inventory-only, including ANSI mode.
local native_supported = false
local native_checked = false
local native_waiters: { () -> () } = {}
function M.refresh_attach_support(done: () -> ())
	if native_checked then
		done()
		return
	end
	table.insert(native_waiters, done)
	if #native_waiters > 1 then
		return
	end
	tern.process.run({ M.herdr, "--machine", "00000000000000000000000000000000", "terminal", "native-attach", "--help" },
		{ timeout_ms = 3000 }, function(res)
			native_supported = res.status == 0
				and string.find(res.stdout, "native-terminal-attach-v1", 1, true) ~= nil
				and string.find(res.stdout, "scoped-terminal-attach-v2", 1, true) ~= nil
			native_checked = true
			machine_cache = nil
			local waiters = native_waiters
			native_waiters = {}
			for _, callback in waiters do
				callback()
			end
		end)
end

function M.machines(): { Machine }
	if machine_cache and os.time() - machine_cache_at < 2 then
		return machine_cache
	end
	local _, _, memberships, org_error = M.organization()
	local list: { Machine } = { { id = "local/default", label = "local", target = "local", session = "default",
		herd = org_error and -1 or (memberships["local/default"] or 0), attach_supported = native_supported } }
	local sessions = config_dir() .. "/herdr/sessions"
	local ok, names = pcall(tern.fs.list, sessions)
	if ok then
		for _, name in names do
			if not string.find(name, "[/%s]") and tern.fs.exists(sessions .. "/" .. name .. "/herdr.sock") then
				table.insert(list, { id = "local/" .. name, label = "local · " .. name, target = "local", session = name, herd = 0, attach_supported = native_supported })
			end
		end
	end
	local doc = decode_file((tern.getenv("XDG_STATE_HOME") or (home .. "/.local/state")) .. "/herdr/client/endpoints.json")
	for _, entry in doc and doc.ssh or {} do
		if entry.enabled == true and type(entry.id) == "string" and type(entry.label) == "string"
			and type(entry.target) == "string" and type(entry.session) == "string" then
			table.insert(list, { id = entry.id, label = entry.label, target = entry.target, session = entry.session,
				herd = org_error and -1 or (memberships[entry.id] or 0), attach_supported = native_supported })
		end
	end
	machine_cache = list
	machine_cache_at = os.time()
	return list
end

function M.machine(id: string): Machine?
	for _, m in M.machines() do
		if m.id == id then
			return m
		end
	end
	return nil
end

function M.quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Herdr's saved-profile API forwarding preserves the configured session on a shared SSH host.
function M.argv(machine: string, args: { string }): { string }
	local argv = { M.herdr }
	if string.sub(machine, 1, 6) == "local/" then
		table.insert(argv, "--session")
		table.insert(argv, string.sub(machine, 7))
	else
		table.insert(argv, "--machine")
		table.insert(argv, machine)
	end
	for _, a in args do
		table.insert(argv, a)
	end
	return argv
end


---------------------------------------------------------------------------------------------------
-- Integrations: Herdr marks one "available" when it isn't installed and the agent's command is
-- on PATH, and "update available" when it is outdated. Both put a dot on Herdr's menu.

local INTEGRATION_COMMANDS: { [string]: { string } } = {
	kilo = { "kilo", "kilo-code" },
	cursor = { "cursor-agent" },
	["antigravity-cli"] = { "agy" },
}

export type Integration = { name: string, state: string, available: boolean }

-- Integration status is CLI text. Probe PATH only for local profiles: saved remote
-- endpoints may be Windows and must not be treated as POSIX login shells.
function M.integrations(machine: string, done: ({ Integration }?, string?) -> ())
	tern.process.run(M.argv(machine, { "integration", "status" }), { timeout_ms = 10000 }, function(res)
		local err = (res.timed_out and "herdr timed out")
			or (res.status ~= 0 and string.gsub(res.stderr .. res.stdout, "%s+$", ""))
		if err then
			done(nil, err)
			return
		end
		local list = {}
		for line in string.gmatch(res.stdout, "[^\n]+") do
			local name, rest = string.match(line, "^([%w%-]+)[^:]*:%s*(.*)$")
			if name then
				local state = string.find(rest, "^current") and "current"
					or string.find(rest, "^outdated") and "outdated"
					or string.find(rest, "^not installed") and "missing"
					or "unknown"
				table.insert(list, { name = name, state = state, available = false })
			end
		end
		if string.sub(machine, 1, 6) ~= "local/" then
			done(list, nil)
			return
		end
		local names = { "pi", "omp", "claude", "codex", "copilot", "devin", "droid", "kimi", "opencode",
			"kilo", "hermes", "qodercli", "qwen", "cursor", "mastracode", "antigravity-cli", "grok", "letta" }
		local commands = {}
		for _, n in names do
			for _, c in INTEGRATION_COMMANDS[n] or { n } do
				table.insert(commands, c)
			end
		end
		local script = "for c in " .. table.concat(commands, " ") .. "; do command -v \"$c\" >/dev/null 2>&1 && echo \"$c\"; done"
		tern.process.run({ tern.getenv("SHELL") or "/bin/sh", "-lc", script }, { timeout_ms = 5000 }, function(probe)
			if probe.status == 0 then
				local found = {}
				for name in string.gmatch(probe.stdout, "%S+") do
					found[name] = true
				end
				for _, entry in list do
					for _, c in INTEGRATION_COMMANDS[entry.name] or { entry.name } do
						entry.available = entry.available or found[c] == true
					end
				end
			end
			done(list, nil)
		end)
	end)
end

function M.needs_install(i: Integration): boolean
	return i.state == "outdated" or (i.state == "missing" and i.available)
end

---------------------------------------------------------------------------------------------------
-- State

M.STATES = { "blocked", "working", "done", "idle", "unknown" }
M.RANK = { blocked = 1, working = 2, done = 3, idle = 4, unknown = 5 }
M.TONE = { blocked = "error", working = "warn", done = "success", idle = "muted", unknown = "muted" }

export type Agent = {
	machine: string,
	pane_id: string,
	terminal_id: string,
	agent: string,
	status: string,
	title: string,
	cwd: string,
	workspace_id: string,
	tab_id: string,
	focused: boolean,
}

export type Workspace = { machine: string, id: string, label: string, number: number, status: string, active_tab: string?, focused: boolean,
	worktree: { checkout_path: string, is_linked_worktree: boolean, repo_key: string, repo_name: string, repo_root: string }? }
export type Tab = { machine: string, id: string, workspace_id: string, label: string, number: number, status: string, focused: boolean }
export type Pane = { machine: string, id: string, key: string, terminal_id: string, tab_id: string, workspace_id: string, cwd: string, focused: boolean }

export type Snapshot = {
	machine: string,
	err: string?,
	workspaces: { Workspace }, -- by number
	tabs: { Tab }, -- by workspace number, then tab number
	panes: { [string]: Pane }, -- by pane id
	agents: { Agent }, -- by urgency
}

local function failure(res: any): string?
	if res.timed_out then
		return "herdr timed out"
	end
	if res.status ~= 0 then
		local msg = string.gsub((res.stderr ~= "" and res.stderr) or res.stdout, "%s+$", "")
		return msg ~= "" and msg or ("herdr exited with status " .. tostring(res.status))
	end
	return nil
end

-- Decodes a Herdr CLI reply and returns `result[field]`, or nil and a reason.
function M.decode(res: any, field: string): (any, string?)
	local err = failure(res)
	if err then
		return nil, err
	end
	local ok, doc = pcall(tern.json.decode, res.stdout)
	if not ok or type(doc) ~= "table" then
		return nil, "unreadable herdr output"
	end
	if doc.error then
		return nil, tostring(doc.error.message or doc.error)
	end
	local value = doc.result and doc.result[field]
	if type(value) ~= "table" then
		return nil, "herdr returned no " .. field
	end
	return value, nil
end

function M.sort(agents: { Agent })
	table.sort(agents, function(x, y)
		local rx, ry = M.RANK[x.status] or 9, M.RANK[y.status] or 9
		if rx ~= ry then
			return rx < ry
		end
		return x.pane_id < y.pane_id
	end)
end

-- Turns `herdr pane list` rows into agents (rows without an agent are skipped).
function M.agents_from(machine: string, rows: { any }): { Agent }
	local agents = {}
	for _, a in rows do
		if a.agent then
			table.insert(agents, {
				machine = machine,
				pane_id = a.pane_id,
				terminal_id = a.terminal_id or "",
				agent = a.agent,
				status = a.agent_status or "unknown",
				title = a.terminal_title_stripped or a.terminal_title or "",
				cwd = a.foreground_cwd or a.cwd or "",
				workspace_id = a.workspace_id or "",
				tab_id = a.tab_id or "",
				focused = a.focused == true,
			})
		end
	end
	M.sort(agents)
	return agents
end

local function build(machine: string, ws: any, ts: any, ps: any): Snapshot
	local snap: Snapshot = { machine = machine, err = nil, workspaces = {}, tabs = {}, panes = {}, agents = {} }
	for _, w in ws do
		table.insert(snap.workspaces, {
			machine = machine,
			id = w.workspace_id,
			label = w.label or w.workspace_id,
			number = w.number or 0,
			status = w.agent_status or "unknown",
			active_tab = w.active_tab_id,
			worktree = w.worktree,
			focused = w.focused == true,
		})
	end
	table.sort(snap.workspaces, function(a, b)
		return a.number < b.number
	end)
	local order = {}
	for i, w in snap.workspaces do
		order[w.id] = i
	end
	for _, t in ts do
		table.insert(snap.tabs, {
			machine = machine,
			id = t.tab_id,
			workspace_id = t.workspace_id,
			label = t.label or tostring(t.number),
			number = t.number or 0,
			status = t.agent_status or "unknown",
			focused = t.focused == true,
		})
	end
	table.sort(snap.tabs, function(a, b)
		local oa, ob = order[a.workspace_id] or 999, order[b.workspace_id] or 999
		if oa ~= ob then
			return oa < ob
		end
		return a.number < b.number
	end)
	for _, p in ps do
		snap.panes[p.pane_id] = {
			machine = machine,
			id = p.pane_id,
			key = machine .. "|" .. p.pane_id,
			terminal_id = p.terminal_id or "",
			tab_id = p.tab_id or "",
			workspace_id = p.workspace_id or "",
			cwd = p.foreground_cwd or p.cwd or "",
			focused = p.focused == true,
		}
	end
	snap.agents = M.agents_from(machine, ps)
	return snap
end

-- One flight per profile in each plugin VM; the sidebar and tab strip share it. On failure
-- keep the last successful view but mark it unavailable (never show stale activity as live).
local cache: { [string]: { snap: Snapshot, at: number } } = {}
local waiting: { [string]: { (Snapshot, any) -> () } } = {}

function M.snapshot(machine: string, done: (Snapshot, any) -> ())
	local cached = cache[machine]
	if cached and os.time() - cached.at < 2 then
		done(cached.snap, nil)
		return
	end
	if waiting[machine] then
		table.insert(waiting[machine], done)
		return
	end
	waiting[machine] = { done }
	local results: { [string]: any } = {}
	local got, err, context = 0, nil, nil
	-- Saved SSH calls include remote shell startup and Herdr's bounded SSH probes.
	local timeout_ms = if string.sub(machine, 1, 6) == "local/" then 8000 else 30000
	local function one(args: { string }, field: string)
		tern.process.run(M.argv(machine, args), { timeout_ms = timeout_ms }, function(res, cx)
			local value, why = M.decode(res, field)
			if value then
				results[field] = value
			else
				err = err or why
			end
			context = cx or context
			got += 1
			if got < 2 then
				return
			end
			local live = results.snapshot
			if not err and (type(live.workspaces) ~= "table" or type(live.tabs) ~= "table"
				or type(live.panes) ~= "table") then
				err = "herdr snapshot is missing workspaces, tabs or panes"
			end
			local snap: Snapshot
			if err then
				local previous = cache[machine] and cache[machine].snap
				snap = previous and { machine = machine, err = err, workspaces = previous.workspaces,
					tabs = previous.tabs, panes = previous.panes, agents = previous.agents }
					or { machine = machine, err = err, workspaces = {}, tabs = {}, panes = {}, agents = {} }
			else
				local worktrees = {}
				for _, w in results.workspaces do
					worktrees[w.workspace_id] = w.worktree
				end
				for _, w in live.workspaces do
					w.worktree = worktrees[w.workspace_id]
				end
				snap = build(machine, live.workspaces, live.tabs, live.panes)
			end
			cache[machine] = { snap = snap, at = os.time() }
			local callbacks = waiting[machine]
			waiting[machine] = nil
			for _, callback in callbacks do
				callback(snap, context)
			end
		end)
	end
	one({ "workspace", "list" }, "workspaces")
	one({ "api", "snapshot" }, "snapshot")
end

function M.tabs_of(snap: Snapshot, workspace_id: string): { Tab }
	local out = {}
	for _, t in snap.tabs do
		if t.workspace_id == workspace_id then
			table.insert(out, t)
		end
	end
	return out
end

function M.panes_of(snap: Snapshot, tab_id: string): { Pane }
	local out = {}
	for _, p in snap.panes do
		if p.tab_id == tab_id then
			table.insert(out, p)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function M.pane_by_terminal(snap: Snapshot, terminal_id: string): Pane?
	for _, p in snap.panes do
		if p.terminal_id == terminal_id then
			return p
		end
	end
	return nil
end

function M.counts(agents: { Agent }): { [string]: number }
	local c = {}
	for _, a in agents do
		c[a.status] = (c[a.status] or 0) + 1
	end
	return c
end

function M.basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

function M.label(a: Agent): string
	if a.title ~= "" then
		return a.title
	end
	return a.agent .. " in " .. M.basename(a.cwd)
end

-- Terminal IDs are server-owned, stable across pane/tab reordering and scoped
-- by machine here. A new terminal identity defaults to native; resuming the
-- same terminal retains its choice.
local function view_key(machine: string, terminal_id: string): string
	return "view:" .. machine .. "|" .. terminal_id
end

function M.view_mode(machine: string, terminal_id: string): string
	return if tern.kv.get(view_key(machine, terminal_id)) == "ansi" then "ansi" else "native"
end

function M.set_view_mode(machine: string, terminal_id: string, mode: string)
	assert(mode == "native" or mode == "ansi")
	tern.kv.set(view_key(machine, terminal_id), mode)
end

-- Exact target bytes are also the follower's input lease and readiness value.
-- A mode switch revokes the old reader even when selector and terminal agree.

function M.target_file(link: string): string
	local dir = tern.plugin.data .. "/links"
	pcall(tern.fs.mkdir, dir)
	return dir .. "/" .. link
end

-- Shell command line for a terminal pane.
function M.follow_command(link: string): string
	return "sh " .. M.quote(tern.plugin.dir .. "/follow.sh") .. " " .. M.quote(M.target_file(link)) .. " " .. M.quote(M.herdr)
end

function M.encode_target(machine: string, terminal_id: string, mode: string): string
	assert(mode == "native" or mode == "ansi")
	return machine .. " " .. terminal_id .. " " .. mode
end

local function decode_target(text: string): (string?, string?, string?)
	local machine, terminal, mode = string.match(text, "^(%S+) (%S+) (native)$")
	if not mode then
		machine, terminal, mode = string.match(text, "^(%S+) (%S+) (ansi)$")
	end
	return machine, terminal, mode
end

function M.link_target(link: string): (string?, string?, string?)
	return decode_target(read(M.target_file(link)))
end

-- A desired target is not the pane's actual attachment during a follower switch.
-- Only expose it to window actions once the follower reports that exact target.
function M.attached_link_target(link: string): (string?, string?, string?)
	local file = M.target_file(link)
	local desired = read(file)
	if desired == "" or read(file .. ".on") ~= desired then
		return nil, nil, nil
	end
	return decode_target(desired)
end

-- The follower watches this file and stops only its own local attach client on change.
-- Never inject escape bytes into a terminal: they could reach the newly attached agent.
function M.retarget(link: string, machine: string, terminal_id: string)
	if not native_supported then
		return
	end
	local file = M.target_file(link)
	local target = M.encode_target(machine, terminal_id, M.view_mode(machine, terminal_id))
	if read(file) ~= target then
		tern.fs.write(file, target)
	end
end

function M.new_link(): string
	return string.format("%x%04x", math.floor(os.time()), math.random(0, 0xffff))
end

return M
