class_name LocalMotion
extends RefCounted

const CORRECTION_TIME := 0.05

var from: Vector2
var _error: Vector2
var _left := 0.0
var _offset: Vector2

func correct(body: Transform2D, previous: Vector2, size: Vector2, snap: bool) -> void:
	var at := body.origin
	_error = Vector2.ZERO if snap else GridPathfinder.toroidal_delta_px(at, previous, size)
	_left = 0.0 if snap else CORRECTION_TIME
	if snap:
		from = at
	_offset = body.affine_inverse() * (at + _error)

func shown(body: Transform2D) -> Vector2:
	return body * _offset

func corrected(at: Vector2) -> Vector2:
	return at + _error * (_left / CORRECTION_TIME)

func rebase(at: Vector2, previous: Vector2, size: Vector2) -> void:
	from = at - GridPathfinder.toroidal_delta_px(from, previous, size)

func advance(delta: float, relative_tick: float, body: Transform2D, size: Vector2) -> Vector2:
	_left = maxf(0.0, _left - delta)
	var at := body.origin
	var movement := GridPathfinder.toroidal_delta_px(from, at, size)
	var at_render := corrected(at) + movement * clampf(relative_tick, -1.0, 1.0)
	_offset = body.affine_inverse() * at_render
	return shown(body)
