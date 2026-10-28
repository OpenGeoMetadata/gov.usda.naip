# Test fixtures

`snapshot/` is a real snapshot, cut down from a full run's `tmp/snapshot/` on 2026-10-27.

Planetary Computer's tiles of four states, chosen for the cases they exercise:

| State | Tiles |
|---|---|
| Rhode Island | 2018: Franklin SW and SE, and Kingston OE S NE and NW, an ocean extension, all with FGDC. 2021: Franklin SW and Kingston OE S NE, without FGDC. |
| New York | 2022: Harrison Valley NE and NW, each flown twice, in May and November |
| Iowa | 2023: m_4009510_nw, listed twice from one flight, processed on 2023-12-01 and 2024-01-04 |
| Hawaii | 2021: m_1915522_ne and nw, flown in 2022, in a year without FGDC |

USDA's sources:
- `image-dates.jsonl`: seven layers of image dates, each with USDA's description, its statistics and its measured extent. Rhode Island 2018 and 2021, New York 2022 and Hawaii 2021 have index maps among the tiles; Puerto Rico and the Virgin Islands 2021 doesn't. Wisconsin 2024 is one of the three USDA gave no description, and one ArcGIS couldn't measure. 2012's layer of every state is cut down to Rhode Island's and Connecticut's polygons, and couldn't be measured either.
- `image-service.jsonl`: the image service, with the statistics of its whole catalog.

The files are plain JSON lines, which the harvester reads like a full snapshot's gzipped ones. The tiles are in `naip-{state}.jsonl`, one tile to a line, as `Tile.row` keeps them.

The other fixtures:
- `item.json`: the whole STAC item of Rhode Island's 2018 Franklin SW tile, as the API answered it.
- `fgdc/`: the FGDC metadata of Rhode Island's 2018 Franklin SW and Kingston OE S NE tiles.
- `quadrangles.json`: the names of the fixture's quadrangles that have FGDC in some year, as `Quadrangles#fill` read them on 2026-10-27. Hawaii's has no FGDC in any year, and Iowa's is left out, as if it had none.
- `iso.xml`: USDA's ISO 19115-2 record for NAIP. The harvester test writes it into each snapshot it makes, as `iso.jsonl`.
- `image-dates-feed.json`: USDA's image dates feed, cut down to eight datasets: Rhode Island 2018 and 2021; Alabama 2013, a layer of a multi-layer service; that service itself; New Jersey 2022, a Box folder; West Virginia 2018; Puerto Rico and the Virgin Islands 2021; and 2012's layer of every state.
