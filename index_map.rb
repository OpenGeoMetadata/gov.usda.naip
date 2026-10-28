require 'json'
require_relative 'extent'
require_relative 'mapper'
require_relative 'tile'

# One index map: a state's NAIP tiles from one year, as OpenIndexMaps GeoJSON
# (https://openindexmaps.org/specification/1.0.0), and the record that points to it. Each tile is outlined by its
# quarter quadrangle, so that the outlines tile the state without overlapping, as the images' buffers do.
class IndexMap
  # One index map for each year of a state's tiles
  # @param tiles [Array<Tile>] one state's tiles
  def self.build(tiles)
    tiles.group_by(&:year).sort.map { |year, members| new(members.first.state, year, members) }
  end

  attr_reader :state, :year, :tiles, :twins

  def initialize(state, year, tiles)
    @state = state
    @year = year
    # A quarter quadrangle's image from one flight is sometimes listed twice, processed on two dates, and only the
    # later processing is kept, whose id ends in the later date
    kept = tiles.group_by { |tile| [tile.code || tile.id, tile.date] }.values.map { |twins| twins.max_by(&:id) }
    @twins = tiles.size - kept.size
    # By quarter quadrangle, and a quarter quadrangle flown twice oldest first, so viewers draw the latest on top
    @tiles = kept.sort_by { |tile| [tile.code.to_s, tile.date, tile.id] }
  end

  def id
    Mapper.index_map_id(state, year)
  end

  def sheets
    tiles.size
  end

  # The tiles whose code doesn't place them within their footprint, which are outlined by the footprint instead
  def misaligned
    tiles.reject(&:aligned?)
  end

  # The GeoJSON, one sheet to a line so that a change to one tile changes one line
  # @param quadrangles [Quadrangles] the names the sheets are labeled with
  def geojson(quadrangles)
    lines = tiles.map { |tile| JSON.generate(feature(tile, quadrangles)) }
    "{\"type\":\"FeatureCollection\",\"features\":[\n#{lines.join(",\n")}\n]}\n"
  end

  # The sheet's label: its quadrangle's name and its quarter, e.g. Wickford NW, or its code where the name isn't
  # known
  def label(tile, quadrangles)
    name = tile.quadrangle && quadrangles.name(tile.quadrangle)
    name ? "#{name} #{tile.quarter}" : tile.code || tile.id
  end

  # [west, east, north, south] covering the outlines
  def bounds
    extent = Extent.new
    tiles.each { |tile| extent.add(*tile.outline) }
    [*extent.longitudes, extent.north, extent.south]
  end

  # The first and last days the tiles were flown
  def dates
    tiles.map(&:date).minmax
  end

  # NAIP's year, and the years the tiles were flown, which can run into the next
  def years
    ([year] + dates.map { |date| date[0, 4].to_i }).minmax
  end

  # When Planetary Computer last indexed any of the tiles
  def modified
    tiles.filter_map(&:modified).max
  end

  # @param url [String] where the GeoJSON is published
  # @param bytes [Integer] the GeoJSON's size
  # @param description [Array<String>] the collection's description
  def record(url, bytes, description:)
    Mapper.index_map(self, url: url, bytes: bytes, description: description)
  end

  private

  # The tile as a sheet: its outline, and what a viewer shows of it. The code is the sheet's alternative label
  # where its label is a name.
  def feature(tile, quadrangles)
    label = label(tile, quadrangles)
    west, east, north, south = tile.outline.map { |value| Mapper.coordinate(value) }
    {
      'type' => 'Feature',
      'properties' => Mapper.compact(
        'label' => label,
        'labelAlt' => (tile.code unless tile.code == label),
        'date' => tile.date,
        'projection' => tile.epsg && "EPSG:#{tile.epsg}",
        'available' => true,
        'websiteUrl' => tile.stac_url,
        'download' => tile.image_url,
        'thumbUrl' => tile.thumbnail_url
      ),
      # Counterclockwise and closed, as GeoJSON wants an outer ring
      'geometry' => {
        'type' => 'Polygon',
        'coordinates' => [[[west, south], [east, south], [east, north], [west, north], [west, south]]]
      }
    }
  end
end
