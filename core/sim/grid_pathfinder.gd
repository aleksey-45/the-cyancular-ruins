class_name GridPathfinder
extends RefCounted

# 相邻子格始终按相同顺序加入候选列表，确保同等优先级的路径能稳定复现。
const DIRECTIONS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]

static func find_path(size: Vector2i, start: Vector2i, goal: Vector2i, can_pass: Callable,
		max_visit := 4000, radius := -1) -> Array[Vector2i]:
	if start == goal:
		return []
	# 按实际发现的子格保存代价和前驱。
	var cost: Dictionary[int, int] = {}
	var parent: Dictionary[int, int] = {}
	var origin := start.y * size.x + start.x
	cost[origin] = 0
	var nearest := origin
	var best := ToroidalGrid.toroidal_dist(start, goal, size.x, size.y)
	var frontier: Array[Vector2i] = [Vector2i(best, origin)]
	while not frontier.is_empty() and max_visit > 0:
		var entry := _pop(frontier)
		var index := entry.y
		var at := Vector2i(index % size.x, index / size.x)
		var distance := ToroidalGrid.toroidal_dist(at, goal, size.x, size.y)
		if entry.x > cost[index] + distance:
			continue
		max_visit -= 1
		if distance < best:
			best = distance
			nearest = index
		if at == goal:
			break
		var next_cost := cost[index] + 1
		for step: Vector2i in DIRECTIONS:
			var next := Vector2i(posmod(at.x + step.x, size.x), posmod(at.y + step.y, size.y))
			if radius > 0 and ToroidalGrid.toroidal_dist(start, next, size.x, size.y) > radius:
				continue
			var neighbor := next.y * size.x + next.x
			if cost.get(neighbor, 2147483647) <= next_cost or not can_pass.call(next):
				continue
			cost[neighbor] = next_cost
			parent[neighbor] = index
			_push(frontier, Vector2i(next_cost + ToroidalGrid.toroidal_dist(next, goal, size.x, size.y), neighbor))
	var path: Array[Vector2i] = []
	while nearest != origin:
		path.append(Vector2i(nearest % size.x, nearest / size.x))
		nearest = parent[nearest]
	path.reverse()
	return path

# 最小堆以 Vector2i.x 作为优先级，y 保存子格索引。
static func _push(heap: Array[Vector2i], entry: Vector2i) -> void:
	var i := heap.size()
	heap.append(entry)
	while i > 0:
		var parent := (i - 1) / 2
		if heap[parent].x <= entry.x:
			break
		heap[i] = heap[parent]
		i = parent
	heap[i] = entry

static func _pop(heap: Array[Vector2i]) -> Vector2i:
	var first := heap[0]
	var last: Vector2i = heap.pop_back()
	if heap.is_empty():
		return first
	var i := 0
	while i * 2 + 1 < heap.size():
		var child := i * 2 + 1
		if child + 1 < heap.size() and heap[child + 1].x < heap[child].x:
			child += 1
		if heap[child].x >= last.x:
			break
		heap[i] = heap[child]
		i = child
	heap[i] = last
	return first
