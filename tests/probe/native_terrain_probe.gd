extends Node

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var definitions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/tile_defs.json"))
	var grid: Array = [[MazeGenerator.pack(15, 15), MazeGenerator.pack(19, 15)]]
	var subgrid := MapFormat.expand_cells_to_subgrid(grid)
	var solo := NativeTerrain.new()
	var server := NativeTerrain.new()
	var predicted := NativeTerrain.new()
	for terrain in [solo, server, predicted]:
		terrain.configure(grid, subgrid, definitions, {})
	server.set_authoritative(true)
	var old_grid := solo.get_grid_snapshot()
	assert(old_grid.is_read_only() and old_grid[0].is_read_only())
	# Inputs and exported snapshots must not become writable aliases of live data.
	grid[0][0] = 0
	subgrid[0][0] = 0
	assert(solo.value(Vector2i.ZERO) != 0 and solo.sub_texture(Vector2i.ZERO) == 15)
	assert(solo.sub_of(Vector2(-1, -1)) == Vector2i(7, 3), "negative coordinates wrap to the last subcell")
	var exported := solo.get_hp_snapshot()
	exported[0] = 999
	assert(solo.get_hp(Vector2i.ZERO) == 8)
	var center := Vector2(32, 32)
	for terrain in [solo, server]:
		terrain.damage_blast(center, 40.0, 30, 1)
	predicted.predict_blast(123, 5, center, 101, 40.0, 30)
	assert(solo.get_hp_snapshot() == server.get_hp_snapshot()
			and solo.get_hp_snapshot() == predicted.get_hp_snapshot(),
			"singleplayer, authority and prediction must share terrain damage semantics")
	assert(old_grid[0][0] != 0, "later writes cannot mutate an earlier grid snapshot")
	var patch := server.take_network_changes()
	assert(not patch.is_empty() and server.revision == patch.size())
	predicted.apply_authority({"tick": 101, "revision": server.revision, "cells": patch})
	predicted.acknowledge(101)
	assert(not predicted.needs_state and predicted.pending_cells().is_empty())
	assert(predicted.get_hp_snapshot() == server.get_hp_snapshot())
	assert(server.take_network_changes().is_empty())
	assert(int(server.take_rewards().get(1, 0)) > 0)
	solo.reset()
	var space := Node2D.new()
	add_child(space)
	solo.attach(space)
	var body := space.get_node("DestructibleChunk_0_0")
	var shape_id := body.get_child(0).get_instance_id()
	var revision := solo.get_geometry_revision()
	solo.invalidate_chunk(Vector2i.ZERO)
	solo.flush_collisions()
	assert(solo.get_geometry_revision() == revision and body.get_child(0).get_instance_id() == shape_id)
	solo.set_rewind_enabled(true)
	assert(solo.damage_impact(Vector2(8, 8), Vector2.UP, 2, 0) == 15)
	assert(solo.pending_rewind_count() == 1)
	solo.seal_rewind(1.0)
	assert(solo.get_hp(Vector2i.ZERO) == 6)
	solo.rewind_between(0.0, 1.0)
	assert(solo.get_hp(Vector2i.ZERO) == 8 and solo.get_geometry_revision() == revision)
	assert(solo.pending_rewind_count() == 0)
	solo.truncate_rewind(0.0)
	assert(solo.rewind_count() == 0)
	space.free()
	print("NATIVE TERRAIN PROBE OK ownership, immutable snapshots, shared damage, authority, shapes and history")
	get_tree().quit(0)
