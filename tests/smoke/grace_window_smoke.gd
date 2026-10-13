extends Node

func _ready() -> void:
	var room := RoomSession.new()
	room.code = "00001234"
	room.seats = {
		1: {"peer": 0, "token": "host", "name": "Host", "hue": 0.0, "team": 0, "deadline": 0.0},
		2: {"peer": 0, "token": "guest", "name": "Guest", "hue": 0.0, "team": 0, "deadline": Time.get_ticks_msec() / 1000.0 + RoomSession.GRACE_SECONDS},
	}
	assert(RoomSession.GRACE_SECONDS == 60.0)
	room._process(0.0)
	assert(room.seats.has(2))
	room.seats[2]["deadline"] = maxf(0.001, Time.get_ticks_msec() / 1000.0 - 0.001)
	room._process(0.0)
	assert(room.seats.size() == 1 and room.host_role == 1 and room.code == "00001234")
	room.guests[123] = {"name": "New", "hue": 10.0}
	room.add_seat(123)
	assert(room.seats.has(2) and room.seats[2]["name"] == "New")
	room.seats[2]["peer"] = 0
	room.seats[1]["deadline"] = maxf(0.001, Time.get_ticks_msec() / 1000.0 - 0.001)
	room._process(0.0)
	assert(room.seats.is_empty() and room.code.is_empty())
	room.free()
	print("GRACE WINDOW SMOKE OK guest expiration, seat reuse, host closure")
	get_tree().quit()
