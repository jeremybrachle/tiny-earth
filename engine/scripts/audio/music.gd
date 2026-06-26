extends Node

# Background-music playlist. Registered as an autoload so a single player persists
# across the menu → loading → world scene changes, cycling a list of public-domain
# classical recordings (Musopen/IMSLP — see ATTRIBUTION.md). Volume sits under
# gameplay so it stays atmospheric, never intrusive.
#
# Playback model:
#   - start() begins the playlist (called from the title screen so music plays from
#     the menu onward). Idempotent — World also calls it post-build; the second call
#     is a no-op while a track is already playing.
#   - Each track plays once (loop disabled) and auto-advances to the next on `finished`,
#     wrapping at the end — a continuous, non-repeating cycle.
#   - next()/prev()/play_index() let the menu list and the in-game [ / ] keys change
#     tracks. track_changed(index, title) lets any UI reflect the current selection.

# Playlist. clair_de_lune leads (the original ambient track) followed by the wider
# classical set. Titles are what the Settings → Audio list shows.
const TRACKS := [
	{"title": "Clair de Lune — Debussy", "path": "res://audio/clair_de_lune.mp3"},
	{"title": "Gymnopédie No. 1 — Satie", "path": "res://audio/gymnopedie_no1.mp3"},
	{"title": "Nocturne Op. 9 No. 2 — Chopin", "path": "res://audio/nocturne_op9_no2.mp3"},
	{"title": "Morning Mood (Peer Gynt) — Grieg", "path": "res://audio/peer_gynt_morning_mood.mp3"},
	{"title": "Boléro — Ravel", "path": "res://audio/bolero.ogg"},
	{"title": "Polovtsian Dances — Borodin", "path": "res://audio/borodin_polovtsian_dances.ogg"},
	{"title": "Symphony No. 5, IV. Adagietto — Mahler", "path": "res://audio/mahler_5_iv.ogg"},
]

const VOLUME_DB := -14.0
# Extra attenuation applied while the game is paused (pause-menu ducking). ~5 dB is a
# clearly audible drop without silencing the track. The music keeps playing under the
# menu (see PROCESS_MODE_ALWAYS below).
const DUCK_DB := -5.0

# Emitted whenever the playing track changes (start / auto-advance / manual switch),
# so the Settings list and any HUD can sync. Args: playlist index, display title.
signal track_changed(index: int, title: String)

var _player: AudioStreamPlayer = null
var _base_db := VOLUME_DB  # slider-set level, before any pause ducking
var _ducked := false
var _index := 0
var _started := false
# Shuffle: when on, auto-advance and Next pick a random OTHER track instead of the
# next in order. The first track is still deterministic (start() plays index 0, the
# Clair de Lune intro); only the rotation after it randomizes. Toggled in Settings → Audio.
var _shuffle := true


func _ready() -> void:
	# Keep playing while get_tree().paused is true — autoloads otherwise pause with the
	# tree, cutting the music the moment the pause menu opens.
	process_mode = Node.PROCESS_MODE_ALWAYS
	randomize()  # so shuffle isn't the same order every launch

	_player = AudioStreamPlayer.new()
	_player.volume_db = VOLUME_DB
	_player.bus = "Master"
	# Auto-advance: a non-looping stream emits `finished` at its end; we step to the next.
	_player.finished.connect(_on_track_finished)
	add_child(_player)


# Begin the playlist. Idempotent — safe to call repeatedly (title screen + World
# post-build both call it); won't interrupt a track that's already playing.
func start() -> void:
	if _started and _player and _player.playing:
		return
	_started = true
	_play_index(_index)


# Load + play the track at `idx` (wrapped into range). Disables looping on the stream
# so it ends and `finished` fires to auto-advance.
func _play_index(idx: int) -> void:
	if _player == null or TRACKS.is_empty():
		return
	_index = wrapi(idx, 0, TRACKS.size())
	var path: String = TRACKS[_index]["path"]
	var stream := _load_stream(path)
	if stream == null:
		push_warning("Music: %s could not be loaded — skipping" % path)
		return
	# Each track plays once; the playlist (not the stream) provides the looping.
	if "loop" in stream:
		stream.set("loop", false)
	_player.stream = stream
	_player.play()
	track_changed.emit(_index, TRACKS[_index]["title"])


# Load a track's AudioStream. Prefers the imported resource when one exists, but
# falls back to reading the raw .mp3/.ogg at runtime (AudioStream*.load_from_file)
# so newly-added tracks play even when the editor hasn't imported them yet — which
# is exactly the case that produced the "No loader found / expected type: unknown"
# errors. ResourceLoader.exists() is checked first so we never call load() on an
# un-imported path (that's what printed the scary error to the console).
func _load_stream(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		var imported := load(path) as AudioStream
		if imported != null:
			return imported
	if not FileAccess.file_exists(path):
		return null
	match path.get_extension().to_lower():
		"mp3":
			return AudioStreamMP3.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
	return null


# A random track index other than the one playing (for shuffle). Falls back to the
# current index when there's only one track.
func _random_other_index() -> int:
	if TRACKS.size() <= 1:
		return _index
	var idx := _index
	while idx == _index:
		idx = randi() % TRACKS.size()
	return idx


func _on_track_finished() -> void:
	# Only auto-advance once the playlist has been started (the signal can also fire
	# from a manual stop in stop_and_free, where _player is being torn down).
	if _started:
		_play_index(_random_other_index() if _shuffle else _index + 1)


# --- Track navigation (Settings list + in-game [ / ] keys) -----------------
func next() -> void:
	_started = true
	_play_index(_random_other_index() if _shuffle else _index + 1)


# Prev always steps sequentially (shuffle has no well-defined "previous").
func prev() -> void:
	_started = true
	_play_index(_index - 1)


func set_shuffle(on: bool) -> void:
	_shuffle = on


func get_shuffle() -> bool:
	return _shuffle


# Jump to an explicit playlist entry (Settings → Audio track list).
func play_index(idx: int) -> void:
	_started = true
	_play_index(idx)


func get_track_titles() -> Array:
	var titles: Array = []
	for t in TRACKS:
		titles.append(t["title"])
	return titles


func get_current_index() -> int:
	return _index


# --- Volume ----------------------------------------------------------------
# Linear 0..1 volume for the Settings slider (mapped to/from dB). 0 mutes. Reports the
# slider-set base level, not the transient paused-duck level.
func get_volume_linear() -> float:
	return db_to_linear(_base_db)


func set_volume_linear(v: float) -> void:
	_base_db = linear_to_db(clampf(v, 0.0001, 1.0)) if v > 0.0 else -80.0
	_apply_volume()


# Duck (pause menu open) / restore the music. Composes with the slider level.
func set_paused_duck(ducked: bool) -> void:
	_ducked = ducked
	_apply_volume()


func _apply_volume() -> void:
	if _player:
		_player.volume_db = _base_db + (DUCK_DB if _ducked else 0.0)


# Stop playback and release the player. Called from World on a manual window close so
# the AudioStream resource is freed in order instead of lingering into Godot's exit
# teardown (part of silencing the "resources in use at exit" warning).
func stop_and_free() -> void:
	_started = false  # so the `finished` from stop() doesn't try to auto-advance
	if _player and is_instance_valid(_player):
		_player.stop()
		_player.stream = null
		_player.queue_free()
	_player = null
