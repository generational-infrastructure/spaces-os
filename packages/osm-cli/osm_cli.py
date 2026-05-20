#!/usr/bin/env python3
"""OpenStreetMap CLI - search, nearby, and route using free OSM APIs."""

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_NOMINATIM = "https://nominatim.openstreetmap.org"
BASE_OVERPASS = "https://overpass-api.de/api/interpreter"
BASE_OSRM = "https://router.project-osrm.org"
USER_AGENT = "distro-pi-chat"
_runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
LOCATION_FILE = f"{_runtime_dir}/distro/location.json"

# Maps common English terms to OSM key=value tags.
TAG_MAP = {
    "restaurant": ("amenity", "restaurant"),
    "cafe": ("amenity", "cafe"),
    "coffee": ("amenity", "cafe"),
    "pharmacy": ("amenity", "pharmacy"),
    "supermarket": ("shop", "supermarket"),
    "train station": ("railway", "station"),
    "bus stop": ("highway", "bus_stop"),
    "tram stop": ("railway", "tram_stop"),
    "hospital": ("amenity", "hospital"),
    "atm": ("amenity", "atm"),
    "fuel": ("amenity", "fuel"),
    "gas station": ("amenity", "fuel"),
    "hotel": ("tourism", "hotel"),
    "parking": ("amenity", "parking"),
    "bank": ("amenity", "bank"),
    "school": ("amenity", "school"),
    "university": ("amenity", "university"),
    "library": ("amenity", "library"),
    "post office": ("amenity", "post_office"),
    "police": ("amenity", "police"),
    "bakery": ("shop", "bakery"),
    "bar": ("amenity", "bar"),
    "pub": ("amenity", "pub"),
    "cinema": ("amenity", "cinema"),
    "theatre": ("amenity", "theatre"),
    "museum": ("tourism", "museum"),
    "park": ("leisure", "park"),
    "playground": ("leisure", "playground"),
    "dentist": ("amenity", "dentist"),
    "doctor": ("amenity", "doctors"),
    "gym": ("leisure", "fitness_centre"),
    "swimming pool": ("leisure", "swimming_pool"),
}

_last_nominatim = 0.0


def _request(url, data=None, timeout=15):
    """HTTP request with User-Agent header. Returns parsed JSON."""
    global _last_nominatim
    if BASE_NOMINATIM in url:
        elapsed = time.monotonic() - _last_nominatim
        if elapsed < 1.0:
            time.sleep(1.0 - elapsed)
        _last_nominatim = time.monotonic()

    headers = {"User-Agent": USER_AGENT}
    if data is not None:
        if isinstance(data, str):
            data = data.encode()
        req = urllib.request.Request(url, data=data, headers=headers)
    else:
        req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"Error: HTTP {e.code} from {url}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except TimeoutError:
        print(f"Error: request timed out ({timeout}s)", file=sys.stderr)
        sys.exit(1)


def _geocode(query):
    """Forward geocode a place name. Returns (lat, lon, display_name) or exits."""
    # Check if query is already lat,lon.
    parts = query.split(",")
    if len(parts) == 2:
        try:
            lat, lon = float(parts[0].strip()), float(parts[1].strip())
            return lat, lon, query
        except ValueError:
            pass

    params = urllib.parse.urlencode({"q": query, "format": "jsonv2", "limit": "1"})
    results = _request(f"{BASE_NOMINATIM}/search?{params}")
    if not results:
        print(f"Error: no results for '{query}'", file=sys.stderr)
        sys.exit(1)
    r = results[0]
    return float(r["lat"]), float(r["lon"]), r.get("display_name", query)


def _haversine(lat1, lon1, lat2, lon2):
    """Distance in meters between two points."""
    R = 6371000
    rlat1, rlat2 = math.radians(lat1), math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(rlat1) * math.cos(rlat2) * math.sin(dlon / 2) ** 2
    )
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _format_distance(meters):
    if meters < 1000:
        return f"{int(meters)}m"
    return f"{meters / 1000:.1f} km"


def _format_duration(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}min"
    h, m = divmod(seconds, 3600)
    m //= 60
    return f"{h}h {m}min" if m else f"{h}h"


def _read_location():
    """Read current location from the GeoClue file. Returns (lat, lon) or None."""
    try:
        with open(LOCATION_FILE) as f:
            data = json.load(f)
        return data["latitude"], data["longitude"]
    except (FileNotFoundError, KeyError, json.JSONDecodeError):
        return None


def _maneuver_text(step):
    """Build a human-readable instruction from an OSRM step."""
    maneuver = step.get("maneuver", {})
    mtype = maneuver.get("type", "")
    modifier = maneuver.get("modifier", "")
    name = step.get("name", "")

    if mtype == "depart":
        return f"Depart on {name}" if name else "Depart"
    if mtype == "arrive":
        return f"Arrive at {name}" if name else "Arrive at destination"
    if mtype == "turn":
        direction = modifier.replace("-", " ") if modifier else ""
        return f"Turn {direction} onto {name}" if name else f"Turn {direction}"
    if mtype in ("new name", "continue"):
        return f"Continue onto {name}" if name else "Continue"
    if mtype == "merge":
        return f"Merge onto {name}" if name else "Merge"
    if mtype in ("on ramp", "off ramp"):
        return f"Take ramp onto {name}" if name else "Take ramp"
    if mtype == "fork":
        direction = modifier.replace("-", " ") if modifier else ""
        return f"Keep {direction} onto {name}" if name else f"Keep {direction}"
    if mtype == "roundabout" or mtype == "rotary":
        exit_nr = maneuver.get("exit", "")
        base = f"Take exit {exit_nr} from roundabout" if exit_nr else "Enter roundabout"
        return f"{base} onto {name}" if name else base
    if mtype == "end of road":
        direction = modifier.replace("-", " ") if modifier else ""
        return (
            f"At end of road, turn {direction} onto {name}"
            if name
            else f"At end of road, turn {direction}"
        )

    # Fallback.
    parts = [mtype.replace("_", " ")]
    if modifier:
        parts.append(modifier.replace("-", " "))
    if name:
        parts.append(f"onto {name}")
    return " ".join(parts).strip().capitalize()


def cmd_search(args):
    """Search for a place by name."""
    params = urllib.parse.urlencode(
        {
            "q": args.query,
            "format": "jsonv2",
            "addressdetails": "1",
            "limit": str(args.limit),
        }
    )
    results = _request(f"{BASE_NOMINATIM}/search?{params}")
    if not results:
        print(f"No results for '{args.query}'")
        return

    for i, r in enumerate(results):
        if i > 0:
            print()
        print(f"Name: {r.get('name') or r.get('display_name', 'Unknown')}")
        print(f"Address: {r.get('display_name', '')}")
        print(f"Coordinates: {r['lat']}, {r['lon']}")
        if r.get("type"):
            print(f"Type: {r['type']}")


def cmd_nearby(args):
    """Find nearby points of interest."""
    if args.location:
        parts = args.location.split(",")
        try:
            lat, lon = float(parts[0].strip()), float(parts[1].strip())
        except (ValueError, IndexError):
            print("Error: --location must be LAT,LON", file=sys.stderr)
            sys.exit(1)
    else:
        loc = _read_location()
        if loc is None:
            print(
                "Error: no --location given and location file not found.\n"
                f"Provide --location LAT,LON or ensure {LOCATION_FILE} exists.",
                file=sys.stderr,
            )
            sys.exit(1)
        lat, lon = loc

    what = args.what.lower().strip()
    tag = TAG_MAP.get(what)

    if tag:
        key, value = tag
        filter_expr = f'["{key}"="{value}"]'
    else:
        # Fallback: search by name regex.
        escaped = what.replace('"', '\\"')
        filter_expr = f'["name"~"{escaped}",i]'

    query = (
        f"[out:json][timeout:10];\n"
        f"(\n"
        f"  node{filter_expr}(around:{args.radius},{lat},{lon});\n"
        f"  way{filter_expr}(around:{args.radius},{lat},{lon});\n"
        f");\n"
        f"out center body qt {args.limit};"
    )
    data = urllib.parse.urlencode({"data": query}).encode()
    result = _request(BASE_OVERPASS, data=data, timeout=20)
    elements = result.get("elements", [])

    if not elements:
        print(f"No results for '{args.what}' within {_format_distance(args.radius)}")
        return

    # Extract coords and sort by distance.
    items = []
    for el in elements:
        elat = el.get("lat") or el.get("center", {}).get("lat")
        elon = el.get("lon") or el.get("center", {}).get("lon")
        if elat is None or elon is None:
            continue
        dist = _haversine(lat, lon, elat, elon)
        tags = el.get("tags", {})
        name = tags.get("name", "")
        addr_parts = []
        for k in ("addr:street", "addr:housenumber"):
            if tags.get(k):
                addr_parts.append(tags[k])
        street = " ".join(addr_parts)
        city = tags.get("addr:city", "")
        address = ", ".join(filter(None, [street, city]))
        items.append((dist, name, address, elat, elon))

    items.sort(key=lambda x: x[0])

    for i, (dist, name, address, elat, elon) in enumerate(items):
        print(f"{i + 1}. {name or '(unnamed)'}")
        if address:
            print(f"   Address: {address}")
        print(f"   Coordinates: {elat:.6f}, {elon:.6f}")
        print(f"   Distance: {_format_distance(dist)}")
        if i < len(items) - 1:
            print()


def cmd_route(args):
    """Get driving directions between two places."""
    if args.mode != "driving":
        print("Note: only driving directions are available. Showing driving route.\n")

    lat1, lon1, name1 = _geocode(args.origin)
    lat2, lon2, name2 = _geocode(args.destination)

    # OSRM uses lon,lat order.
    url = (
        f"{BASE_OSRM}/route/v1/driving/{lon1},{lat1};{lon2},{lat2}"
        f"?overview=false&steps=true"
    )
    result = _request(url)

    if result.get("code") != "Ok" or not result.get("routes"):
        print("Error: no route found", file=sys.stderr)
        sys.exit(1)

    route = result["routes"][0]
    dist = route["distance"]
    dur = route["duration"]

    print(f"Route: {name1} → {name2}")
    print(f"Distance: {_format_distance(dist)}")
    print(f"Duration: {_format_duration(dur)}")

    steps = route.get("legs", [{}])[0].get("steps", [])
    if steps:
        print("\nSteps:")
        for i, step in enumerate(steps, 1):
            text = _maneuver_text(step)
            sdist = _format_distance(step.get("distance", 0))
            print(f"  {i}. {text} ({sdist})")


def main():
    parser = argparse.ArgumentParser(
        prog="osm-cli",
        description="Search, nearby, and route using OpenStreetMap",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # search
    p_search = sub.add_parser("search", help="Search for a place by name")
    p_search.add_argument("query", help="Place name or address")
    p_search.add_argument(
        "--limit", type=int, default=1, help="Number of results (default: 1)"
    )

    # nearby
    p_nearby = sub.add_parser("nearby", help="Find nearby points of interest")
    p_nearby.add_argument(
        "what", help="Type of place (e.g. restaurant, pharmacy, train station)"
    )
    p_nearby.add_argument(
        "--location", help="Center point as LAT,LON (default: current location)"
    )
    p_nearby.add_argument(
        "--radius",
        type=int,
        default=2000,
        help="Search radius in meters (default: 2000)",
    )
    p_nearby.add_argument(
        "--limit", type=int, default=5, help="Max results (default: 5)"
    )

    # route
    p_route = sub.add_parser("route", help="Get directions between two places")
    p_route.add_argument("origin", help="Start location (address or LAT,LON)")
    p_route.add_argument("destination", help="End location (address or LAT,LON)")
    p_route.add_argument(
        "--mode",
        default="driving",
        choices=["driving", "walking", "cycling", "transit"],
        help="Travel mode (default: driving). Note: only driving is available.",
    )

    args = parser.parse_args()
    if args.command == "search":
        cmd_search(args)
    elif args.command == "nearby":
        cmd_nearby(args)
    elif args.command == "route":
        cmd_route(args)


if __name__ == "__main__":
    main()
