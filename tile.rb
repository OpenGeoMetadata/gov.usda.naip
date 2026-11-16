# One NAIP tile as Planetary Computer's STAC API lists it: the image of one quarter quadrangle in one year, with its
# cloud-optimized GeoTIFF, its thumbnail and, from 2011 to 2019, its FGDC metadata.
#
# NAIP cuts its imagery by USGS's 7.5-minute quadrangles, each tile a quarter of one, and names the tile by a DOQQ
# code: m_4107129_nw is the north-west quarter of quadrangle 4107129. A quadrangle's first two digits are the
# latitude, and the next three the longitude west, of the south-east corner of a 1° block; its last two number the
# block's 64 quadrangles row by row, eight to a row, from the block's north-west corner. Each tile's image extends
# 300 pixels past its quarter quadrangle on every side, so neighboring tiles overlap.
class Tile
  STAC_URL = 'https://planetarycomputer.microsoft.com/api/stac/v1/collections/naip/items'

  # A quadrangle is an eighth of a degree square, and a quarter quadrangle a sixteenth
  QUADRANGLE = 0.125
  QUARTER = 0.0625

  # How far, in degrees, a quarter quadrangle may stand outside its tile's footprint before its code is taken to
  # place it wrongly: about 50 meters, where the buffer is 90 meters or more
  TOLERANCE = 0.0005

  # e.g. ri_m_4107129_nw_19_060_20180816_20181211: the state, the DOQQ code, the UTM zone, the resolution and the
  # date flown, then for some years the date processed. Arizona's 2025 ids write the quarter in capitals, e.g.
  # az_m_3411203_NE_12_060_20250526.
  ID = /\A[a-z]{2}_(m_(\d{7})_(ne|nw|se|sw))_/i

  # The snapshot's row for a STAC item: the fields the index maps use, and nothing else the item has
  def self.row(item)
    properties = item['properties'] || {}
    assets = item['assets'] || {}
    {
      'id' => item['id'], 'bbox' => item['bbox'], 'datetime' => properties['datetime'],
      'state' => properties['naip:state'], 'year' => year_of(properties), 'epsg' => epsg_of(properties),
      'image' => assets.dig('image', 'href'),
      'thumbnail' => assets.dig('thumbnail', 'href'), 'metadata' => assets.dig('metadata', 'href'),
      'modified' => item['_msft:ts']
    }.compact
  end

  # The item's NAIP year as a number. The items Planetary Computer added in November 2026, of 2024 and 2025, give it
  # as a string, the older ones as a number.
  def self.year_of(properties)
    year = properties['naip:year']
    year.nil? ? nil : Integer(year.to_s, 10)
  end

  # The item's EPSG code as a number: proj:epsg in the older items, and in the ones added in November 2026, which
  # follow version 2 of the projection extension, proj:code, e.g. EPSG:26919
  def self.epsg_of(properties)
    properties['proj:epsg'] || properties['proj:code'].to_s[/\AEPSG:(\d+)\z/, 1]&.to_i
  end

  attr_reader :row

  def initialize(row)
    @row = row
  end

  def id
    row['id']
  end

  def state
    row['state']
  end

  def year
    row['year']
  end

  # The day the tile was flown, e.g. 2018-08-16
  def date
    row['datetime'].to_s[0, 10]
  end

  def epsg
    row['epsg']
  end

  def image_url
    row['image']
  end

  def thumbnail_url
    row['thumbnail']
  end

  def fgdc_url
    row['metadata']
  end

  # When Planetary Computer last indexed the tile, to the second: 2026-10-17T15:36:33Z
  def modified
    row['modified'] && "#{row['modified'][0, 19]}Z"
  end

  # The tile's STAC item, as JSON: Planetary Computer has no web page for one
  def stac_url
    "#{STAC_URL}/#{id}"
  end

  # The DOQQ code, e.g. m_4107129_nw, in lower case whatever the id's case; nil when the id doesn't have one
  def code
    id.to_s[ID, 1]&.downcase
  end

  # The quadrangle the tile quarters, e.g. 4107129
  def quadrangle
    id.to_s[ID, 2]
  end

  # Which quarter of it, e.g. NW
  def quarter
    id.to_s[ID, 3]&.upcase
  end

  # [west, east, north, south] of the quarter quadrangle the code names; nil without a code
  def quarter_quadrangle
    return nil unless code

    latitude, longitude, number = quadrangle[0, 2].to_i, quadrangle[2, 3].to_i, quadrangle[5, 2].to_i
    row, column = (number - 1).divmod(8)
    west = -(longitude + 1) + (column * QUADRANGLE) + (quarter.end_with?('E') ? QUARTER : 0)
    north = latitude + 1 - (row * QUADRANGLE) - (quarter.start_with?('S') ? QUARTER : 0)
    [west, west + QUARTER, north, north - QUARTER]
  end

  # Whether the quarter quadrangle lies within the tile's footprint, as it does when the code was read rightly
  def aligned?
    box = quarter_quadrangle
    return false unless box && row['bbox']

    west, south, east, north = row['bbox']
    box[0] >= west - TOLERANCE && box[1] <= east + TOLERANCE && box[2] <= north + TOLERANCE &&
      box[3] >= south - TOLERANCE
  end

  # [west, east, north, south] of the tile's outline on an index map: its quarter quadrangle, without the buffer,
  # so that neighbors meet rather than overlap; or, when the code doesn't place it, its footprint's box
  def outline
    return quarter_quadrangle if aligned?

    west, south, east, north = row['bbox']
    [west, east, north, south]
  end
end
