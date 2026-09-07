#!/usr/bin/env python3
"""Regenerates the bundled song-fame database (fame.tsv) from chart history.

Source: https://github.com/utdata/rwd-billboard-data (MIT), file
data-out/hot-100-current.csv — weekly US singles-chart entries 1958-present.
The chart positions themselves are facts; keep chart brand names out of the
app UI and marketing regardless.

Usage:
  python3 native/tools/generate-fame-db.py [path/to/hot-100-current.csv]

Downloads the CSV when no path is given, then writes
native/SongSmashApp/Resources/fame.tsv with one row per unique song:

  titleNorm \t artistNorm \t peak \t weeks \t firstYear

titleNorm/artistNorm MUST stay byte-identical to FameDatabase.normalize*()
in native/SongSmashApp/Services/FameService.swift — the app looks songs up
by recomputing the same normalization on Apple catalog metadata.
"""
import csv
import io
import re
import sys
import unicodedata
import urllib.request
from pathlib import Path

SOURCE_URL = "https://raw.githubusercontent.com/utdata/rwd-billboard-data/main/data-out/hot-100-current.csv"
OUT = Path(__file__).resolve().parents[1] / "SongSmashApp" / "Resources" / "fame.tsv"

# Cut points mirror FameService.swift. Titles: parenthetical/bracket/dash
# suffixes ("(feat. X)", "- Single") name the same song. Artists: everything
# after the primary act. Both sides of a lookup apply the same cuts, so even
# an "over-cut" ("Earth, Wind & Fire" -> "earth") still matches itself.
TITLE_CUTS = [" (", " [", " - ", "/"]
ARTIST_CUTS = [" featuring ", " feat. ", " feat ", " ft. ", " ft ", " with ",
               " duet with ", " and ", " & ", ", ", " x ", " + "]


def fold(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return s.lower()


def strip_punct(s: str) -> str:
    s = s.replace("&", " and ")
    s = re.sub(r"[^a-z0-9 ]", "", s)
    return re.sub(r" +", " ", s).strip()


def cut_at_first(s: str, seps) -> str:
    idx = min((i for i in (s.find(sep) for sep in seps) if i > 0), default=-1)
    return s[:idx] if idx > 0 else s


def norm_title(s: str) -> str:
    return strip_punct(cut_at_first(fold(s), TITLE_CUTS))


def norm_artist(s: str) -> str:
    s = cut_at_first(fold(s), ARTIST_CUTS)
    if s.startswith("the "):
        s = s[4:]
    return strip_punct(s)


def main() -> None:
    if len(sys.argv) > 1:
        raw = Path(sys.argv[1]).read_text(encoding="utf-8")
    else:
        print(f"downloading {SOURCE_URL} ...")
        raw = urllib.request.urlopen(SOURCE_URL, timeout=120).read().decode("utf-8")

    songs = {}  # (titleNorm, artistNorm) -> [peak, weeks, firstYear]
    rows = 0
    for row in csv.DictReader(io.StringIO(raw)):
        rows += 1
        title = norm_title(row["title"])
        artist = norm_artist(row["performer"])
        if not title or not artist:
            continue
        try:
            peak = int(row["peak_pos"])
            weeks = int(row["wks_on_chart"])
            year = int(row["chart_week"][:4])
        except (KeyError, ValueError):
            continue
        rec = songs.setdefault((title, artist), [101, 0, 9999])
        rec[0] = min(rec[0], peak)
        rec[1] = max(rec[1], weeks)
        rec[2] = min(rec[2], year)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as f:
        f.write("# fame.tsv — titleNorm\tartistNorm\tpeak\tweeks\tfirstYear\n")
        f.write(f"# regenerate: python3 native/tools/generate-fame-db.py ({rows} weekly rows in)\n")
        for (title, artist), (peak, weeks, year) in sorted(songs.items()):
            f.write(f"{title}\t{artist}\t{peak}\t{weeks}\t{year}\n")

    top10 = sum(1 for v in songs.values() if v[0] <= 10)
    top40 = sum(1 for v in songs.values() if v[0] <= 40)
    size = OUT.stat().st_size
    print(f"{rows} weekly rows -> {len(songs)} unique songs "
          f"({top10} top-10, {top40} top-40) -> {OUT} ({size/1e6:.2f} MB)")


if __name__ == "__main__":
    main()
