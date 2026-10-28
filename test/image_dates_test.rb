require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require 'uri'
require_relative '../image_dates'

class ImageDatesTest < Minitest::Test
  FEED = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'image-dates-feed.json')))
  LAYERS = ImageDates.layers(FEED)

  # Answers like USDA's hub and its feature layers: the feed, then for each layer's statistics and extent the
  # answers given for its service, by default polygons flown on two days
  class FakeArcGis
    Response = Struct.new(:code, :body, :message) do
      def is_a?(type)
        type == Net::HTTPSuccess ? code == '200' : super
      end
    end

    attr_reader :requests

    def initialize(answers = {})
      @answers = answers
      @requests = []
    end

    def get(url)
      @requests << url
      return Response.new('200', JSON.generate(FEED), 'OK') if url == ImageDates::FEED_URL

      service, query = url.split('/query?')
      params = URI.decode_www_form(query).to_h
      kind = params['returnExtentOnly'] ? :extent : :statistics
      answer = @answers.dig(service, kind) || default(kind)
      Response.new('200', JSON.generate(answer.is_a?(Array) ? answer.shift : answer), 'OK')
    end

    def default(kind)
      return { 'extent' => { 'xmin' => -71.9, 'ymin' => 41.1, 'xmax' => -71.0, 'ymax' => 42.1 } } if kind == :extent

      { 'features' => [
        { 'attributes' => { 'IDATE' => '2021-08-26', 'polygons' => 10 } },
        { 'attributes' => { 'IDATE' => '2021-09-26', 'polygons' => 6 } }
      ] }
    end
  end

  def layer(title)
    LAYERS.find { |candidate| candidate['title'] == title }
  end

  def test_each_layer_of_image_dates_in_the_feed_is_kept
    assert_equal ['2021 Rhode Island Image Dates', '2018 Rhode Island Image Dates', 'AL 2013',
                  '2018 West Virginia Image Dates', '2021 Puerto Rico/Virgin Islands', 'NAIP 2012 Seamlines'],
                 LAYERS.map { |candidate| candidate['title'] }
  end

  def test_a_layer_keeps_its_service_downloads_and_landing_page
    ri = layer('2021 Rhode Island Image Dates')
    downloads = 'https://naip-image-dates-usdaonline.hub.arcgis.com/api/download/v1/items/ea7614c2738d478b9e7892696c1ad166'

    assert_equal 'ea7614c2738d478b9e7892696c1ad166', ri['item']
    assert_equal 'https://services.arcgis.com/LLVEmB8Lsae3Um4s/arcgis/rest/services/Seamlines_RI44_2021/FeatureServer/0',
                 ri['service']
    assert_equal "#{downloads}/geojson?layers=0", ri['geojson']
    assert_equal "#{downloads}/csv?layers=0", ri['csv']
    assert_equal 'https://naip-image-dates-usdaonline.hub.arcgis.com/datasets/ea7614c2738d478b9e7892696c1ad166_0',
                 ri['landing']
    assert_equal [-71.9555, 41.1118, -71.0444, 42.0763], ri['bbox']
    assert_match(/\AThis data is for illustration only\. Not suitable/, ri['license'])
    refute_match(/[<>]/, ri['license'], 'the HTML is stripped')
  end

  def test_states_and_years_come_from_the_title
    assert_equal [['ri'], 2021], layer('2021 Rhode Island Image Dates').values_at('states', 'year')
    assert_equal [['al'], 2013], layer('AL 2013').values_at('states', 'year')
    assert_equal [['wv'], 2018], layer('2018 West Virginia Image Dates').values_at('states', 'year')
    assert_equal [%w[pr vi], 2021], layer('2021 Puerto Rico/Virgin Islands').values_at('states', 'year')
    assert_equal [[], 2012], layer('NAIP 2012 Seamlines').values_at('states', 'year')
  end

  def fetch(dir, api = FakeArcGis.new, extents = ImageDates::Extents.new({}, File.join(dir, 'extents.json')))
    ImageDates.fetch(dir, http: api, log: StringIO.new, extents: extents, measurer: api)
  end

  def test_fetching_adds_each_layers_statistics_and_extent
    dir = Dir.mktmpdir
    rows = fetch(dir)
    ri = rows.find { |row| row['title'] == '2021 Rhode Island Image Dates' }

    assert_equal [['2021-08-26', nil, 10], ['2021-09-26', nil, 6]], ri['groups']
    assert_equal [-71.9, 41.1, -71.0, 42.1], ri['extent']
    assert_equal rows, ImageDates.load(dir)
  ensure
    FileUtils.rm_rf(dir)
  end

  # 2012's layer is of every state flown that year, so its statistics are by state too
  def test_the_national_layer_is_summarized_by_state
    api = FakeArcGis.new
    ImageDates.statistics(api, layer('NAIP 2012 Seamlines'))
    params = URI.decode_www_form(api.requests.last.split('?').last).to_h

    assert_equal 'IDATE,State', params['groupByFieldsForStatistics']
  end

  def test_a_layer_that_cant_answer_is_left_out_and_a_busy_one_is_asked_again
    ri = layer('2021 Rhode Island Image Dates')
    broken = FakeArcGis.new(ri['service'] => { statistics: { 'error' => { 'code' => 400, 'message' => 'Invalid' } } })
    busy = FakeArcGis.new(ri['service'] => { statistics: [{ 'error' => { 'code' => 500 } }, FakeArcGis.new.default(:x)] })
    down = FakeArcGis.new(ri['service'] => { statistics: Array.new(3) { { 'error' => { 'code' => 503 } } } })
    pause = ->(_seconds) {}

    assert_nil ImageDates.statistics(broken, ri, sleeper: pause)
    assert_equal 2, ImageDates.statistics(busy, ri, sleeper: pause).size
    assert_raises(ImageDates::Error) { ImageDates.statistics(down, ri, sleeper: pause) }
  end

  def test_a_layer_is_named_by_its_states_and_year
    rows = fetch(Dir.mktmpdir).to_h do |row|
      [row['title'], ImageDates::Layer.new(row).id]
    end

    assert_equal 'usda-naip-dates-ri-2021', rows['2021 Rhode Island Image Dates']
    assert_equal 'usda-naip-dates-pr-vi-2021', rows['2021 Puerto Rico/Virgin Islands']
    assert_equal 'usda-naip-dates-2012', rows['NAIP 2012 Seamlines']
  end

  def test_a_layers_years_run_from_its_naip_year_to_its_last_flight
    layer = ImageDates::Layer.new('states' => ['tx'], 'year' => 2024,
                                  'groups' => [['2024-05-14', nil, 5], ['2025-01-02', nil, 1], ['', nil, 2]])

    assert_equal %w[2024-05-14 2025-01-02], layer.dates
    assert_equal [2024, 2025], layer.years
  end

  def test_the_national_layers_states_come_from_its_polygons
    layer = ImageDates::Layer.new('states' => [], 'year' => 2012,
                                  'groups' => [['2012-06-01', 'California', 3], ['2012-06-02', 'Rhode Island', 4]])

    assert layer.national?
    assert_equal %w[ca ri], layer.states
  end

  # USDA's own words, a paragraph or list item to an entry, with nothing added
  def test_a_layer_keeps_usdas_description
    description = layer('2021 Rhode Island Image Dates')['description']

    assert_equal 'This hosted feature layer is provided by the USDA FPAC-BC-GEO and shows image acquisition dates for ' \
                 '2021 National Agriculture Imagery Program (NAIP) imagery for Rhode Island.', description.first
    assert_includes description, 'IDATE - Image acquisition date'
    assert_equal 18, description.size
    refute(description.any? { |paragraph| paragraph.match?(/[<>]|&\w+;|  /) }, 'HTML and runs of spaces are gone')
    assert_equal description, ImageDates::Layer.new(layer('2021 Rhode Island Image Dates')).description
  end

  def test_a_layer_usda_gives_no_description_has_none
    feed = { 'dataset' => [FEED['dataset'].first.merge('description' => '<p>&nbsp;</p>')] }
    row = ImageDates.layers(feed).first

    refute row.key?('description')
    assert_empty ImageDates::Layer.new(row).description
  end

  # Measuring is kept until USDA modifies the layer, and so is a layer that couldn't be measured
  def test_a_layers_extent_is_measured_once_until_the_layer_changes
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'extents.json')
      extents = ImageDates::Extents.new({}, file)
      ri = layer('2021 Rhode Island Image Dates')
      measurements = 0
      measure = lambda do
        measurements += 1
        [-71.9, 41.1, -71.0, 42.1]
      end

      assert_equal [-71.9, 41.1, -71.0, 42.1], extents.fetch(ri, &measure)
      extents.fetch(ri, &measure)
      assert_equal 1, measurements
      extents.fetch(ri.merge('modified' => '2027-01-01T00:00:00.000Z'), &measure)
      assert_equal 2, measurements
      assert_nil extents.fetch(layer('AL 2013')) { nil }
      assert_nil extents.fetch(layer('AL 2013')) { flunk 'a layer that could not be measured is not measured again' }
      assert extents.save
      assert_equal [layer('AL 2013')['service'], ri['service']].sort, JSON.parse(File.read(file)).keys
      assert_equal [-71.9, 41.1, -71.0, 42.1], ImageDates::Extents.load(file).fetch(ri.merge('modified' => '2027-01-01T00:00:00.000Z')) { nil }
    end
  end

  def test_a_layer_too_big_to_measure_in_time_has_no_extent
    timeout = Object.new
    def timeout.get(_url) = raise(HttpClient::Error, 'GET failed 1 times; last: Net::ReadTimeout')

    assert_nil ImageDates.extent(timeout, layer('2021 Rhode Island Image Dates'))
  end

  def test_a_layers_bounds_are_its_polygons_extent_or_else_the_feeds_box
    with_extent = ImageDates::Layer.new('bbox' => [-115.8, 40.0, -112.7, 50.97], 'extent' => [-120, 40.1, -109.6, 49.7])
    without = ImageDates::Layer.new('bbox' => [-115.8, 40.0, -112.7, 50.97])

    assert_equal [-120, -109.6, 49.7, 40.1], with_extent.bounds
    assert_equal [-115.8, -112.7, 50.97, 40.0], without.bounds
  end
end
