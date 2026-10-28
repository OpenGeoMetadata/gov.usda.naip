require 'minitest/autorun'
require 'json'
require_relative '../planetary_computer'
require_relative '../index_map'
require_relative '../quadrangles'

# Index maps of the fixture snapshot's tiles: see test/fixtures/README.md
class IndexMapTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'snapshot')
  QUADRANGLES = Quadrangles.load(File.join(__dir__, 'fixtures', 'quadrangles.json'))
  INDEX_MAPS = {}.tap do |index_maps|
    PlanetaryComputer.each_state(FIXTURE, states: %w[hi ia ny ri]) do |_state, rows|
      IndexMap.build(rows.map { |row| Tile.new(row) }).each { |index_map| index_maps[index_map.id] = index_map }
    end
  end
  URL = 'https://raw.githubusercontent.com/OpenGeoMetadata/gov.usda.naip/main/index-maps/' \
        'usda-naip-index-ri-2018.geojson'
  DESCRIPTION = ["USDA's abstract of NAIP", "USDA's purpose of NAIP"].freeze

  def features(id)
    JSON.parse(INDEX_MAPS.fetch(id).geojson(QUADRANGLES))['features']
  end

  def record(id, bytes = 2_000)
    INDEX_MAPS.fetch(id).record(URL, bytes, description: DESCRIPTION)
  end

  def test_one_index_map_for_each_state_and_year
    assert_equal %w[usda-naip-index-hi-2021 usda-naip-index-ia-2023 usda-naip-index-ny-2022
                    usda-naip-index-ri-2018 usda-naip-index-ri-2021], INDEX_MAPS.keys.sort
  end

  def test_each_sheet_is_a_quarter_quadrangle_labeled_by_name_and_linked_to_its_files
    sheet = features('usda-naip-index-ri-2018').find { |feature| feature.dig('properties', 'labelAlt') == 'm_4207161_sw' }
    base = 'https://naipeuwest.blob.core.windows.net/naip/v002/ri/2018/ri_060cm_2018/42071/m_4207161_sw_19_060_20180930'

    assert_equal(
      { 'label' => 'Franklin SW', 'labelAlt' => 'm_4207161_sw', 'date' => '2018-09-30', 'projection' => 'EPSG:26919',
        'available' => true,
        'websiteUrl' => 'https://planetarycomputer.microsoft.com/api/stac/v1/collections/naip/items/' \
                        'ri_m_4207161_sw_19_060_20180930_20181211',
        'download' => "#{base}.tif", 'thumbUrl' => "#{base}.200.jpg" },
      sheet['properties']
    )
    assert_equal [[[-71.5, 42], [-71.4375, 42], [-71.4375, 42.0625], [-71.5, 42.0625], [-71.5, 42]]],
                 sheet.dig('geometry', 'coordinates')
  end

  def test_ocean_extensions_keep_their_suffix
    labels = features('usda-naip-index-ri-2018').map { |feature| feature.dig('properties', 'label') }

    assert_equal ['Kingston OE S NE', 'Kingston OE S NW', 'Franklin SE', 'Franklin SW'], labels
  end

  # Hawaii's tiles are only from 2021, which has no FGDC, so no name is known for them
  def test_a_sheet_without_a_known_name_is_labeled_by_its_code
    properties = features('usda-naip-index-hi-2021').first['properties']

    assert_equal 'm_1915522_ne', properties['label']
    refute properties.key?('labelAlt'), 'the code is the label already'
  end

  # A year without FGDC still gets the names other years' FGDC gave
  def test_names_carry_over_to_years_without_fgdc
    labels = features('usda-naip-index-ri-2021').map { |feature| feature.dig('properties', 'label') }

    assert_equal ['Kingston OE S NE', 'Franklin SW'], labels
  end

  # New York's 2022 tiles of Harrison Valley were flown in May and again in November
  def test_a_quarter_quadrangle_flown_twice_stacks_its_tiles_with_the_latest_on_top
    dates = features('usda-naip-index-ny-2022').map { |feature| feature['properties'].values_at('labelAlt', 'date') }

    assert_equal [%w[m_4107703_ne 2022-05-08], %w[m_4107703_ne 2022-11-10],
                  %w[m_4107703_nw 2022-05-08], %w[m_4107703_nw 2022-11-10]], dates
  end

  # Iowa's 2023 tile of m_4009510_nw is listed twice, from one flight processed on two dates
  def test_only_the_later_processing_of_a_tile_is_kept
    index_map = INDEX_MAPS.fetch('usda-naip-index-ia-2023')

    assert_equal 1, index_map.sheets
    assert_equal 1, index_map.twins
    assert_match(/_20231019_20240104\z/, features('usda-naip-index-ia-2023').first.dig('properties', 'websiteUrl'))
  end

  # A change to one tile changes one line of the file
  def test_each_sheet_is_a_line_of_its_own
    geojson = INDEX_MAPS.fetch('usda-naip-index-ri-2018').geojson(QUADRANGLES)

    assert_equal 4 + 2, geojson.lines.size
  end

  def test_an_index_maps_record_points_to_its_geojson
    record = record('usda-naip-index-ri-2018')
    refs = JSON.parse(record['dct_references_s'])

    assert_equal 'usda-naip-index-ri-2018', record['id']
    assert_equal 'Index to NAIP Aerial Imagery of Rhode Island, 2018', record['dct_title_s']
    assert_equal %w[Maps Imagery], record['gbl_resourceClass_sm']
    assert_equal ['Index maps', 'Aerial photographs'], record['gbl_resourceType_sm']
    assert_equal ['United States. Farm Service Agency'], record['dct_creator_sm']
    assert_equal 'Microsoft Planetary Computer', record['schema_provider_s']
    assert_equal ['Rhode Island'], record['dct_spatial_sm']
    assert_equal ['2018'], record['dct_temporal_sm']
    assert_equal 'GeoJSON', record['dct_format_s']
    assert_equal 'ENVELOPE(-71.625, -71.375, 42.0625, 41.3125)', record['dcat_bbox']
    assert_equal ['usda-naip'], record['pcdm_memberOf_sm']
    assert_equal ['https://creativecommons.org/publicdomain/zero/1.0/'], record['dct_license_sm']
    assert_equal '2026-10-17T16:22:25Z', record['gbl_mdModified_dt']
    assert_equal URL, refs['https://openindexmaps.org']
    assert_equal [{ 'url' => URL, 'label' => 'GeoJSON (2 KB)' }], refs['http://schema.org/downloadUrl']
    assert_equal 'https://planetarycomputer.microsoft.com/dataset/naip', refs['http://schema.org/url']
    assert_equal 'Microsoft Planetary Computer', record['schema_provider_s'], 'Planetary Computer hosts what it outlines'
    refute record.key?('dct_relation_sm'), 'the image dates name their index map, not the other way round'
    refute record.key?('dct_source_sm')
  end

  # Neither USDA nor Microsoft describes an index map, so it's given the collection's description
  def test_an_index_map_carries_the_description_its_given
    assert_equal DESCRIPTION, record('usda-naip-index-ri-2018')['dct_description_sm']
  end

  # Hawaii's 2021 tiles were flown in 2022, so the record covers both years
  def test_tiles_flown_after_their_naip_year_widen_its_dates
    record = record('usda-naip-index-hi-2021')

    assert_equal 'Index to NAIP Aerial Imagery of Hawaii, 2021', record['dct_title_s']
    assert_equal ['2021-2022'], record['dct_temporal_sm']
    assert_equal [2021, 2022], record['gbl_indexYear_im']
  end
end
