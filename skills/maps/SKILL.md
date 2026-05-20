---
name: Maps and Places
description: Search places, find nearby POIs, and get driving directions using OpenStreetMap
---

Use `osm-cli` to search for places, find nearby points of interest, and get driving directions.

### Search for a place

```bash
osm-cli search "Marienplatz, Munich"
osm-cli search "Berlin" --limit 3
```

Returns name, address, coordinates, and type.

### Find nearby places

```bash
osm-cli nearby "restaurant" --limit 5
osm-cli nearby "train station"
osm-cli nearby "Starbucks" --location 48.137,11.575 --radius 5000
```

Automatically uses your current location from the location skill.
Override with `--location LAT,LON`. Adjust search radius with `--radius` (meters, default 2000).

Common search terms: restaurant, cafe, pharmacy, supermarket, train station,
bus stop, hospital, atm, fuel, hotel, parking, bank, bakery, bar, pub,
cinema, museum, park, dentist, doctor, gym.

You can also search by name (e.g. `osm-cli nearby "Starbucks"`).

### Get directions

```bash
osm-cli route "Munich" "Berlin"
```

Shows distance, duration, and step-by-step driving directions.
Only driving directions are available.

### Tips

- The `nearby` command reads `$XDG_RUNTIME_DIR/distro/location.json` automatically when no `--location` is given.
- For travel planning, chain: `osm-cli nearby "train station"` → `db-cli` for train connections.
- Use `osm-cli search` to geocode a place name into coordinates for other tools.
