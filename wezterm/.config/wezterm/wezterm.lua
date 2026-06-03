local wezterm = require("wezterm")
local act = wezterm.action

local config = wezterm.config_builder()

config.keys = {
	{ key = "a", mods = "ALT|SHIFT", action = act.ActivateCopyMode },
}

local function repeat_move(direction, count)
	local moves = {}
	for _ = 1, count do
		table.insert(moves, act.CopyMode(direction))
	end
	return act.Multiple(moves)
end

local copy_mode = wezterm.gui.default_key_tables().copy_mode
local n = 5
for _, m in ipairs({
	{ key = "j", dir = "MoveDown" },
	{ key = "k", dir = "MoveUp" },
	{ key = "h", dir = "MoveLeft" },
	{ key = "l", dir = "MoveRight" },
}) do
	table.insert(copy_mode, {
		key = m.key,
		mods = "SHIFT",
		action = repeat_move(m.dir, n),
	})
end

config.key_tables = { copy_mode = copy_mode }

config.automatically_reload_config = true
config.enable_tab_bar = false
config.window_close_confirmation = "NeverPrompt"
config.window_decorations = "RESIZE"
config.default_cursor_style = "BlinkingBar"
-- config.color_scheme = "Nord (Gogh)"
--
config.color_scheme = "Catppuccin Macchiato"

config.font = wezterm.font_with_fallback({
	"CaskaydiaCove Nerd Font Propo",
	-- "0xProto Nerd Font Mono",
	{ family = "Noto Sans CJK SC", weight = "Regular" },
	{ family = "PingFang SC", weight = "Medium" },
	"Apple Color Emoji",
})

config.send_composed_key_when_left_alt_is_pressed = false
config.send_composed_key_when_right_alt_is_pressed = false

-- config.window_decorations = "NONE"

config.font_size = 20.0

-- config.window_background_opacity = 0.65
config.window_background_opacity = 0.85
config.macos_window_background_blur = 20
--
config.colors = {
	background = "#1f1f1f",
	-- background = "#101010",
}

config.window_padding = {
	left = 0,
	right = 0,
	top = 0,
	bottom = 0,
}

return config
