extends "res://tests/case.gd"

func run(tree: SceneTree) -> void:
	world(tree)
	var terrain := TileDefs.terrain
	var sub := Vector2i(8, 12)
	var original := terrain.get_hp(sub)
	var geometry := terrain.get_geometry_revision()
	terrain.apply_hp(sub, original - 1, 1)
	expect(terrain.get_hp(sub) == original - 1, "partial terrain damage preserves exact HP")
	expect(terrain.get_geometry_revision() == geometry and terrain.flush_collisions() == 0, "HP-only damage does not rebuild geometry")
	terrain.set_rewind_enabled(true)
	terrain.seal_rewind(0.0)
	terrain.apply_hp(sub, 0, 1)
	terrain.seal_rewind(1.0)
	expect(terrain.flush_collisions() > 0, "destroyed terrain commits collision changes")
	expect(terrain.affects_since(geometry, Rect2(120, 184, 32, 32)), "destroyed subcell invalidates intersecting queries")
	expect(not terrain.affects_since(geometry, Rect2(300, 50, 16, 16)), "unrelated query area remains valid")
	terrain.rewind_between(0.0, 1.0)
	expect(terrain.get_hp(sub) == original - 1, "rewind restores residual HP, not full health")
	terrain.reset()
	terrain.reset_prediction(100)
	var generation := terrain.generation
	terrain.predict_blast(1, WeaponRegistry.all_ids()[0], Vector2(136, 200), 101, 8.0, original)
	var damaged := terrain.get_hp(sub)
	expect(damaged < original, "predicted blast changes terrain")
	expect(terrain.can_restore(100, generation), "prediction checkpoint is restorable")
	terrain.restore_checkpoint(100)
	expect(terrain.get_hp(sub) == original, "prediction restore recovers exact terrain")
	terrain.predict_blast(1, WeaponRegistry.all_ids()[0], Vector2(136, 200), 101, 8.0, original)
	expect(terrain.get_hp(sub) == damaged, "repeated blast after restore gives the same damage")
	terrain.apply_authority({"tick": 101, "revision": 1, "cells": {sub: damaged}})
	expect(terrain.difference(101, generation, 1).is_empty(), "matching authority confirms predicted terrain")
	_map_format()

func _map_format() -> void:
	var info := MapFormat.load_map_info("res://maps/newfactory.cyrm", true)
	expect(not info["grid"].is_empty() and not info["subgrid"].is_empty(), "shipped v4 map loads macro and subgrid together")
	var body := PackedByteArray([0, 0, 1, 1, 0, 0, 16, 0, 0, 1])
	body.resize(26)
	var bytes := _map_bytes(body)
	expect(MapFormatV4.parse(bytes)["ok"], "minimal valid v4 scene")
	for size in [3, 4, 8, 9, 10, 25]:
		expect(not MapFormatV4.parse(_map_bytes(body.slice(0, size)))["ok"], "truncated v4 block is rejected, length %d" % size)
	var invalid := body.duplicate()
	invalid[9] = 3
	expect(not MapFormatV4.parse(_map_bytes(invalid))["ok"], "invalid palette index width is rejected")
	invalid = body.duplicate()
	invalid[10] = 1
	expect(not MapFormatV4.parse(_map_bytes(invalid))["ok"], "out-of-range palette index is rejected")
	bytes[10] ^= 1
	expect(not MapFormatV4.parse(bytes)["ok"], "v4 CRC mismatch is rejected")

func _map_bytes(body: PackedByteArray) -> PackedByteArray:
	var bytes := PackedByteArray([67, 89, 82, 77, 4, 0])
	bytes.resize(20)
	bytes.encode_u32(6, body.size())
	bytes.encode_u32(10, MapFormatV4.crc32(body))
	bytes.encode_u16(14, 4)
	bytes.encode_u16(16, 4)
	bytes[18] = 2
	bytes.append_array(body)
	return bytes
