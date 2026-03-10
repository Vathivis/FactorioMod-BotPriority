local selection_color = { r = 0.15, g = 0.8, b = 1.0, a = 1.0 }
local clear_color = { r = 1.0, g = 0.3, b = 0.3, a = 1.0 }
local highlighted_entity_types = { "entity-ghost" }

data:extend({
	{
		type = "selection-tool",
		name = "botpriority-selector",
		icon = "__BotPriority__/prio_icon.png",
		icon_size = 64,
		flags = { "spawnable", "only-in-cursor", "not-stackable" },
		subgroup = "tool",
		order = "c[automated-construction]-z[botpriority]",
		stack_size = 1,
		select = {
			border_color = selection_color,
			cursor_box_type = "copy",
			mode = { "any-entity" },
			entity_filter_mode = "whitelist",
			entity_type_filters = highlighted_entity_types
		},
		alt_select = {
			border_color = selection_color,
			cursor_box_type = "copy",
			mode = { "any-entity" },
			entity_filter_mode = "whitelist",
			entity_type_filters = highlighted_entity_types
		},
		reverse_select = {
			border_color = clear_color,
			cursor_box_type = "not-allowed",
			mode = { "any-entity" },
			entity_filter_mode = "whitelist",
			entity_type_filters = highlighted_entity_types
		},
		alt_reverse_select = {
			border_color = clear_color,
			cursor_box_type = "not-allowed",
			mode = { "any-entity" },
			entity_filter_mode = "whitelist",
			entity_type_filters = highlighted_entity_types
		}
	}
})
