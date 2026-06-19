class_name SpawnPoints

# Curated starting locations — one recognizable spot per continent, each chosen
# to sit well inside a landmass (spawn must never land in water — see the planet
# build notes). The main menu lets the player pick one before the world loads;
# the choice is carried here in a `static` var (survives the menu→world scene
# change without an autoload) and applied to the Player spawn in player.gd.
#
# Lat/lon are WGS84 degrees. Resolution at 256 makes each cell ~150 km, so these
# continental-interior points are comfortably on land. Index 0 is the historical
# default (central Kansas), so launching world.tscn directly is unchanged.

const LOCATIONS: Array[Dictionary] = [
	{"name": "Great Plains  ·  North America", "lat": 39.5, "lon": -98.5},
	{"name": "Amazon Basin  ·  South America", "lat": -3.5, "lon": -62.2},
	{"name": "Serengeti  ·  Africa", "lat": -2.3, "lon": 34.8},
	{"name": "The Alps  ·  Europe", "lat": 46.5, "lon": 9.8},
	{"name": "Himalayas  ·  Asia", "lat": 28.0, "lon": 86.9},
	{"name": "Outback  ·  Australia", "lat": -25.3, "lon": 131.0},
	{"name": "East Antarctica", "lat": -75.0, "lon": 45.0},
]

# Index into LOCATIONS chosen on the menu; carried across the scene change.
static var selected_index: int = 0


static func selected() -> Dictionary:
	return LOCATIONS[clampi(selected_index, 0, LOCATIONS.size() - 1)]
