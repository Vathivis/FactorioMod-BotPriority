data:extend({
	{
		type = "int-setting",
		name = "botpriority-operations-per-tick",
		setting_type = "runtime-global",
		default_value = 150,
		minimum_value = 10,
		maximum_value = 5000,
		order = "a"
	},
	{
		type = "bool-setting",
		name = "botpriority-safe-uninstall",
		setting_type = "runtime-global",
		default_value = false,
		order = "b"
	}
})
