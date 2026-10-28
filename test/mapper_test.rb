require 'minitest/autorun'
require 'json'
require_relative '../image_dates'
require_relative '../iso_record'
require_relative '../mapper'

class MapperTest < Minitest::Test
  ISO = IsoRecord.new(File.read(File.join(__dir__, 'fixtures', 'iso.xml')))
  DESCRIPTION = Mapper.description(ISO)
  SERVICE = 'https://apps.geo.fpac.usda.gov/geo-imagery/rest/services/naip/conus_naip/ImageServer'
  USDA_DESCRIPTION = ['This hosted feature layer is provided by the USDA FPAC-BC-GEO and shows image acquisition ' \
                      'dates for 2021 National Agriculture Imagery Program (NAIP) imagery for Rhode Island.',
                      'IDATE - Image acquisition date'].freeze

  def collection
    Mapper.collection(iso: ISO, west: -160.3193, east: -64.5625, north: 49.375, south: 17.625, first_year: 2010,
                      last_year: 2025, modified: '2026-10-17T16:22:21Z', service_url: SERVICE)
  end

  def image_dates(overrides = {})
    ImageDates::Layer.new({
      'item' => 'ea7614c2738d478b9e7892696c1ad166', 'title' => '2021 Rhode Island Image Dates', 'states' => ['ri'],
      'year' => 2021, 'service' => 'https://services.arcgis.com/x/arcgis/rest/services/Seamlines_RI44_2021/FeatureServer/0',
      'landing' => 'https://naip-image-dates-usdaonline.hub.arcgis.com/datasets/ea7614c2738d478b9e7892696c1ad166_0',
      'geojson' => 'https://hub.example/geojson', 'csv' => 'https://hub.example/csv',
      'bbox' => [-71.9555, 41.1118, -71.0444, 42.0763], 'extent' => [-71.96, 41.11, -71.04, 42.08],
      'issued' => '2022-06-06T19:42:05.983Z', 'modified' => '2022-06-06T19:42:05.983Z',
      'description' => USDA_DESCRIPTION, 'license' => 'This data is for illustration only.',
      'groups' => [['2021-08-26', nil, 10], ['2021-09-26', nil, 6]]
    }.merge(overrides))
  end

  def service
    { 'url' => SERVICE, 'bands' => 4, 'extent' => [-124.69, 24.43, -66.84, 49.47],
      'groups' => [
        { 'year' => 2025, 'state' => 'ri', 'tiles' => 116, 'added' => '2026-02-12T13:48:27Z' },
        { 'year' => 2025, 'state' => 'ct', 'tiles' => 370, 'added' => '2026-02-01T00:00:00Z' },
        { 'year' => 2024, 'state' => 'tx', 'tiles' => 17_278, 'added' => '2025-06-15T21:32:45Z' }
      ] }
  end

  def test_the_collection_record_describes_naip_from_usdas_iso_metadata
    record = collection
    refs = JSON.parse(record['dct_references_s'])

    assert_equal 'usda-naip', record['id']
    assert_equal 'National Agriculture Imagery Program (NAIP) Imagery', record['dct_title_s']
    assert_equal [ISO.abstract, ISO.purpose], record['dct_description_sm'], "USDA's words, and nothing else"
    assert_equal 'U.S. Department of Agriculture', record['schema_provider_s']
    assert_equal %w[Collections Imagery], record['gbl_resourceClass_sm']
    assert_equal ['2002-2025'], record['dct_temporal_sm'], "NAIP's ISO metadata says it began in 2002"
    assert_equal 'ENVELOPE(-160.3193, -64.5625, 49.375, 17.625)', record['dcat_bbox']
    assert_equal ['https://creativecommons.org/publicdomain/mark/1.0/'], record['dct_license_sm']
    assert_equal 'https://naip-usdaonline.hub.arcgis.com/', refs['http://schema.org/url']
    assert_equal ISO.url, refs['http://www.isotc211.org/schemas/2005/gmd/']
    assert refs['http://schema.org/thumbnailUrl'].start_with?("#{SERVICE}/exportImage?")
    refute record.key?('pcdm_memberOf_sm')
  end

  def test_an_image_dates_record_links_its_layer_and_downloads
    record = Mapper.image_dates(image_dates, description: DESCRIPTION, index_maps: ['usda-naip-index-ri-2021'])
    refs = JSON.parse(record['dct_references_s'])

    assert_equal 'usda-naip-dates-ri-2021', record['id']
    assert_equal 'NAIP Image Dates of Rhode Island, 2021', record['dct_title_s']
    assert_equal ['2021 Rhode Island Image Dates'], record['dct_alternative_sm']
    assert_equal 'U.S. Department of Agriculture', record['schema_provider_s']
    assert_equal ['Datasets'], record['gbl_resourceClass_sm']
    assert_equal ['Polygon data'], record['gbl_resourceType_sm']
    assert_equal '2022-06-06', record['dct_issued_s']
    assert_equal '2022-06-06T19:42:05Z', record['gbl_mdModified_dt']
    assert_equal ['Rhode Island'], record['dct_spatial_sm']
    assert_equal 'ENVELOPE(-71.96, -71.04, 42.08, 41.11)', record['dcat_bbox'], "the polygons' extent, not the feed's"
    assert_equal ['usda-naip'], record['pcdm_memberOf_sm']
    assert_equal ['usda-naip-index-ri-2021'], record['dct_source_sm'], 'the index map of its imagery is its source'
    refute record.key?('dct_relation_sm')
    assert_equal ['This data is for illustration only.', Mapper::CREDIT], record['dct_rights_sm']
    refute record.key?('dct_license_sm'), "USDA doesn't license its image dates"
    assert_equal image_dates.row['service'], refs['urn:x-esri:serviceType:ArcGIS#FeatureLayer']
    assert_equal [{ 'url' => 'https://hub.example/geojson', 'label' => 'GeoJSON' },
                  { 'url' => 'https://hub.example/csv', 'label' => 'CSV' }], refs['http://schema.org/downloadUrl']
    assert_equal image_dates.row['landing'], refs['http://schema.org/url']
  end

  def test_an_image_dates_record_has_usdas_description_of_its_layer
    assert_equal USDA_DESCRIPTION, Mapper.image_dates(image_dates, description: DESCRIPTION)['dct_description_sm']
  end

  # Three layers have no description of their own
  def test_an_image_dates_record_usda_gives_no_description_has_the_collections
    layer = image_dates('description' => nil)

    assert_equal DESCRIPTION, Mapper.image_dates(layer, description: DESCRIPTION)['dct_description_sm']
  end

  def test_the_national_image_dates_are_of_the_states_its_polygons_name
    layer = image_dates('title' => 'NAIP 2012 Seamlines', 'states' => [], 'year' => 2012,
                        'groups' => [['2012-06-01', 'California', 3], ['2012-06-02', 'Rhode Island', 4]])
    record = Mapper.image_dates(layer, description: DESCRIPTION)

    assert_equal 'usda-naip-dates-2012', record['id']
    assert_equal 'NAIP Image Dates, 2012', record['dct_title_s']
    assert_equal ['United States', 'California', 'Rhode Island'], record['dct_spatial_sm']
  end

  # The service's own description is a placeholder, so it has the collection's
  def test_the_image_service_record_has_the_collections_description
    record = Mapper.image_service(service, description: DESCRIPTION)
    refs = JSON.parse(record['dct_references_s'])

    assert_equal 'usda-naip-latest', record['id']
    assert_equal DESCRIPTION, record['dct_description_sm']
    assert_equal 'U.S. Department of Agriculture', record['schema_provider_s']
    assert_equal ['Imagery'], record['gbl_resourceClass_sm']
    assert_equal [2024, 2025], record['gbl_indexYear_im']
    assert_equal ['United States', 'Connecticut', 'Rhode Island', 'Texas'], record['dct_spatial_sm']
    assert_equal 'ENVELOPE(-124.69, -66.84, 49.47, 24.43)', record['dcat_bbox']
    assert_equal '2026-02-12T13:48:27Z', record['gbl_mdModified_dt']
    assert_equal SERVICE, refs['urn:x-esri:serviceType:ArcGIS#ImageMapLayer']
    assert refs['http://schema.org/thumbnailUrl'].start_with?("#{SERVICE}/exportImage?")
  end

  def test_coordinates_and_sizes_lose_their_padding
    assert_equal 42, Mapper.coordinate(42.0)
    assert_equal(-71.4375, Mapper.coordinate(-71.4375))
    assert_equal 'ENVELOPE(-72, -71, 42.0625, 41)', Mapper.format_envelope(-72.0, -71.0, 42.0625, 41.0)
    assert_equal '3 KB', Mapper.size_label(2_001)
    assert_equal '14.7 MB', Mapper.size_label(14_700_000)
  end
end
