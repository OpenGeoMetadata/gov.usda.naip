require 'minitest/autorun'
require 'json'
require_relative '../index_map'
require_relative '../tile'

class TileTest < Minitest::Test
  ITEM = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'item.json')))
  # The same quarter quadrangle in 2025, from the items Planetary Computer added in November 2026
  ITEM_2025 = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'item-2025.json')))

  def tile(id, bbox = [-180, -90, 180, 90])
    Tile.new('id' => id, 'bbox' => bbox, 'datetime' => '2018-09-30T00:00:00Z', 'year' => 2018)
  end

  def test_a_snapshot_row_keeps_only_what_the_index_maps_use
    base = 'https://naipeuwest.blob.core.windows.net/naip/v002/ri/2018'

    assert_equal(
      { 'id' => 'ri_m_4207161_sw_19_060_20180930_20181211', 'bbox' => [-71.506181, 41.995875, -71.431389, 42.066626],
        'datetime' => '2018-09-30T00:00:00Z', 'state' => 'ri', 'year' => 2018, 'epsg' => 26_919,
        'image' => "#{base}/ri_060cm_2018/42071/m_4207161_sw_19_060_20180930.tif",
        'thumbnail' => "#{base}/ri_060cm_2018/42071/m_4207161_sw_19_060_20180930.200.jpg",
        'metadata' => "#{base}/ri_fgdc_2018/42071/m_4207161_sw_19_060_20180930.txt",
        'modified' => '2026-10-17T15:36:33.337159Z' },
      Tile.row(ITEM)
    )
  end

  # The items added in November 2026 give their year as a string and their projection as proj:code, which the row
  # reads as the older items' numbers
  def test_a_2025_items_year_and_projection_are_read_as_numbers
    base = 'https://naipeuwest.blob.core.windows.net/naip/v002/ri/2025/ri_060cm_2025/42071'

    assert_equal ['2025', 'EPSG:26919'], ITEM_2025['properties'].values_at('naip:year', 'proj:code')
    assert_equal(
      { 'id' => 'ri_m_4207161_sw_19_060_20250802', 'bbox' => ITEM_2025['bbox'],
        'datetime' => '2025-08-02T16:00:00.000000Z', 'state' => 'ri', 'year' => 2025, 'epsg' => 26_919,
        'image' => "#{base}/m_4207161_sw_19_060_20250802.tif",
        'thumbnail' => "#{base}/m_4207161_sw_19_060_20250802.200.jpg", 'modified' => '2026-11-12T02:58:50.207994Z' },
      Tile.row(ITEM_2025)
    )
  end

  # Index maps are grouped and sorted by year, which a state mixing the two kinds of year would break
  def test_old_and_new_items_years_sort_together
    tiles = [ITEM_2025, ITEM].map { |item| Tile.new(Tile.row(item)) }

    assert_equal [2018, 2025], IndexMap.build(tiles).map(&:year)
  end

  def test_a_quarter_in_capitals_is_read_like_one_in_lower_case
    tile = tile('az_m_3411203_NE_12_060_20250526', [-112.688917, 34.936543, -112.623633, 35.000962])

    assert_equal 'm_3411203_ne', tile.code
    assert_equal '3411203', tile.quadrangle
    assert_equal 'NE', tile.quarter
    assert tile.aligned?
    assert_equal [-112.6875, -112.625, 35, 34.9375], tile.outline
  end

  def test_an_unreadable_year_or_projection_is_refused_or_left_out
    assert_raises(ArgumentError) { Tile.year_of('naip:year' => '20x5') }
    assert_nil Tile.year_of({})
    assert_nil Tile.epsg_of('proj:code' => 'IAU_2015:30100')
    assert_nil Tile.epsg_of({})
  end

  def test_the_code_names_the_quadrangle_and_quarter
    tile = Tile.new(Tile.row(ITEM))

    assert_equal 'm_4207161_sw', tile.code
    assert_equal '4207161', tile.quadrangle
    assert_equal 'SW', tile.quarter
    assert_equal '2018-09-30', tile.date
    assert_equal '2026-10-17T15:36:33Z', tile.modified
    assert_equal 'https://planetarycomputer.microsoft.com/api/stac/v1/collections/naip/items/' \
                 'ri_m_4207161_sw_19_060_20180930_20181211', tile.stac_url
  end

  # Quadrangle 57 is the first of the block's eighth and last row, so its south-west quarter is in the block's
  # south-west corner, and quadrangle 08 is the last of the first row, in the north-east corner
  def test_a_quarter_quadrangle_is_placed_from_its_code
    assert_equal [-72, -71.9375, 41.0625, 41], tile('ri_m_4107157_sw_19_060_20180930').quarter_quadrangle
    assert_equal [-71.0625, -71, 42, 41.9375], tile('ri_m_4107108_ne_19_060_20180930').quarter_quadrangle
    assert_equal [-155.3125, -155.25, 19.75, 19.6875],
                 tile('hi_m_1915522_ne_05_060_20220428_20220909').quarter_quadrangle
  end

  def test_the_outline_is_the_quarter_quadrangle_within_the_footprint
    tile = Tile.new(Tile.row(ITEM))

    assert tile.aligned?
    assert_equal [-71.5, -71.4375, 42.0625, 42], tile.outline
  end

  # A code that puts the tile somewhere its footprint isn't was misread, so the footprint outlines it instead
  def test_a_tile_its_code_misplaces_is_outlined_by_its_footprint
    tile = tile('ri_m_4107161_sw_19_060_20180930', [-71.506181, 41.995875, -71.431389, 42.066626])

    refute tile.aligned?
    assert_equal [-71.506181, -71.431389, 42.066626, 41.995875], tile.outline
  end

  def test_an_id_without_a_code_has_no_quadrangle
    tile = tile('ri_20180930', [-71.5, 42, -71.4, 42.1])

    assert_nil tile.code
    assert_nil tile.quadrangle
    assert_nil tile.quarter_quadrangle
    assert_equal [-71.5, -71.4, 42.1, 42], tile.outline
  end
end
