--!strict
-- portcall through its CLI, as you run it (`zeron.run`, "commands": ["portcall"]):
-- the plugin reads `--json` like any agent does and keeps no state of its own.
--
--   portcall.watch(where)   in a build: a function reading `where`'s status as
--                           it changes, asked again every few seconds while a
--                           build reading it stands. `where` is { cwd = folder }
--                           (that folder's project) or { all = true } (every
--                           known project). The value: { state = "loading" |
--                           "ok" | "none" | "failed", data?, error? }.
--   portcall.act(target, verb, service)
--                           runs `portcall <verb> <service> --json` for a
--                           project ({ cwd } or { project }), then asks again.
--   portcall.busy(project, service)
--                           in a build: a function reading the verb running on
--                           that service now, or nil.
--   portcall.errors(target, service)
--                           a promise-like of its error lines (`logs --errors`).
--   portcall.refresh()      asks everything shown again now.

local POLL_MS = 5000
local TIMEOUT_STATUS = 20
-- `up` waits for the port (60 s by default, more with readyTimeout).
local TIMEOUT_ACTION = 180

return function(zeron: any)
	local M = {}

	local function decoded(text: string?): any
		if not text or string.match(text, "^%s*$") then
			return nil
		end
		local ok, value = pcall(ui.json.decode, text)
		return if ok then value else nil
	end

	-- What portcall said, as `{ ok, data, error }`: its JSON on stdout (a
	-- failing `up` still prints it, with exit 1), else its words on stderr.
	local function run(args: { string }, cwd: string?, timeout: number, done: (ok: boolean, data: any, err: string?) -> ())
		zeron.run("portcall", args, { cwd = cwd, timeout = timeout }):after(function(r: any)
			local data = decoded(r and r.stdout)
			if type(data) == "table" and data.error then
				done(false, data, tostring(data.error))
			elseif type(data) == "table" then
				done(true, data, nil)
			else
				local said = r and (if r.stderr and r.stderr ~= "" then r.stderr else r.stdout) or ""
				done(false, nil, if said ~= "" then string.gsub(said, "%s+$", "") else zeron.s("failed.title"))
			end
		end, function(err: any)
			local said = if type(err) == "table" and err.message then tostring(err.message) else tostring(err)
			if string.find(said, "not found", 1, true) or string.find(said, "ENOENT", 1, true) then
				said = zeron.s("failed.missing")
			end
			done(false, nil, said)
		end)
	end

	-- One state per place asked (a folder, or every project), and how many
	-- builds read it now: only what's shown is asked again.
	type Entry = { cell: any, args: { string }, cwd: string?, shown: number, asking: boolean, again: boolean, waiting: { () -> () } }
	local entries: { [string]: Entry } = {}

	local function ask(entry: Entry)
		-- Asked while an answer is on its way: that answer may predate what
		-- changed (a stop that just ended), so it's dropped and asked again.
		if entry.asking then
			entry.again = true
			return
		end
		entry.asking = true
		run(entry.args, entry.cwd, TIMEOUT_STATUS, function(ok, data, err)
			entry.asking = false
			if entry.again then
				entry.again = false
				ask(entry)
				return
			end
			if ok then
				entry.cell:set({ state = "ok", data = data })
			elseif err and string.find(err, "no portcall.json", 1, true) then
				entry.cell:set({ state = "none" })
			elseif entry.cell:peek().state == "ok" then
				-- One failed read after good ones: the last list stays (a page
				-- swapped for an error and back would jump).
			else
				entry.cell:set({ state = "failed", error = err })
			end
			local waiting = entry.waiting
			entry.waiting = {}
			for _, fn in waiting do
				fn()
			end
		end)
	end

	local function entry_for(where: { cwd: string?, all: boolean? }): Entry
		local key = if where.all then "all" else `cwd:{where.cwd}`
		local entry = entries[key]
		if not entry then
			entry = {
				-- Named by what it holds: Zeron keeps states across reloads, so a
				-- name must never pass from one place to another.
				cell = ui.state(`portcall.status.{key}`, { state = "loading" }),
				args = if where.all then { "status", "--all", "--json" } else { "status", "--json" },
				cwd = where.cwd,
				shown = 0,
				asking = false,
				again = false,
				waiting = {},
			}
			entries[key] = entry
		end
		return entry :: Entry
	end

	-- `status()` reads it as it changes; `status(true)` reads it now without following.
	function M.watch(where: { cwd: string?, all: boolean? }): (peek: boolean?) -> any
		local entry = entry_for(where)
		entry.shown += 1
		if entry.shown == 1 then
			ask(entry)
		end
		pcall(ui.on_cleanup, function()
			entry.shown -= 1
		end)
		return function(peek: boolean?): any
			return if peek then entry.cell:peek() else entry.cell:get()
		end
	end

	-- `settled` runs once every place shown has its new answer (at once if none is shown).
	function M.refresh(settled: (() -> ())?)
		local pending = 0
		local function one()
			pending -= 1
			if pending == 0 and settled then
				settled()
			end
		end
		for _, entry in entries do
			if entry.shown > 0 then
				pending += 1
				table.insert(entry.waiting, one)
				ask(entry)
			end
		end
		if pending == 0 and settled then
			settled()
		end
	end

	ui.every(POLL_MS, function()
		if zeron.window(true).shown then
			M.refresh()
		end
	end)

	-- The verb running on each service, by "project/service".
	local busy = ui.state("portcall.busy", {} :: { [string]: string })

	function M.busy(project: string, service: string): () -> string?
		return function(): string?
			return busy:get()[`{project}/{service}`]
		end
	end

	local function target_args(target: { cwd: string?, project: string? }): { string }
		return if target.project then { "-p", target.project } else {}
	end

	function M.act(target: { cwd: string?, project: string? }, label: string, verb: string, service: string)
		local key = `{label}/{service}`
		local now = table.clone(busy:peek())
		now[key] = verb
		busy:set(now)
		local args = { verb, service, "--json" }
		for _, a in target_args(target) do
			table.insert(args, a)
		end
		run(args, target.cwd, TIMEOUT_ACTION, function(ok, data, err)
			if not ok then
				-- `up` says why per service (crashed, wrong-port, blocked...).
				local detail = err
				if type(data) == "table" and type(data.services) == "table" then
					for _, s in data.services do
						if s.service == service and s.detail then
							detail = `{s.outcome}: {s.detail}`
						end
					end
				end
				zeron.toast(zeron.s("failed.action", { service = service, detail = detail or "" }))
			end
			-- The action's badge stays until the state after it is in: in
			-- between, the last answer read may still say mid-stop's starting.
			M.refresh(function()
				local after = table.clone(busy:peek())
				after[key] = nil
				busy:set(after)
			end)
		end)
		M.refresh()
	end

	function M.errors(target: { cwd: string?, project: string? }, service: string, done: (lines: { string }?, err: string?) -> ())
		local args = { "logs", service, "--errors", "-n", "40", "--json" }
		for _, a in target_args(target) do
			table.insert(args, a)
		end
		run(args, target.cwd, TIMEOUT_STATUS, function(ok, data, err)
			if not ok then
				done(nil, err)
				return
			end
			local lines: { string } = {}
			for _, l in (data.lines or {}) do
				table.insert(lines, tostring(l.text or ""))
			end
			done(lines, nil)
		end)
	end

	return M
end
