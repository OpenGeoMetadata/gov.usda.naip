require 'minitest/autorun'
require 'json'
require_relative '../tile'

class TileTest < Minitest::Test
  ITEM = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'item.json')))

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
