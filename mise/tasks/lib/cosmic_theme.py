#!/usr/bin/env python3
"""COSMIC theme helper: search and download themes from cosmic-themes.org.

Commands:
  search <name>              Search for themes, output pipe-delimited lines: name|downloads
  download <name> <outfile>  Download exact-match theme .ron to file
"""

import json
import sys
import urllib.parse
import urllib.request

THEMES_API = "https://cosmic-themes.org/api/themes"


# ─── API interaction ────────────────────────────────────────────────────────


def api_search(name: str, limit: int = 20) -> list[dict]:
    """Search cosmic-themes.org API. Returns list of theme dicts."""
    encoded = urllib.parse.quote(name)
    url = f"{THEMES_API}?search={encoded}&limit={limit}"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"ERROR: API request failed: {e}", file=sys.stderr)
        sys.exit(1)


# ─── Commands ────────────────────────────────────────────────────────────────


def cmd_search(name: str) -> None:
    """Search and output results as pipe-delimited lines: name|downloads."""
    results = api_search(name)
    if not results:
        sys.exit(1)
    for theme in results:
        print(f"{theme['name']}|{theme['downloads']}")


def cmd_download(name: str, outfile: str) -> None:
    """Download a theme by name (exact match first, then first result)."""
    results = api_search(name)
    if not results:
        sys.exit(3)  # no results found (distinct from exit 1 = API error)

    # Try exact match (case-insensitive)
    match = None
    for theme in results:
        if theme["name"].lower() == name.lower():
            match = theme
            break

    if match is None:
        # No exact match — output available names and exit with code 2
        for theme in results:
            print(f"{theme['name']}|{theme['downloads']}")
        sys.exit(2)

    # Write .ron content to file
    with open(outfile, "w") as f:
        f.write(match["ron"])

    print(f"NAME={match['name']}")
    print(f"DOWNLOADS={match['downloads']}")


# ─── Main ────────────────────────────────────────────────────────────────────


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <search|download> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "search" and len(sys.argv) == 3:
        cmd_search(sys.argv[2])
    elif cmd == "download" and len(sys.argv) == 4:
        cmd_download(sys.argv[2], sys.argv[3])
    else:
        print(f"Usage: {sys.argv[0]} <search|download> [args...]", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
