require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require 'uri'
require_relative '../planetary_computer'

class PlanetaryComputerTest < Minitest::Test
  ITEM = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'item.json')))

  # Answers like Planetary Computer's STAC search, a page of items at a time with a link to the next, or with a
  # canned body
  class FakeApi
    Response = Struct.new(:code, :body, :message) do
      def is_a?(type)
        type == Net::HTTPSuccess ? code == '200' : super
      end
    end

    attr_reader :requests

    # @param items [Hash{String => Array}] each state's items
    def initialize(items, page_size: 2, body: nil)
      @items = items
      @page_size = page_size
      @body = body
      @requests = []
    end

    def get(url)
      params = URI.decode_www_form(URI(url).query).to_h
      @requests << params
      return Response.new('200', @body, 'OK') if @body

      state = params['filter'][/'(\w+)'/, 1]
      offset = params['token'].to_i
      page = @items.fetch(state, [])[offset, @page_size] || []
      links = []
      if offset + @page_size < @items.fetch(state, []).size
        links << { 'rel' => 'next', 'href' => "#{url.sub(/&token=\d+/, '')}&token=#{offset + @page_size}" }
      end
      Response.new('200', JSON.generate('type' => 'FeatureCollection', 'features' => page, 'links' => links), 'OK')
    end
  end

  def setup
    @tmp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
  end

  def items(state, count)
    Array.new(count) do |index|
      ITEM.merge('id' => "#{state}_m_42071#{format('%02d', index + 1)}_sw_19_060_20180930",
                 'properties' => ITEM['properties'].merge('naip:state' => state))
    end
  end

  def test_pages_through_each_state_and_keeps_its_rows_in_the_snapshot
    api = FakeApi.new({ 'ri' => items('ri', 5), 'ct' => items('ct', 1) })
    fetched = {}
    PlanetaryComputer.fetch(@tmp_dir, states: %w[ct ri vi], http: api, log: StringIO.new) { |state, rows| fetched[state] = rows }

    assert_equal({ 'ct' => 1, 'ri' => 5, 'vi' => 0 }, fetched.transform_values(&:size))
    assert_equal 3, (api.requests.count { |params| params['filter'] == %("naip:state" = 'ri') }), 'three pages of ri'
    assert_equal PlanetaryComputer::FIELDS.join(','), api.requests.first['fields']
    assert_equal Tile.row(items('ri', 1).first), Snapshot.read(@tmp_dir, 'naip-ri.jsonl').first
    assert_empty Snapshot.read(@tmp_dir, 'naip-vi.jsonl'), 'a state with no tiles still gets a file'
  end

  def test_reads_each_state_back_from_a_snapshot
    PlanetaryComputer.fetch(@tmp_dir, states: %w[ri], http: FakeApi.new({ 'ri' => items('ri', 3) }), log: StringIO.new)
    read = []
    PlanetaryComputer.each_state(@tmp_dir, states: %w[ri]) { |state, rows| read << [state, rows.size] }

    assert_equal [['ri', 3]], read
    assert_raises(Snapshot::Error) { PlanetaryComputer.each_state(@tmp_dir, states: %w[ct]) { nil } }
  end

  def test_an_item_repeated_across_pages_is_kept_once
    ri = items('ri', 3)
    rows = PlanetaryComputer.fetch_state(FakeApi.new({ 'ri' => ri + [ri.first] }), 'ri')

    assert_equal 3, rows.size
  end

  def test_an_item_from_another_state_stops_the_fetch
    assert_raises(PlanetaryComputer::Error) { PlanetaryComputer.fetch_state(FakeApi.new({ 'ri' => items('ct', 1) }), 'ri') }
  end

  def test_an_answer_that_isnt_a_list_of_items_stops_the_fetch
    assert_raises(PlanetaryComputer::Error) { PlanetaryComputer.fetch_state(FakeApi.new({}, body: '<html>busy</html>'), 'ri') }
    assert_raises(PlanetaryComputer::Error) { PlanetaryComputer.fetch_state(FakeApi.new({}, body: '{"code":"Error"}'), 'ri') }
  end
end
