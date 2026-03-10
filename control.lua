local MOD_TAG = "botpriority"
local TOOL_NAME = "botpriority-selector"
local CLONE_SURFACE_NAME = "botpriority-clone-surface"
local OPS_PER_TICK_SETTING = "botpriority-operations-per-tick"
local SAFE_UNINSTALL_SETTING = "botpriority-safe-uninstall"
local AUTO_RELEASE_CHECK_INTERVAL = 30

local function ensure_storage()
	storage.players = storage.players or {}
	storage.backlog_forces = storage.backlog_forces or {}
end

local function get_player_state(player_index)
	ensure_storage()

	local state = storage.players[player_index]
	if state then
		return state
	end

	state = {
		next_batch_id = 1
	}
	storage.players[player_index] = state
	return state
end

local function get_operation_budget()
	local setting = settings.global[OPS_PER_TICK_SETTING]
	if setting and type(setting.value) == "number" then
		return setting.value
	end

	return 150
end

local function is_safe_uninstall_requested()
	local setting = settings.global[SAFE_UNINSTALL_SETTING]
	return setting and setting.value == true or false
end

local function get_player_from_index(player_index)
	local player = game.get_player(player_index)
	if player and player.valid then
		return player
	end

	return nil
end

local function copy_position(position)
	return {
		x = position.x,
		y = position.y
	}
end

local function normalize_area(area)
	local left = area.left_top
	local right = area.right_bottom

	return {
		left_top = {
			x = math.min(left.x, right.x),
			y = math.min(left.y, right.y)
		},
		right_bottom = {
			x = math.max(left.x, right.x),
			y = math.max(left.y, right.y)
		}
	}
end

local function copy_area(area)
	local normalized = normalize_area(area)

	return {
		left_top = copy_position(normalized.left_top),
		right_bottom = copy_position(normalized.right_bottom)
	}
end

local function position_to_key(position)
	return string.format("%.4f:%.4f", position.x, position.y)
end

local function get_quality_name(entity)
	return entity.quality and entity.quality.name or nil
end

local function copy_tags(tags)
	local result = {}

	if not tags then
		return result
	end

	for key, value in pairs(tags) do
		result[key] = value
	end

	return result
end

local function count_string_set(source)
	local count = 0

	for _ in pairs(source) do
		count = count + 1
	end

	return count
end

local function build_batch_id(state)
	local batch_id = state.next_batch_id or 1
	state.next_batch_id = batch_id + 1
	return batch_id
end

local function get_clone_surface()
	local surface = game.surfaces[CLONE_SURFACE_NAME]
	if surface then
		return surface
	end

	surface = game.create_surface(CLONE_SURFACE_NAME)
	surface.daytime = 0
	surface.freeze_daytime = true
	return surface
end

local function remove_clone_surface_if_possible()
	local surface = game.surfaces[CLONE_SURFACE_NAME]
	if not surface then
		return true
	end

	return game.delete_surface(surface)
end

local function sync_force_state(source_force, target_force)
	if not (source_force and source_force.valid and target_force and target_force.valid) then
		return
	end

	for technology_name, source_technology in pairs(source_force.technologies) do
		local target_technology = target_force.technologies[technology_name]
		if target_technology then
			target_technology.researched = source_technology.researched
		end
	end

	for recipe_name, source_recipe in pairs(source_force.recipes) do
		local target_recipe = target_force.recipes[recipe_name]
		if target_recipe then
			target_recipe.enabled = source_recipe.enabled
		end
	end
end

local function get_backlog_force_name(source_force_name, player_index)
	return string.format("%s__botpriority_p%d", source_force_name, player_index)
end

local function ensure_backlog_force(player_index, source_force_name)
	local source_force = game.forces[source_force_name]
	if not source_force then
		return nil
	end

	local backlog_name = get_backlog_force_name(source_force_name, player_index)
	local backlog_force = game.forces[backlog_name]
	if not backlog_force then
		backlog_force = game.create_force(backlog_name)
	end

	source_force.set_friend(backlog_force, true)
	backlog_force.set_friend(source_force, true)
	source_force.set_cease_fire(backlog_force, true)
	backlog_force.set_cease_fire(source_force, true)
	sync_force_state(source_force, backlog_force)

	storage.backlog_forces[backlog_name] = {
		player_index = player_index,
		source_force_name = source_force_name
	}

	return backlog_force
end

local function merge_backlog_force(backlog_force_name, source_force_name)
	if not backlog_force_name then
		return
	end

	local backlog_force = game.forces[backlog_force_name]
	local source_force = game.forces[source_force_name]
	if backlog_force and source_force and backlog_force ~= source_force then
		game.merge_forces(backlog_force, source_force)
	end

	storage.backlog_forces[backlog_force_name] = nil
end

local function set_botpriority_tag(entity, tag_data)
	local tags = copy_tags(entity.tags)
	tags[MOD_TAG] = tag_data
	entity.tags = tags
end

local function clear_botpriority_tag(entity)
	local tags = copy_tags(entity.tags)
	tags[MOD_TAG] = nil
	entity.tags = tags
end

local function make_ghost_descriptor(entity, current_force_name, original_force_name)
	return {
		surface_index = entity.surface.index,
		position = copy_position(entity.position),
		ghost_name = entity.ghost_name,
		direction = entity.direction,
		quality_name = get_quality_name(entity),
		current_force_name = current_force_name or entity.force.name,
		original_force_name = original_force_name or entity.force.name
	}
end

local function make_entity_descriptor(entity, current_force_name, original_force_name)
	return {
		surface_index = entity.surface.index,
		position = copy_position(entity.position),
		entity_name = entity.name,
		direction = entity.direction,
		quality_name = get_quality_name(entity),
		current_force_name = current_force_name or entity.force.name,
		original_force_name = original_force_name or entity.force.name
	}
end

local function make_upgrade_descriptor(entity, current_force_name, original_force_name)
	local target, target_quality = entity.get_upgrade_target()
	if not target then
		return nil
	end

	local descriptor = make_entity_descriptor(entity, current_force_name, original_force_name)
	descriptor.target_name = target.name
	descriptor.target_quality_name = target_quality and target_quality.name or nil
	return descriptor
end

local function build_ghost_key(entity)
	return table.concat({
		tostring(entity.surface.index),
		position_to_key(entity.position),
		entity.ghost_name or "",
		tostring(entity.direction or 0),
		get_quality_name(entity) or ""
	}, "|")
end

local function build_entity_descriptor_key(descriptor)
	return table.concat({
		tostring(descriptor.surface_index),
		position_to_key(descriptor.position),
		descriptor.entity_name or "",
		tostring(descriptor.direction or 0),
		descriptor.quality_name or ""
	}, "|")
end

local function build_upgrade_descriptor_key(descriptor)
	return table.concat({
		build_entity_descriptor_key(descriptor),
		descriptor.target_name or "",
		descriptor.target_quality_name or ""
	}, "|")
end

local function upgrade_target_value(descriptor)
	if descriptor.target_quality_name then
		return {
			name = descriptor.target_name,
			quality = descriptor.target_quality_name
		}
	end

	return descriptor.target_name
end

local function find_descriptor_ghost(descriptor, expected_force_name)
	local surface = game.surfaces[descriptor.surface_index]
	if not surface then
		return nil
	end

	local ghosts = surface.find_entities_filtered({
		position = descriptor.position,
		name = "entity-ghost",
		force = expected_force_name
	})

	for _, ghost in ipairs(ghosts) do
		if ghost.valid
			and ghost.type == "entity-ghost"
			and ghost.ghost_name == descriptor.ghost_name
			and ghost.direction == descriptor.direction
			and get_quality_name(ghost) == descriptor.quality_name then
			return ghost
		end
	end

	return nil
end

local function find_descriptor_entity(descriptor, expected_force_name)
	local surface = game.surfaces[descriptor.surface_index]
	if not surface then
		return nil
	end

	local entities = surface.find_entities_filtered({
		position = descriptor.position,
		name = descriptor.entity_name,
		force = expected_force_name
	})

	for _, entity in ipairs(entities) do
		if entity.valid
			and entity.type ~= "entity-ghost"
			and entity.direction == descriptor.direction
			and get_quality_name(entity) == descriptor.quality_name then
			return entity
		end
	end

	return nil
end

local function upgrade_matches_descriptor(entity, descriptor)
	if not entity.to_be_upgraded() then
		return false
	end

	local target, target_quality = entity.get_upgrade_target()
	if not target then
		return false
	end

	return target.name == descriptor.target_name
		and (target_quality and target_quality.name or nil) == descriptor.target_quality_name
end

local function build_restore_queue(batch)
	local queue = {}

	for index = 1, #batch.moved_ghosts do
		queue[#queue + 1] = {
			kind = "restore_ghost",
			descriptor = batch.moved_ghosts[index],
			require_batch_tag = true
		}
	end

	for index = 1, #batch.paused_deconstruction_entities do
		queue[#queue + 1] = {
			kind = "restore_deconstruction",
			descriptor = batch.paused_deconstruction_entities[index]
		}
	end

	for index = 1, #batch.paused_upgrade_entities do
		queue[#queue + 1] = {
			kind = "restore_upgrade",
			descriptor = batch.paused_upgrade_entities[index]
		}
	end

	return queue
end

local function has_pending_player_operations()
	for _, state in pairs(storage.players) do
		if state.pending then
			return true
		end
	end

	return false
end

local function is_cleanup_active()
	return storage.cleanup ~= nil
end

local function get_optional_other_force_message(count)
	if count <= 0 then
		return ""
	end

	return { "botpriority-message.unsupported-other-force", count }
end

local function build_apply_message(stats, skipped_other_force)
	return {
		"botpriority-message.applied",
		stats.paused_ghosts or 0,
		stats.paused_deconstruction or 0,
		stats.paused_upgrades or 0,
		stats.refreshed_ghosts or 0,
		stats.refreshed_deconstruction or 0,
		stats.refreshed_upgrades or 0,
		get_optional_other_force_message(skipped_other_force or 0)
	}
end

local function build_clear_message(stats)
	return {
		"botpriority-message.cleared",
		stats.restored_ghosts or 0,
		stats.restored_deconstruction or 0,
		stats.restored_upgrades or 0
	}
end

local function relocate_ghost_entity(ghost, target_force_name, tag_data)
	if not (ghost and ghost.valid and ghost.type == "entity-ghost") then
		return nil
	end

	local target_force = game.forces[target_force_name]
	if not target_force then
		return nil
	end

	local clone_surface = get_clone_surface()
	local source_surface = ghost.surface
	local source_force = ghost.force
	local source_position = copy_position(ghost.position)

	local temp_clone = ghost.clone({
		surface = clone_surface,
		position = { x = 0, y = 0 },
		force = target_force,
		create_build_effect_smoke = false
	})
	if not temp_clone then
		return nil
	end

	ghost.destroy()

	local moved_clone = temp_clone.clone({
		surface = source_surface,
		position = source_position,
		force = target_force,
		create_build_effect_smoke = false
	})

	if not moved_clone then
		temp_clone.clone({
			surface = source_surface,
			position = source_position,
			force = source_force,
			create_build_effect_smoke = false
		})
		temp_clone.destroy()
		return nil
	end

	temp_clone.destroy()

	if tag_data then
		set_botpriority_tag(moved_clone, tag_data)
	else
		clear_botpriority_tag(moved_clone)
	end

	return moved_clone
end

local function process_restore_item(work_item, player, clear_batch, stats)
	local descriptor = work_item.descriptor

	if work_item.kind == "restore_ghost" then
		local ghost = find_descriptor_ghost(descriptor, descriptor.current_force_name)
		if not ghost then
			return
		end

		if work_item.require_batch_tag then
			local tag = ghost.tags and ghost.tags[MOD_TAG]
			if not (tag
				and clear_batch
				and tag.owner_player_index == player.index
				and tag.batch_id == clear_batch.id) then
				return
			end
		end

		local restored = relocate_ghost_entity(ghost, descriptor.original_force_name, false)
		if restored then
			clear_botpriority_tag(restored)
			stats.restored_ghosts = stats.restored_ghosts + 1
		end
		return
	end

	if work_item.kind == "restore_deconstruction" then
		local entity = find_descriptor_entity(descriptor, descriptor.current_force_name)
		if entity then
			if entity.order_deconstruction(descriptor.original_force_name, player.index) then
				stats.restored_deconstruction = stats.restored_deconstruction + 1
			end
		end
		return
	end

	if work_item.kind == "restore_upgrade" then
		local entity = find_descriptor_entity(descriptor, descriptor.current_force_name)
		if entity then
			if entity.order_upgrade({
				target = upgrade_target_value(descriptor),
				force = descriptor.original_force_name,
				player = player.index
			}) then
				stats.restored_upgrades = stats.restored_upgrades + 1
			end
		end
	end
end

local function batch_has_remaining_priority_work(batch)
	local remaining_ghosts = {}
	for index = 1, #batch.selected_ghosts do
		local descriptor = batch.selected_ghosts[index]
		local ghost = find_descriptor_ghost(descriptor, batch.source_force_name)
		if ghost then
			remaining_ghosts[#remaining_ghosts + 1] =
				make_ghost_descriptor(ghost, batch.source_force_name, batch.source_force_name)
		end
	end
	batch.selected_ghosts = remaining_ghosts

	local remaining_deconstruction = {}
	for index = 1, #batch.selected_deconstruction_entities do
		local descriptor = batch.selected_deconstruction_entities[index]
		local entity = find_descriptor_entity(descriptor, batch.source_force_name)
		if entity and entity.to_be_deconstructed() then
			remaining_deconstruction[#remaining_deconstruction + 1] =
				make_entity_descriptor(entity, batch.source_force_name, batch.source_force_name)
		end
	end
	batch.selected_deconstruction_entities = remaining_deconstruction

	local remaining_upgrades = {}
	for index = 1, #batch.selected_upgrade_entities do
		local descriptor = batch.selected_upgrade_entities[index]
		local entity = find_descriptor_entity(descriptor, batch.source_force_name)
		if entity and upgrade_matches_descriptor(entity, descriptor) then
			local refreshed_descriptor = make_upgrade_descriptor(entity, batch.source_force_name, batch.source_force_name)
			if refreshed_descriptor then
				remaining_upgrades[#remaining_upgrades + 1] = refreshed_descriptor
			end
		end
	end
	batch.selected_upgrade_entities = remaining_upgrades

	return #remaining_ghosts > 0
		or #remaining_deconstruction > 0
		or #remaining_upgrades > 0
end

local function should_auto_release_batch(state)
	local batch = state.active_batch
	if not batch then
		return false
	end

	local next_check_tick = state.next_completion_check_tick or 0
	if game.tick < next_check_tick then
		return false
	end

	state.next_completion_check_tick = game.tick + AUTO_RELEASE_CHECK_INTERVAL
	return not batch_has_remaining_priority_work(batch)
end

local function finish_operation(player, state, operation)
	if operation.kind == "clear" then
		if operation.clear_batch then
			merge_backlog_force(operation.clear_batch.backlog_force_name, operation.clear_batch.source_force_name)
		end

		player.print(build_clear_message(operation.stats))
		state.next_completion_check_tick = nil
		state.pending = nil
		return
	end

	if operation.kind == "replace" or operation.kind == "apply" then
		state.active_batch = operation.pending_batch
		state.next_completion_check_tick = game.tick + AUTO_RELEASE_CHECK_INTERVAL
		state.pending = nil

		player.print(build_apply_message(operation.stats, operation.stats.skipped_other_force))
	end
end

local function process_restore_phase(player, state, operation, budget)
	while budget > 0 and operation.restore_index <= #operation.restore_queue do
		process_restore_item(
			operation.restore_queue[operation.restore_index],
			player,
			operation.clear_batch,
			operation.stats
		)
		operation.restore_index = operation.restore_index + 1
		budget = budget - 1
	end

	if operation.restore_index <= #operation.restore_queue then
		return budget
	end

	if state.active_batch and operation.clear_batch and state.active_batch.id == operation.clear_batch.id then
		state.active_batch = nil
	end

	if operation.kind == "replace" then
		operation.phase = "prepare"
	else
		finish_operation(player, state, operation)
	end

	return budget
end

local function process_apply_item(work_item, operation, player)
	if work_item.kind == "pause_ghost" then
		local ghost = find_descriptor_ghost(work_item.descriptor, operation.pending_batch.source_force_name)
		if ghost then
			local moved = relocate_ghost_entity(ghost, operation.pending_batch.backlog_force_name, {
				batch_id = operation.pending_batch.id,
				owner_player_index = player.index,
				original_force_name = operation.pending_batch.source_force_name
			})

			if moved then
				operation.pending_batch.moved_ghosts[#operation.pending_batch.moved_ghosts + 1] =
					make_ghost_descriptor(moved, operation.pending_batch.backlog_force_name, operation.pending_batch.source_force_name)
				operation.stats.paused_ghosts = operation.stats.paused_ghosts + 1
			end
		end
		return
	end

	if work_item.kind == "refresh_ghost" then
		local ghost = find_descriptor_ghost(work_item.descriptor, operation.pending_batch.source_force_name)
		if ghost then
			local refreshed = relocate_ghost_entity(ghost, operation.pending_batch.source_force_name, false)
			if refreshed then
				operation.stats.refreshed_ghosts = operation.stats.refreshed_ghosts + 1
			end
		end
		return
	end

	if work_item.kind == "pause_deconstruction" then
		local entity = find_descriptor_entity(work_item.descriptor, operation.pending_batch.source_force_name)
		if entity and entity.to_be_deconstructed() then
			entity.cancel_deconstruction(operation.pending_batch.source_force_name, player.index)
			if not entity.to_be_deconstructed() then
				operation.pending_batch.paused_deconstruction_entities[#operation.pending_batch.paused_deconstruction_entities + 1] =
					make_entity_descriptor(entity, operation.pending_batch.source_force_name, operation.pending_batch.source_force_name)
				operation.stats.paused_deconstruction = operation.stats.paused_deconstruction + 1
			end
		end
		return
	end

	if work_item.kind == "refresh_deconstruction" then
		local entity = find_descriptor_entity(work_item.descriptor, operation.pending_batch.source_force_name)
		if entity and entity.to_be_deconstructed() then
			entity.cancel_deconstruction(operation.pending_batch.source_force_name, player.index)
			if entity.order_deconstruction(operation.pending_batch.source_force_name, player.index) then
				operation.stats.refreshed_deconstruction = operation.stats.refreshed_deconstruction + 1
			end
		end
		return
	end

	if work_item.kind == "pause_upgrade" then
		local entity = find_descriptor_entity(work_item.descriptor, operation.pending_batch.source_force_name)
		if entity and upgrade_matches_descriptor(entity, work_item.descriptor) then
			entity.cancel_upgrade(operation.pending_batch.source_force_name, player.index)
			if not entity.to_be_upgraded() then
				operation.pending_batch.paused_upgrade_entities[#operation.pending_batch.paused_upgrade_entities + 1] = work_item.descriptor
				operation.stats.paused_upgrades = operation.stats.paused_upgrades + 1
			end
		end
		return
	end

	if work_item.kind == "refresh_upgrade" then
		local entity = find_descriptor_entity(work_item.descriptor, operation.pending_batch.source_force_name)
		if entity and upgrade_matches_descriptor(entity, work_item.descriptor) then
			entity.cancel_upgrade(operation.pending_batch.source_force_name, player.index)
			if entity.order_upgrade({
				target = upgrade_target_value(work_item.descriptor),
				force = operation.pending_batch.source_force_name,
				player = player.index
			}) then
				operation.stats.refreshed_upgrades = operation.stats.refreshed_upgrades + 1
			end
		end
	end
end

local function selection_has_supported_work(surface, area, source_force_name)
	local selected_entities = surface.find_entities_filtered({
		area = area
	})

	for _, entity in ipairs(selected_entities) do
		if entity.force.name == source_force_name then
			if entity.type == "entity-ghost" then
				return true
			end

			if entity.to_be_deconstructed and entity.to_be_deconstructed() then
				return true
			end

			if entity.to_be_upgraded and entity.to_be_upgraded() then
				local descriptor = make_upgrade_descriptor(entity, source_force_name, source_force_name)
				if descriptor then
					return true
				end
			end
		end
	end

	return false
end

local function prepare_apply_phase(player, state, operation)
	local request = operation.apply_request
	local surface = game.surfaces[request.surface_index]
	if not surface then
		player.print({ "botpriority-message.surface-missing" })
		state.pending = nil
		return
	end

	local source_force = game.forces[request.source_force_name]
	if not source_force then
		player.print({ "botpriority-message.force-missing" })
		state.pending = nil
		return
	end

	local backlog_force = ensure_backlog_force(player.index, request.source_force_name)
	if not backlog_force then
		player.print({ "botpriority-message.force-missing" })
		state.pending = nil
		return
	end

	local selected_ghosts = {}
	local selected_deconstruction_entities = {}
	local selected_upgrade_entities = {}
	local ghost_keys = {}
	local deconstruction_keys = {}
	local upgrade_keys = {}
	local ghost_prototypes = {}
	local deconstruction_names = {}
	local upgrade_pairs = {}
	local apply_queue = {}
	local skipped_other_force = 0

	local selected_entities = surface.find_entities_filtered({
		area = request.area
	})

	for _, entity in ipairs(selected_entities) do
		if entity.type == "entity-ghost" then
			if entity.force.name == request.source_force_name then
				local descriptor = make_ghost_descriptor(entity, request.source_force_name, request.source_force_name)
				selected_ghosts[#selected_ghosts + 1] = descriptor
				ghost_keys[build_ghost_key(entity)] = true
				ghost_prototypes[entity.ghost_name] = true
				apply_queue[#apply_queue + 1] = {
					kind = "refresh_ghost",
					descriptor = descriptor
				}
			else
				skipped_other_force = skipped_other_force + 1
			end
		elseif entity.force.name == request.source_force_name then
			if entity.to_be_deconstructed and entity.to_be_deconstructed() then
				local descriptor = make_entity_descriptor(entity, request.source_force_name, request.source_force_name)
				selected_deconstruction_entities[#selected_deconstruction_entities + 1] = descriptor
				deconstruction_keys[build_entity_descriptor_key(descriptor)] = true
				deconstruction_names[entity.name] = true
				apply_queue[#apply_queue + 1] = {
					kind = "refresh_deconstruction",
					descriptor = descriptor
				}
			end

			if entity.to_be_upgraded and entity.to_be_upgraded() then
				local descriptor = make_upgrade_descriptor(entity, request.source_force_name, request.source_force_name)
				if descriptor then
					selected_upgrade_entities[#selected_upgrade_entities + 1] = descriptor
					local upgrade_key = build_upgrade_descriptor_key(descriptor)
					upgrade_keys[upgrade_key] = true
					upgrade_pairs[upgrade_key] = true
					apply_queue[#apply_queue + 1] = {
						kind = "refresh_upgrade",
						descriptor = descriptor
					}
				end
			end
		elseif (entity.to_be_deconstructed and entity.to_be_deconstructed())
			or (entity.to_be_upgraded and entity.to_be_upgraded()) then
			skipped_other_force = skipped_other_force + 1
		end
	end

	if #selected_ghosts == 0
		and #selected_deconstruction_entities == 0
		and #selected_upgrade_entities == 0 then
		player.print({ "botpriority-message.no-selection" })
		state.pending = nil
		return
	end

	if next(ghost_prototypes) ~= nil then
		local candidate_ghosts = surface.find_entities_filtered({
			type = "entity-ghost",
			force = request.source_force_name
		})

		for _, ghost in ipairs(candidate_ghosts) do
			if ghost_prototypes[ghost.ghost_name] and not ghost_keys[build_ghost_key(ghost)] then
				apply_queue[#apply_queue + 1] = {
					kind = "pause_ghost",
					descriptor = make_ghost_descriptor(ghost, request.source_force_name, request.source_force_name)
				}
			end
		end
	end

	if next(deconstruction_names) ~= nil or next(upgrade_pairs) ~= nil then
		local candidate_entities = surface.find_entities_filtered({
			force = request.source_force_name
		})

		for _, entity in ipairs(candidate_entities) do
			if entity.type ~= "entity-ghost" then
				if next(deconstruction_names) ~= nil and entity.to_be_deconstructed and entity.to_be_deconstructed() then
					local descriptor = make_entity_descriptor(entity, request.source_force_name, request.source_force_name)
					if deconstruction_names[entity.name]
						and not deconstruction_keys[build_entity_descriptor_key(descriptor)] then
						apply_queue[#apply_queue + 1] = {
							kind = "pause_deconstruction",
							descriptor = descriptor
						}
					end
				end

				if next(upgrade_pairs) ~= nil and entity.to_be_upgraded and entity.to_be_upgraded() then
					local descriptor = make_upgrade_descriptor(entity, request.source_force_name, request.source_force_name)
					if descriptor then
						local upgrade_key = build_upgrade_descriptor_key(descriptor)
						if upgrade_pairs[upgrade_key] and not upgrade_keys[upgrade_key] then
							apply_queue[#apply_queue + 1] = {
								kind = "pause_upgrade",
								descriptor = descriptor
							}
						end
					end
				end
			end
		end
	end

	operation.phase = "apply"
	operation.apply_queue = apply_queue
	operation.apply_index = 1
	operation.pending_batch = {
		id = build_batch_id(state),
		player_index = player.index,
		source_force_name = request.source_force_name,
		backlog_force_name = backlog_force.name,
		surface_index = request.surface_index,
		area = copy_area(request.area),
		selected_ghosts = selected_ghosts,
		moved_ghosts = {},
		selected_deconstruction_entities = selected_deconstruction_entities,
		paused_deconstruction_entities = {},
		selected_upgrade_entities = selected_upgrade_entities,
		paused_upgrade_entities = {}
	}
	operation.stats.skipped_other_force = skipped_other_force
end

local function process_apply_phase(player, state, operation, budget)
	while budget > 0 and operation.apply_index <= #operation.apply_queue do
		process_apply_item(operation.apply_queue[operation.apply_index], operation, player)
		operation.apply_index = operation.apply_index + 1
		budget = budget - 1
	end

	if operation.apply_index > #operation.apply_queue then
		finish_operation(player, state, operation)
	end

	return budget
end

local function process_player_operation(player_index, budget)
	local state = storage.players[player_index]
	if not (state and state.pending) then
		return budget
	end

	local player = get_player_from_index(player_index)
	if not player then
		return budget
	end

	while budget > 0 and state.pending do
		local operation = state.pending

		if operation.phase == "restore" then
			budget = process_restore_phase(player, state, operation, budget)
		elseif operation.phase == "prepare" then
			prepare_apply_phase(player, state, operation)
		elseif operation.phase == "apply" then
			budget = process_apply_phase(player, state, operation, budget)
		else
			state.pending = nil
			break
		end
	end

	return budget
end

local function start_clear(player, suppress_empty_message)
	local state = get_player_state(player.index)
	if is_safe_uninstall_requested() or is_cleanup_active() then
		player.print({ "botpriority-message.cleanup-setting-on" })
		return
	end

	if state.pending then
		player.print({ "botpriority-message.busy" })
		return
	end

	if not state.active_batch then
		if not suppress_empty_message then
			player.print({ "botpriority-message.already-clear" })
		end
		return
	end

	state.pending = {
		kind = "clear",
		phase = "restore",
		clear_batch = state.active_batch,
		restore_queue = build_restore_queue(state.active_batch),
		restore_index = 1,
		stats = {
			restored_ghosts = 0,
			restored_deconstruction = 0,
			restored_upgrades = 0
		}
	}

	process_player_operation(player.index, get_operation_budget())
end

local function start_apply(player, surface, area)
	local state = get_player_state(player.index)
	if is_safe_uninstall_requested() or is_cleanup_active() then
		player.print({ "botpriority-message.cleanup-setting-on" })
		return
	end

	if state.pending then
		player.print({ "botpriority-message.busy" })
		return
	end

	local request = {
		surface_index = surface.index,
		area = copy_area(area),
		source_force_name = player.force.name
	}

	local stats = {
		restored_ghosts = 0,
		restored_deconstruction = 0,
		restored_upgrades = 0,
		paused_ghosts = 0,
		paused_deconstruction = 0,
		paused_upgrades = 0,
		refreshed_ghosts = 0,
		refreshed_deconstruction = 0,
		refreshed_upgrades = 0,
		skipped_other_force = 0
	}

	if not selection_has_supported_work(surface, area, player.force.name) then
		player.print({ "botpriority-message.no-selection" })
		return
	end

	if state.active_batch then
		state.pending = {
			kind = "replace",
			phase = "restore",
			clear_batch = state.active_batch,
			restore_queue = build_restore_queue(state.active_batch),
			restore_index = 1,
			apply_request = request,
			stats = stats
		}
	else
		state.pending = {
			kind = "apply",
			phase = "prepare",
			apply_request = request,
			stats = stats
		}
	end

	process_player_operation(player.index, get_operation_budget())
end

local function handle_selected_area(event)
	if event.item ~= TOOL_NAME then
		return
	end

	local player = get_player_from_index(event.player_index)
	if not player then
		return
	end

	local surface = event.surface or player.surface
	start_apply(player, surface, event.area)
end

local function handle_reverse_selected_area(event)
	if event.item ~= TOOL_NAME then
		return
	end

	local player = get_player_from_index(event.player_index)
	if not player then
		return
	end

	start_clear(player)
end

local function build_backlog_cleanup_entries()
	local entries = {}

	for backlog_force_name, force_data in pairs(storage.backlog_forces) do
		entries[#entries + 1] = {
			backlog_force_name = backlog_force_name,
			source_force_name = force_data.source_force_name
		}
	end

	table.sort(entries, function(left, right)
		return left.backlog_force_name < right.backlog_force_name
	end)

	return entries
end

local function reset_player_batches_for_cleanup()
	for _, state in pairs(storage.players) do
		state.pending = nil
		state.active_batch = nil
		state.next_completion_check_tick = nil
	end
end

local function begin_safe_uninstall_cleanup()
	ensure_storage()

	if storage.cleanup or has_pending_player_operations() then
		return
	end

	local restore_queue = {}
	for _, state in pairs(storage.players) do
		local batch = state.active_batch
		if batch then
			for index = 1, #batch.paused_deconstruction_entities do
				restore_queue[#restore_queue + 1] = {
					kind = "restore_deconstruction",
					descriptor = batch.paused_deconstruction_entities[index]
				}
			end

			for index = 1, #batch.paused_upgrade_entities do
				restore_queue[#restore_queue + 1] = {
					kind = "restore_upgrade",
					descriptor = batch.paused_upgrade_entities[index]
				}
			end
		end
	end

	storage.cleanup = {
		phase = "scan",
		entries = build_backlog_cleanup_entries(),
		scan_index = 1,
		restore_queue = restore_queue,
		restore_index = 1,
		merge_index = 1,
		stats = {
			restored_ghosts = 0,
			restored_deconstruction = 0,
			restored_upgrades = 0,
			merged = 0
		}
	}
end

local function scan_cleanup_backlog_force(cleanup, entry)
	local backlog_force = game.forces[entry.backlog_force_name]
	if not backlog_force then
		return
	end

	for _, surface in pairs(game.surfaces) do
		local ghosts = surface.find_entities_filtered({
			type = "entity-ghost",
			force = entry.backlog_force_name
		})

		for _, ghost in ipairs(ghosts) do
			local tag = ghost.tags and ghost.tags[MOD_TAG]
			local original_force_name = entry.source_force_name
			if tag and tag.original_force_name then
				original_force_name = tag.original_force_name
			end

			cleanup.restore_queue[#cleanup.restore_queue + 1] = {
				kind = "restore_ghost",
				descriptor = make_ghost_descriptor(ghost, entry.backlog_force_name, original_force_name),
				require_batch_tag = false
			}
		end
	end
end

local function finalize_cleanup()
	local cleanup = storage.cleanup
	if not cleanup then
		return
	end

	local clone_surface_result = remove_clone_surface_if_possible() and "deleted" or "kept"
	storage.cleanup = nil
	reset_player_batches_for_cleanup()

	game.print({
		"botpriority-message.cleanup-finished",
		cleanup.stats.restored_ghosts or 0,
		cleanup.stats.restored_deconstruction or 0,
		cleanup.stats.restored_upgrades or 0,
		cleanup.stats.merged or 0,
		clone_surface_result
	})
end

local function process_cleanup_operation(budget)
	local cleanup = storage.cleanup
	if not cleanup then
		return
	end

	local player = game.connected_players[1] or game.players[1]
	if not player then
		return
	end

	while budget > 0 and storage.cleanup do
		if cleanup.phase == "scan" then
			if cleanup.scan_index <= #cleanup.entries then
				scan_cleanup_backlog_force(cleanup, cleanup.entries[cleanup.scan_index])
				cleanup.scan_index = cleanup.scan_index + 1
				budget = budget - 1
			else
				cleanup.phase = "restore"
			end
		elseif cleanup.phase == "restore" then
			while budget > 0 and cleanup.restore_index <= #cleanup.restore_queue do
				process_restore_item(cleanup.restore_queue[cleanup.restore_index], player, nil, cleanup.stats)
				cleanup.restore_index = cleanup.restore_index + 1
				budget = budget - 1
			end

			if cleanup.restore_index > #cleanup.restore_queue then
				cleanup.phase = "merge"
			end
		elseif cleanup.phase == "merge" then
			if cleanup.merge_index <= #cleanup.entries then
				local entry = cleanup.entries[cleanup.merge_index]
				cleanup.merge_index = cleanup.merge_index + 1
				budget = budget - 1

				local backlog_force = game.forces[entry.backlog_force_name]
				local source_force = game.forces[entry.source_force_name]
				if backlog_force and source_force and backlog_force ~= source_force then
					game.merge_forces(backlog_force, source_force)
					cleanup.stats.merged = cleanup.stats.merged + 1
				end

				storage.backlog_forces[entry.backlog_force_name] = nil
			else
				finalize_cleanup()
			end
		else
			finalize_cleanup()
		end

		cleanup = storage.cleanup
	end
end

local function sync_registered_backlog_forces()
	ensure_storage()

	for backlog_name, force_data in pairs(storage.backlog_forces) do
		local source_force = game.forces[force_data.source_force_name]
		local backlog_force = game.forces[backlog_name]
		if source_force and backlog_force then
			source_force.set_friend(backlog_force, true)
			backlog_force.set_friend(source_force, true)
			source_force.set_cease_fire(backlog_force, true)
			backlog_force.set_cease_fire(source_force, true)
			sync_force_state(source_force, backlog_force)
		end
	end
end

script.on_init(function()
	ensure_storage()
end)

script.on_configuration_changed(function()
	ensure_storage()
	sync_registered_backlog_forces()
end)

script.on_event(defines.events.on_research_finished, function(event)
	ensure_storage()

	for backlog_name, force_data in pairs(storage.backlog_forces) do
		if force_data.source_force_name == event.research.force.name then
			local backlog_force = game.forces[backlog_name]
			if backlog_force then
				sync_force_state(event.research.force, backlog_force)
			end
		end
	end
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting ~= SAFE_UNINSTALL_SETTING then
		return
	end

	ensure_storage()

	if is_safe_uninstall_requested() then
		game.print({ "botpriority-message.cleanup-started" })
	elseif storage.cleanup then
		game.print({ "botpriority-message.cleanup-running" })
	else
		game.print({ "botpriority-message.cleanup-disabled" })
	end
end)

script.on_event(defines.events.on_player_selected_area, handle_selected_area)
script.on_event(defines.events.on_player_alt_selected_area, handle_selected_area)
script.on_event(defines.events.on_player_reverse_selected_area, handle_reverse_selected_area)
script.on_event(defines.events.on_player_alt_reverse_selected_area, handle_reverse_selected_area)

script.on_event(defines.events.on_tick, function()
	ensure_storage()

	local budget = get_operation_budget()
	if storage.cleanup then
		process_cleanup_operation(budget)
		return
	end

	if is_safe_uninstall_requested() then
		if has_pending_player_operations() then
			for player_index in pairs(storage.players) do
				budget = process_player_operation(player_index, budget)
				if budget <= 0 then
					return
				end
			end
			return
		end

		begin_safe_uninstall_cleanup()
		if storage.cleanup then
			process_cleanup_operation(budget)
		end
		return
	end

	for player_index, state in pairs(storage.players) do
		if state.pending then
			budget = process_player_operation(player_index, budget)
			if budget <= 0 then
				return
			end
		elseif state.active_batch then
			local player = get_player_from_index(player_index)
			if player and should_auto_release_batch(state) then
				start_clear(player, true)
			end
		end
	end
end)
