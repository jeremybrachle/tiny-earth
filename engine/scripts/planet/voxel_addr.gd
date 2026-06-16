class_name VoxelAddr

var face: int = 0
var shell: int = 0
var chunk_u: int = 0
var chunk_v: int = 0
var local_u: int = 0
var local_v: int = 0
var local_r: int = 0

func _init(
	p_face: int = 0,
	p_shell: int = 0,
	p_chunk_u: int = 0,
	p_chunk_v: int = 0,
	p_local_u: int = 0,
	p_local_v: int = 0,
	p_local_r: int = 0
) -> void:
	face = p_face
	shell = p_shell
	chunk_u = p_chunk_u
	chunk_v = p_chunk_v
	local_u = p_local_u
	local_v = p_local_v
	local_r = p_local_r

func _to_string() -> String:
	return "VoxelAddr(f:%d,s:%d,cu:%d,cv:%d,lu:%d,lv:%d,lr:%d)" % [
		face, shell, chunk_u, chunk_v, local_u, local_v, local_r
	]

func equals(other: VoxelAddr) -> bool:
	return (
		face == other.face and
		shell == other.shell and
		chunk_u == other.chunk_u and
		chunk_v == other.chunk_v and
		local_u == other.local_u and
		local_v == other.local_v and
		local_r == other.local_r
	)

static func from_face_col_row(
	p_face: int,
	p_shell: int,
	col: int,
	row: int,
	depth: int,
	chunk_size: int
) -> VoxelAddr:
	var chunk_u := col / chunk_size
	var chunk_v := row / chunk_size
	var local_u := col % chunk_size
	var local_v := row % chunk_size
	var local_r := depth
	return VoxelAddr.new(p_face, p_shell, chunk_u, chunk_v, local_u, local_v, local_r)

func to_col_row_depth(chunk_size: int) -> Vector3i:
	var col := chunk_u * chunk_size + local_u
	var row := chunk_v * chunk_size + local_v
	var depth := local_r
	return Vector3i(col, row, depth)
