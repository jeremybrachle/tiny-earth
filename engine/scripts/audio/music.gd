extends Node

# Looping ambient background music — Clair de Lune (Debussy), a public-domain
# Musopen/IMSLP recording (see ATTRIBUTION.md). Registered as an autoload so a
# single player persists across the menu → loading → world scene changes.
# Volume sits under gameplay so it stays atmospheric, never intrusive.
#
# Playback does NOT start automatically: the player triggers it via start() only
# once the world has finished building and is explorable (see World).

const TRACK     := "res://audio/clair_de_lune.mp3"
const VOLUME_DB := -14.0

var _player: AudioStreamPlayer = null


func _ready() -> void:
	var stream := load(TRACK) as AudioStream
	if stream == null:
		push_warning("Music: %s not found — skipping ambient track" % TRACK)
		return
	# Loop seamlessly. MP3/Vorbis streams expose `loop`; set it defensively.
	if "loop" in stream:
		stream.set("loop", true)

	_player = AudioStreamPlayer.new()
	_player.stream    = stream
	_player.volume_db = VOLUME_DB
	_player.bus       = "Master"
	add_child(_player)


# Begin the ambient track. Idempotent — safe to call repeatedly (e.g. if the
# world is rebuilt); won't restart a track that's already playing.
func start() -> void:
	if _player and not _player.playing:
		_player.play()


# Linear 0..1 volume for the Settings slider (mapped to/from dB). 0 mutes.
func get_volume_linear() -> float:
	return db_to_linear(_player.volume_db) if _player else db_to_linear(VOLUME_DB)


func set_volume_linear(v: float) -> void:
	if _player:
		_player.volume_db = linear_to_db(clampf(v, 0.0001, 1.0)) if v > 0.0 else -80.0


# Stop playback and release the stream + player. Called from World on a manual
# window close so the AudioStream resource is freed in order instead of lingering
# into Godot's exit teardown (part of silencing the "resources in use at exit"
# warning). Safe to call once; the player is detached and freed immediately.
func stop_and_free() -> void:
	if _player and is_instance_valid(_player):
		_player.stop()
		_player.stream = null
		_player.queue_free()
	_player = null
