-- git
require("git"):setup()

-- full-border
require("full-border"):setup()

-- DuckDB plugin configuration
require("duckdb"):setup({
	mode = "standard", -- "standard" / "summarized"
	cache_size = 1000, -- Default: 500
	row_id = "dynamic", -- false / true / 'dynamic'
	minmax_column_width = 21, -- Default: 21
	column_fit_factor = 10.0, -- Default: 10.0
})

-- bunny (bookmarks / directory hopping) — edit `hops` to taste
require("bunny"):setup({
	hops = {
		{ key = "~", path = "~",           desc = "Home" },
		{ key = "c", path = "~/.config",   desc = "Config" },
		{ key = "f", path = "~/.dotfiles", desc = "Dotfiles" },
		{ key = "p", path = "~/projects",  desc = "Projects" },
		{ key = "d", path = "~/Downloads", desc = "Downloads" },
		{ key = "D", path = "~/Documents", desc = "Documents" },
		{ key = "s", path = "~/Desktop",   desc = "Desktop" },
		{ key = "t", path = "/tmp",        desc = "Temp" },
	},
	desc_strategy = "path", -- fall back to path when a hop has no desc
	ephemeral = true, -- allow creating temporary bookmarks during a session
	tabs = true, -- list dirs open in other tabs as hops
	notify = false,
	fuzzy_cmd = "fzf",
})

-- Status-line and Header-line config
require("yatline"):setup({
	show_background = false,

	header_line = {
		left = {
			section_a = {
				{ type = "line", custom = false, name = "tabs", params = { "left" } },
			},
			section_b = {},
			section_c = {},
		},
		right = {
			section_a = {},
			section_b = {},
			section_c = {},
		},
	},

	status_line = {
		left = {
			section_a = {
				{ type = "string", custom = false, name = "tab_mode" },
			},
			section_b = {
				{ type = "string", custom = false, name = "hovered_size" },
			},
			section_c = {
				{ type = "string", custom = false, name = "hovered_path" },
				{ type = "coloreds", custom = false, name = "count" },
			},
		},
		right = {
			section_a = {
				{ type = "string", custom = false, name = "cursor_position" },
			},
			section_b = {
				{ type = "string", custom = false, name = "cursor_percentage" },
			},
			section_c = {
				{ type = "string", custom = false, name = "hovered_file_extension", params = { true } },
				{ type = "coloreds", custom = false, name = "permissions" },
			},
		},
	},
})

-- yatline (rev c5d4b48) still calls the `File:icon()` API that yazi 26.8 deprecated
-- in favour of `th.icon:match(file)`. Override the one component that hits it,
-- rather than patching the vendored plugin (which `ya pkg` upgrades would clobber).
function Yatline.string.get:hovered_file_extension(show_icon)
	local hovered = cx.active.current.hovered
	if not hovered then
		return ""
	end

	local name
	if hovered.cha.is_dir then
		name = "dir"
	else
		name = hovered.url.name:match("^.+%.(.+)$") or "null"
	end

	if not show_icon then
		return name
	end

	local icon
	if th.icon then
		icon = th.icon:match(hovered)
	else -- yazi < 25.x fallback
		icon = hovered:icon()
	end

	return (icon and icon.text .. " " or "") .. name
end
