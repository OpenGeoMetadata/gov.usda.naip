require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require 'uri'
require_relative '../image_service'

class ImageServiceTest < Minitest::Test
  # Answers like the image service: its description, then the statistics of its catalog
  class FakeService
    Response = Struct.new(:code, :body, :message) do
      def is_a?(type)
        type == Net::HTTPSuccess ? code == '200' : super
      end
    end

    attr_reader :requests

    def initialize(statistics = nil)
      @statistics = statistics
      @requests = []
    end

    def get(url)
      @requests << url
      body =
        if url.include?('/query?')
          @statistics || { 'features' => [{ 'attributes' => {
            'year_ts' => 2025, 'ST' => 'RI', 'tiles' => 116, 'added' => 1_770_904_107_623
          } }] }
        else
          { 'bandCount' => 4, 'extent' => { 'xmin' => -124.7, 'ymin' => 24.4, 'xmax' => -66.8, 'ymax' => 49.5 } }
        end
      Response.new('200', JSON.generate(body), 'OK')
    end
  end

  def test_fetches_the_service_and_the_tiles_of_each_state_and_year
    Dir.mktmpdir do |dir|
      api = FakeService.new
      row = ImageService.fetch(dir, http: api, log: StringIO.new)
      params = URI.decode_www_form(api.requests.last.split('?').last).to_h

      assert_equal [-124.7, 24.4, -66.8, 49.5], row['extent']
      assert_equal 4, row['bands']
      assert_equal [{ 'year' => 2025, 'state' => 'ri', 'tiles' => 116, 'added' => '2026-02-12T13:48:27Z' }],
                   row['groups']
      assert_equal 'year_ts,ST', params['groupByFieldsForStatistics']
      assert_equal 'year_ts IS NOT NULL', params['where'], "overviews, which have no year, aren't counted"
      assert_equal row, ImageService.load(dir)
    end
  end

  def test_an_error_stops_the_fetch
    Dir.mktmpdir do |dir|
      api = FakeService.new({ 'error' => { 'code' => 500, 'message' => 'Unable to complete operation.' } })

      assert_raises(ImageService::Error) { ImageService.fetch(dir, http: api, log: StringIO.new) }
    end
  end
end
