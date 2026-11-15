--!strict
-- A project's services as portcall says them, one settings row each: its
-- state's badge, its port and what portcall adds (an exit code, who holds the
-- port, where it listens instead), and the actions its state allows. Shared by
-- the chat panel's tab (one project) and the Dev servers page (all of them).
--
--   Services.Project { label, services, find, undeclared, target, portcall, zeron }
--   Services.summary(services)   the panel row's trail: "2/3 running"

local Settings = require("@ds/settings")
local Badge = require("@ds/badge")
local Button = require("@ds/button")
local Text = require("@ds/text")

local TONES: { [string]: string } = {
	running = "success",
	starting = "warning",
	crashed = "danger",
	stopped = "neutral",
	unmanaged = "warning",
	taken = "danger",
	elsewhere = "neutral",
}

-- The badge's word while an action runs, by verb.
local BUSY_WORDS: { [string]: string } = { up = "starting", down = "stopping", restart = "restarting" }

local M = {}

-- What portcall adds to a service's state, in its own words where it has them.
local function info(zeron: any, s: any): string
	local parts: { string } = { `:{s.port}` }
	if s.basePort then
		table.insert(parts, `(declared {s.basePort})`)
	end
	if s.external then
		table.insert(parts, zeron.s("info.external"))
	end
	if s.state == "crashed" then
		table.insert(parts, if s.exitSignal then `killed by {s.exitSignal}` else `exit code {s.exitCode or "?"}`)
	elseif s.state == "starting" and s.listeningOn then
		table.insert(parts, `listening on {table.concat(s.listeningOn, ", ")}, not {s.port}`)
	elseif (s.state == "taken" or s.state == "unmanaged") and s.holder then
		table.insert(parts, tostring(s.holder.command or ""))
	elseif s.state == "elsewhere" and s.root then
		table.insert(parts, `run from {s.root}`)
	end
	return table.concat(parts, "  ·  ")
end

-- The verbs a state allows, in the order they show.
local function verbs(s: any): { string }
	if s.external then
		return {}
	elseif s.state == "stopped" then
		return { "up" }
	elseif s.state == "crashed" then
		return { "up", "down" }
	elseif s.state == "running" or s.state == "starting" then
		return { "restart", "down" }
	end
	return {}
end

-- Each row reads its service as it changes (`props.find(name)`), so a state
-- moving redraws its badge, its line and its buttons, never the list: the
-- page keeps its height and its scroll.
local Row = ui.component(function(props: any): Node
	local zeron, portcall, name = props.zeron, props.portcall, props.name
	local open = ui.use_state(false)
	local lines = ui.use_state(nil :: { string }?)
	local busy = portcall.busy(props.label, name)
	local function now(peek: boolean?): any
		return props.find(name, peek) or { service = name, state = "stopped", port = props.port, external = props.external }
	end

	local function load_errors()
		portcall.errors(props.target, name, function(found, err)
			lines:set(found or { err or "" })
		end)
	end

	local function controls(state: string): Node
		local list: { Node } = {}
		-- Its URL, where links open (Settings → Links): once it answers on its port.
		if state == "running" and not props.external then
			table.insert(list, Button {
				zeron.t("action.open"),
				tone = "secondary",
				size = "sm",
				on_click = function()
					local url = now(true).url
					if type(url) == "string" then
						zeron.open_url(url)
					end
				end,
			})
		end
		for _, verb in verbs({ state = state, external = props.external }) do
			table.insert(list, Button {
				zeron.t(`action.{verb}`),
				tone = if verb == "up" then "primary" else "secondary",
				size = "sm",
				busy = function(): boolean
					return busy() == verb
				end,
				-- One action at a time on a service: the others wait for it.
				disabled = function(): boolean
					local doing = busy()
					return doing ~= nil and doing ~= verb
				end,
				on_click = function()
					if busy() == nil then
						portcall.act(props.target, props.label, verb, name)
					end
				end,
			})
		end
		if not props.external then
			table.insert(list, Button {
				zeron.t("action.errors"),
				tone = "ghost",
				size = "sm",
				on_click = function()
					local opening = not open:peek()
					open:set(opening)
					if opening then
						load_errors()
					end
				end,
			})
		end
		return ui.row { gap = "$space.2", items = "center", table.unpack(list) }
	end

	return ui.column {
		w_full = true,
		Settings.Row {
			label = name,
			-- While an action of ours runs, what it does: mid-stop, portcall
			-- sees a supervisor whose port closed, which it calls starting.
			badge = ui.presence(function(): string
				return busy() or now().state
			end, function(key: string): Node
				local verb = BUSY_WORDS[key]
				if verb then
					return Badge.Badge { zeron.s(`busy.{verb}`), tone = "warning" }
				end
				local state = now(true).state
				return Badge.Badge { zeron.s(`state.{state}`), tone = TONES[state] or "neutral" }
			end),
			description = function(): string
				return info(zeron, now())
			end,
			truncate = true,
			control = ui.presence(function(): string
				return now().state
			end, controls),
		},
		ui.show(function(): boolean
			return open:get()
		end, ui.column {
			w_full = true,
			px = "$space.4",
			pb = "$space.3",
			gap = "$space.1",
			selectable = true,
			Text {
				function(): string
					local found = lines:get()
					if found == nil then
						return "…"
					end
					return if #found == 0 then zeron.s("info.no_errors") else table.concat(found, "\n")
				end,
				style = "mono",
				tone = "secondary",
				wrap = true,
			},
		}),
	}
end)

-- Ports listening in the project that it doesn't declare, as they change.
local function Undeclared(zeron: any, list: (peek: boolean?) -> { any }): Node
	return ui.presence(function(): string
		local keys: { string } = {}
		for _, l in list() do
			table.insert(keys, `{l.pid}:{l.port}`)
		end
		return table.concat(keys, ";")
	end, function(key: string): Node
		if key == "" then
			return ui.div {}
		end
		local stray: { Node } = {}
		for _, l in list(true) do
			table.insert(stray, Settings.Row {
				label = `:{l.port}`,
				description = `pid {l.pid}  ·  {l.cwd}`,
				detail = tostring(l.command or ""),
				truncate = true,
			})
		end
		return ui.column {
			w_full = true,
			pt = "$space.3",
			gap = "$space.2",
			Text { zeron.s("info.undeclared_title"), style = "label", tone = "secondary" },
			Text { zeron.s("info.undeclared_body"), style = "caption", tone = "tertiary", wrap = true },
			Settings.Group(stray :: any),
		}
	end, { w_full = true })
end

-- One project: `services` as they were when it was built (names, ports, which
-- are external), `find(name, peek?)` each one as it is now, `undeclared(peek?)`
-- the ports it doesn't declare.
function M.Project(props: any): Node
	local rows: { Node } = {}
	for _, s in props.services do
		table.insert(rows, Row {
			zeron = props.zeron,
			portcall = props.portcall,
			name = s.service,
			port = s.port,
			external = s.external,
			find = props.find,
			label = props.label,
			target = props.target,
		})
	end
	return Settings.Section({
		title = props.title,
		trail = props.trail,
		Settings.Group(rows :: any),
		Undeclared(props.zeron, props.undeclared),
	} :: any)
end

-- "2/3 running": the services with a command, and how many run.
function M.summary(services: { any }): string
	local total, up = 0, 0
	for _, s in services do
		if not s.external then
			total += 1
			if s.state == "running" then
				up += 1
			end
		end
	end
	return `{up}/{total} running`
end

-- A key that changes only when the list itself does (projects, services, ports).
function M.key(services: { any }): string
	local parts: { string } = {}
	for _, s in services do
		table.insert(parts, `{s.project}|{s.worktree or ""}|{s.service}|{s.port}|{s.external and 1 or 0}`)
	end
	return table.concat(parts, ";")
end

return M
