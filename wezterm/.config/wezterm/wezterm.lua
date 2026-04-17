local wezterm = require("wezterm")

local config = wezterm.config_builder()

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
