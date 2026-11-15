--!strict
-- portcall in Zeron: the dev servers portcall runs, beside the chat. Built only
-- on portcall's CLI (`portcall status --json`, `up`, `down`, `restart`,
-- `logs --errors`), as an agent would use it: portcall knows nothing of Zeron.
--
-- - In a chat's panel home, under its branch: "Dev servers 2/3 running" for the
--   session folder's project; a click opens them in a tab of the panel.
-- - In the sidebar: Dev servers, every project portcall knows.

local zeron = require("./zeron")("portcall")
local portcall = require("./portcall")(zeron)
local Services = require("./services")
local PanelHome = require("@ds/panel_home")
local Settings = require("@ds/settings")
local EmptyState = require("@ds/empty_state")
local Button = require("@ds/button")
local Text = require("@ds/text")
local banner = require("@ds/banner")

local function label_of(project: string, worktree: string?): string
	return if worktree then `{project}@{worktree}` else project
end

-- What a status says when it has no services to list.
local function notice(s: any): Node?
	if s.state == "loading" then
		return ui.column { w_full = true, py = "$space.6", items = "center", Text { "…", tone = "tertiary" } }
	elseif s.state == "failed" then
		return banner.Callout { tone = "danger", title = zeron.s("failed.title"), body = s.error or "" }
	elseif s.state == "none" then
		return ui.div {}
	end
	return nil
end

-- What a status says while it has no list: loading, failed, or no project.
local function phase(s: any): string
	return if s.state == "ok" then "ok" else `{s.state}:{s.error or ""}`
end

-- A service of the latest answer, found by its project label and name.
local function finder(status: (peek: boolean?) -> any, label: string?): (name: string, peek: boolean?) -> any
	return function(name: string, peek: boolean?): any
		local s = status(peek)
		if s.state ~= "ok" then
			return nil
		end
		for _, svc in s.data.services or {} do
			if svc.service == name and (label == nil or label_of(svc.project, svc.worktree) == label) then
				return svc
			end
		end
		return nil
	end
end

local function undeclared_of(status: (peek: boolean?) -> any, label: string?): (peek: boolean?) -> { any }
	return function(peek: boolean?): { any }
		local s = status(peek)
		local out: { any } = {}
		if s.state == "ok" then
			for _, l in s.data.undeclaredPorts or {} do
				if label == nil or label_of(l.project, l.worktree) == label then
					table.insert(out, l)
				end
			end
		end
		return out
	end
end

-- One project, from `portcall status --json` run in a folder. Rebuilt only
-- when its list changes: each row follows its own service.
local function ProjectView(status: (peek: boolean?) -> any, cwd: string): Node
	return ui.presence(function(): string
		local s = status()
		return if s.state == "ok" then `ok:{Services.key(s.data.services)}` else phase(s)
	end, function(_key: string): Node
		local s = status(true)
		local said = notice(s)
		if said then
			return said
		end
		local label = label_of(s.data.project, s.data.worktree)
		return Services.Project {
			zeron = zeron,
			portcall = portcall,
			title = label,
			label = label,
			target = { cwd = cwd },
			services = s.data.services,
			find = finder(status, nil),
			undeclared = undeclared_of(status, nil),
		}
	end, { w_full = true })
end

-- Every known project, from `portcall status --all --json`.
local function AllView(status: (peek: boolean?) -> any): Node
	return ui.presence(function(): string
		local s = status()
		return if s.state == "ok" then `ok:{Services.key(s.data.services)}` else phase(s)
	end, function(_key: string): Node
		local s = status(true)
		local said = notice(s)
		if said then
			return said
		end
		-- Grouped by project (and worktree), in portcall's order.
		local order: { string } = {}
		local groups: { [string]: { any } } = {}
		for _, svc in s.data.services or {} do
			local label = label_of(svc.project, svc.worktree)
			if not groups[label] then
				groups[label] = {}
				table.insert(order, label)
			end
			table.insert(groups[label], svc)
		end
		if #order == 0 then
			return EmptyState { icon = "remote-server", title = zeron.s("page.empty_title"), body = zeron.s("page.empty_body") }
		end
		local sections: { Node } = {}
		for _, label in order do
			table.insert(sections, Services.Project {
				zeron = zeron,
				portcall = portcall,
				title = label,
				label = label,
				target = { project = label },
				services = groups[label],
				find = finder(status, label),
				undeclared = undeclared_of(status, label),
			})
		end
		return ui.column { w_full = true, gap = "$space.6", table.unpack(sections) }
	end, { w_full = true })
end

-- In the panel home's details (core's `zeron.panel.details` slot, which gives
-- { session, device, cwd, branch }): the session folder's dev servers, when
-- that folder is inside a project with a portcall.json.
zeron.place {
	at = "slot:zeron.panel.details",
	after = function(): Node
		local details = zeron.context("panel_details")
		local cwd = details and details.cwd
		-- (The folder is the session record's: "sessions.read", and "files.read" for its path.)
		if type(cwd) ~= "string" then
			return ui.div {}
		end
		local panel = zeron.context("panel")
		local status = portcall.watch({ cwd = cwd })
		return ui.show(function(): boolean
			return status().state == "ok"
		end, ui.column {
			w_full = true,
			pt = "$zeron.list.gap",
			PanelHome.Row {
				id = "portcall-panel-row",
				icon = "remote-server",
				label = zeron.t("panel.row"),
				trail = Text {
					function(): string
						local s = status()
						return if s.state == "ok" then Services.summary(s.data.services) else ""
					end,
					style = "caption",
					tone = "secondary",
				},
				on_click = function()
					if panel then
						panel.open_tab {
							kind = "portcall-project",
							title = zeron.s("panel.tab"),
							icon = "remote-server",
							data = { cwd = cwd, key = cwd },
						}
					end
				end,
			},
		})
	end,
}

zeron.tab("portcall-project", function(tab: any): Node
	local cwd = tab.data and tab.data.cwd
	return ui.scroll {
		w_full = true,
		h_full = true,
		ui.column {
			w_full = true,
			p = "$space.4",
			if type(cwd) == "string" then ProjectView(portcall.watch({ cwd = cwd }), cwd) else ui.div {},
		},
	}
end)

zeron.page {
	id = "servers",
	title = zeron.t("page.title"),
	icon = "remote-server",
	build = function(_page: any): Node
		-- (Centred with a gutter, as Zeron's own pages are: Settings.Page keeps
		-- a reading width but no margin of its own outside Settings.)
		return ui.scroll {
			w_full = true,
			h_full = true,
			fade = { 16, 16 },
			fade_overflow = true,
			ui.column {
				w_full = true,
				min_h = "100%",
				items = "center",
				px = "$space.6",
				pt = "$space.6",
				pb = "$space.8",
				Settings.Page {
					title = zeron.t("page.title"),
					description = zeron.t("page.description"),
					trail = Button {
						zeron.t("action.refresh"),
						tone = "secondary",
						size = "sm",
						on_click = function()
							portcall.refresh()
						end,
					},
					AllView(portcall.watch({ all = true })),
				},
			},
		}
	end,
}

ui.command {
	id = "refresh",
	title = zeron.s("command.refresh"),
	run = function()
		portcall.refresh()
	end,
}
