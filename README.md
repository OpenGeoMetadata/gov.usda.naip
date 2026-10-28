# gov.usda.naip

This repository contains [OpenGeoMetadata Aardvark](https://opengeometadata.org/ogm-aardvark/) records for the USDA's [National Agriculture Imagery Program](https://naip-usdaonline.hub.arcgis.com/) (NAIP): aerial imagery of the United States captured during the growing season, at least every three years for each state. There are four kinds of record:
- a [collection record](#collection-record) for NAIP as a whole, from USDA's ISO metadata;
- a record of USDA's [image service](#image-service) for the latest imagery of each state;
- a record of USDA's [image dates](#image-dates) for each state's imagery from each year since 2011, which show when each part of it was flown;
- an [index map](#index-maps) of each state's tiles for each year from 2010 to 2023, which are hosted by Microsoft's [Planetary Computer](https://planetarycomputer.microsoft.com/dataset/naip).

This repository is not an official USDA or Microsoft product.

This metadata is provided under the [CC0 v1.0 License](LICENSE), which allows for free use and redistribution without restrictions. NAIP's imagery is in the U.S. public domain, and USDA's Farm Production and Conservation Business Center asks to be credited in derived products.

## File Structure

```
metadata-aardvark/
  usda-naip.json                         the collection record
  usda-naip-latest.json                  the image service's record
  image-dates/
    usda-naip-dates-ri-2021.json         one record per layer of image dates, named by its id
    ...
  index-maps/
    usda-naip-index-ri-2018.json         one record per index map
    ...
index-maps/
  usda-naip-index-ri-2018.geojson        the index map itself
  ...
data/
  quadrangles.json                       the names of USGS's quadrangles, which label the index maps' sheets
  image-date-extents.json                the measured extents of the image dates' layers
withdrawn.json                           records that have left the repository
```

## Metadata

- **Version:** OGM Aardvark, with no custom fields.
- **Provider:** the index maps' `schema_provider_s` is `Microsoft Planetary Computer`, which hosts the tiles they outline and link to. Every other record's is `U.S. Department of Agriculture`.
- **Other formats:** the collection record links USDA's ISO 19115-2 metadata for NAIP. NAIP's FGDC for the tiles from 2011 to 2019 is linked from each tile's STAC item, which is in the OpenIndexMaps metadata for each tile.
- **Sources:** the image dates of a state's imagery from a year name the index map of the same imagery in `dct_source_sm`: they record when each of its tiles was flown. Only the image dates say so; a viewer finds what an index map is the source of from them.
- **Updates:** a GitHub Actions workflow rebuilds every record weekly. Files only change when what the sources say does, so unchanged sources produce no commit.
- **Validation:** the tests in `test/` run before every harvest.

### Sources

The harvester reads four things on each run, and saves what it fetched in `tmp/snapshot/`:
- **USDA's ISO metadata:** the [ISO 19115-2 record](https://geodata.nal.usda.gov/geonetwork/srv/api/records/e2442795-2136-424f-afd1-291397b51c3d/formatters/xml) the NAIP hub links to, in the National Agricultural Library's catalog.
- **USDA's image service:** the [description](https://apps.geo.fpac.usda.gov/geo-imagery/rest/services/naip/conus_naip/ImageServer) of its image service of the latest imagery, and one statistics query of its catalog of tiles: how many it has of each state and year, and when the last were added.
- **USDA's image dates:** the [DCAT feed](https://naip-image-dates-usdaonline.hub.arcgis.com/api/feed/dcat-us/1.1.json) of its NAIP image dates hub, with USDA's description of each layer, and a statistics query of each layer it lists: how many polygons were flown on each day, which says what years the layer covers. Layers new to `data/image-date-extents.json`, or modified since they were measured, are measured too; see [Image dates](#image-dates).
- **Planetary Computer's tile metadata:** its [STAC API](https://planetarycomputer.microsoft.com/api/stac/v1)'s `naip` items, one state or territory at a time, a page of 1,000 at a time, keeping only the fields the index maps use. Each item is the metadata for a tile: the image of one quarter quadrangle in one year. In October 2026 there were 1.44 million, in 326 states and years.

Nothing is downloaded but metadata: the tiles' images, thumbnails and FGDC stay on Planetary Computer's `naipeuwest` storage account, which serves them to anyone, with CORS, without a token.

### Collection record

`usda-naip` takes its title, and its description, the abstract and purpose, from USDA's ISO metadata. Its years run from 2002, when the ISO metadata says NAIP began, to its latest member's; its extent covers its members'. It carries the imagery's public-domain statement with USDA's request for credit, and the Public Domain Mark, and links to the NAIP hub, the ISO metadata, and a picture of the latest imagery drawn by the image service.

### Image service

`usda-naip-latest` is the record of USDA's [image service](https://apps.geo.fpac.usda.gov/geo-imagery/rest/services/naip/conus_naip/ImageServer) of the latest imagery of each state, which replaces a state's imagery when NAIP flies it again. In October 2026 that was 2025's of 31 states and 2024's of 14; the service has nothing of the other states, and doesn't offer its imagery for download. The record lists the states it has in `dct_spatial_sm` and their years in `gbl_indexYear_im`, and links the service as an ArcGIS image layer, which viewers can draw. The service has a twin, `conus_naip_cache`, which gets no record.

### Image dates

USDA's image dates hub has a hosted feature layer for each state's imagery from each year since 2016, and for 2011 and 2013 to 2015, with a polygon for each exposure the imagery was made from. Each polygon gives the day and time it was flown, the camera, and the aircraft. Each layer gets a record, e.g. `usda-naip-dates-ri-2021`; 332 in October 2026.

### Index maps

There is an [OpenIndexMaps](https://openindexmaps.org/specification/1.0.0) index map for each state's tiles from each year that Planetary Computer has, e.g. `usda-naip-index-ri-2018` for Rhode Island's in 2018. Each is a GeoJSON file of outlines, one sheet to a line, and has a record of its own.

Index maps are large; the median state-year's is 2.6 MB and Texas's are up to 12 MB, 960 MB in all.

| Aardvark field | Source | Notes |
|---|---|---|
| `id` | `naip:state`, `naip:year` | `usda-naip-index-ri-2018` |
| `dct_title_s` | `naip:state`, `naip:year` | `Index to NAIP Aerial Imagery of Rhode Island, 2018` |
| `dct_description_sm` | USDA's ISO metadata | The collection record's: USDA's abstract and purpose of NAIP |
| `dct_temporal_sm`, `gbl_indexYear_im`, `gbl_dateRange_drsim` | `naip:year`, `datetime` | NAIP's year, and the years flown, which can run into the next: Hawaii's 2021 tiles were flown in 2022 |
| `dct_spatial_sm` | `naip:state` | Named as gov.usgs.htmc names states |
| `locn_geometry`, `dcat_bbox` | the outlines | |
| `gbl_mdModified_dt` | `_msft:ts` | When Planetary Computer last indexed any of the tiles |
| `dct_references_s` | | The index map, as OpenIndexMaps and as a download, and Planetary Computer's page for NAIP |

The remaining fields are the same for every index map: `dct_creator_sm` and `dct_publisher_sm` are `United States. Farm Service Agency`; `gbl_resourceClass_sm` is `Maps` and `Imagery`; `gbl_resourceType_sm` is `Index maps` and `Aerial photographs`; `dct_format_s` is `GeoJSON`; `dct_rights_sm` dedicates the index map to the public domain, and says the imagery is in it; and `dct_license_sm` is CC0.

### Quadrangle names

A tile's name is only in its FGDC metadata, as a place keyword (`WICKFORD, NW`), and Planetary Computer has FGDC only for the tiles from 2011 to 2019. A quadrangle keeps its name from year to year, so each quadrangle's name is read once, from the FGDC of its latest tile that has one, and kept in `data/quadrangles.json`, where tiles from other years find it too. The harvester reads the FGDC of quadrangles new to the file as each state comes in. A quadrangle whose FGDC names nothing is kept as `null`, so it isn't read again.

USGS's names are capitals in the FGDC, and are title-cased: `Lake of the Woods`, `McAllen`, `Wilkes-Barre East`. The compass points that tell sheets of a name apart (`Fort Worth SW`) and ocean extensions' `OE` keep their capitals. A first run without `data/quadrangles.json` reads about 54,000 FGDC files, which takes about 20 minutes.

## Withdrawn Records

When a source stops listing something, its record leaves the repository: it's deleted, along with an index map's GeoJSON, and logged in `withdrawn.json` with the reason `upstream-removed`. Entries are only removed when the record comes back.

The harvester stops without changing anything when a source looks cut short:
- Planetary Computer lists no tiles at all, or none for a state that has index maps.
- The image dates hub lists no layers, while the repository has image dates.
- The run would remove more than 2% of the records.
- An index map would lose more than 2% of its sheets, and more than 10.

Set `FORCE=1` if the drop is real.

## Running the Harvester

The harvester needs Ruby 4.0 (`minitest` and `rexml` ship with it), and nothing else.

```bash
ruby harvester.rb
```

The harvester fetches USDA's sources and every state's tile metadata to `tmp/`, reads the names of any new quadrangles, rebuilds every record and index map, and prints what changed. It takes about half an hour, nearly all of it paging through Planetary Computer's STAC API; rebuilding from a snapshot takes about a minute. These environment variables change how it runs:

- `SOURCE=tmp/snapshot` rebuilds from a snapshot a run already fetched, offline. No names are read.
- `DRY_RUN=1` reports what would change without writing anything.
- `FORCE=1` allows a run that would withdraw more than 2% of the records, or shrink an index map by more than 2%.
- `INDEX_MAP_URL=http://localhost:8000/index-maps` changes where index map records say their GeoJSON is, to try them in a local GeoBlacklight before the files are on GitHub. Don't commit records written this way.

`ruby quadrangles.rb tmp/snapshot` reads the names of the quadrangles a snapshot has that `data/quadrangles.json` doesn't, without harvesting.

A first run without the files in `data/` takes much longer: reading every quadrangle's name takes about 20 minutes, and measuring every layer of image dates about 45, most of it waiting out the layers ArcGIS can't measure.

To run the tests:

```bash
for test in test/*_test.rb; do ruby "$test"; done
```

## How to Contribute

For problems with the records, open an issue in this repository. Every record is regenerated from its sources weekly, so edits to the files would be overwritten:
- **How fields are mapped:** change `mapper.rb`, or `index_map.rb` for the index maps' sheets.
- **A quadrangle's name:** correct it in `data/quadrangles.json`. The harvester never reads a name it already has again.
- **The sources themselves:** corrections have to be made by USDA or Microsoft.
