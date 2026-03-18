local wezterm = require("wezterm")

config = wezterm.config_builder()

config = {
	automatically_reload_config = true,
	enable_tab_bar = true,
	window_decorations = "RESIZE",
	hide_tab_bar_if_only_one_tab = true,
	window_background_opacity = 0.9,
	color_scheme = "Nord (Gogh)",
	font = wezterm.font("JetBrains Mono", { weight = "Bold" }),
	font_size = 15.0,
}

config.keys = {
	{
		key = "d",
		mods = "CMD",
		action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }),
	},
	{
		key = "w",
		mods = "CMD",
		action = wezterm.action.CloseCurrentPane({ confirm = false }),
	},
	{
		key = "d",
		mods = "CMD|SHIFT",
		action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }),
	},
	{
		key = "k",
		mods = "CMD",
		action = wezterm.action.SendString("clear\n"),
	},
}

return config

