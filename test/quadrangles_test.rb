require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../quadrangles'

class QuadranglesTest < Minitest::Test
  FGDC = File.join(__dir__, 'fixtures', 'fgdc')

  # Answers each URL with the FGDC fixture of the same name, or a 404
  class FakeStorage
    Response = Struct.new(:code, :body) do
      def is_a?(type)
        type == Net::HTTPSuccess ? code == '200' : super
      end
    end

    attr_reader :requests

    def initialize(requests)
      @requests = requests
    end

    def get(url)
      @requests << url
      path = File.join(FGDC, File.basename(url))
      File.exist?(path) ? Response.new('200', File.binread(path)) : Response.new('404', '')
    end
  end

  def setup
    @tmp_dir = Dir.mktmpdir
    @file = File.join(@tmp_dir, 'quadrangles.json')
    @requests = Queue.new
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
  end

  def fgdc(name)
    File.read(File.join(FGDC, name))
  end

  def tile(id, year, fgdc = nil)
    Tile.new('id' => id, 'year' => year,
             'metadata' => fgdc && "https://naipeuwest.blob.core.windows.net/naip/v002/ri/#{year}/ri_fgdc_#{year}/x/#{fgdc}")
  end

  def fill(names, tiles)
    quadrangles = Quadrangles.new(names, @file)
    looked_up = quadrangles.fill(tiles, http_factory: -> { FakeStorage.new(@requests) })
    [quadrangles, looked_up]
  end

  def test_reads_the_name_from_the_place_keyword_naming_the_quarter
    assert_equal 'Franklin', Quadrangles.parse(fgdc('m_4207161_sw_19_060_20180930.txt'), 'SW')
    assert_equal 'Kingston OE S', Quadrangles.parse(fgdc('m_4107144_ne_19_060_20180816.txt'), 'NE')
    assert_nil Quadrangles.parse(fgdc('m_4207161_sw_19_060_20180930.txt'), 'NE'), 'the keyword names the SW quarter'
  end

  def test_names_are_title_cased_as_usgs_writes_them
    {
      'WICKFORD' => 'Wickford', 'KINGSTON OE S' => 'Kingston OE S', 'LAKE OF THE WOODS' => 'Lake of the Woods',
      'MCALLEN' => 'McAllen', 'WILKES-BARRE EAST' => 'Wilkes-Barre East', "O'NEILL" => "O'Neill",
      'FORT WORTH SW' => 'Fort Worth SW', 'N LOUP' => 'N Loup'
    }.each { |name, expected| assert_equal expected, Quadrangles.title_case(name), name }
  end

  def test_fills_each_unknown_quadrangle_from_its_latest_tiles_fgdc
    tiles = [tile('ri_m_4207161_sw_19_060_20160801', 2016, 'm_4207161_sw_19_060_20160801.txt'),
             tile('ri_m_4207161_sw_19_060_20180930', 2018, 'm_4207161_sw_19_060_20180930.txt'),
             tile('ri_m_4207161_sw_19_060_20210826', 2021),
             tile('ri_m_4107144_ne_19_060_20180816', 2018, 'm_4107144_ne_19_060_20180816.txt')]
    quadrangles, looked_up = fill({}, tiles)

    assert_equal 2, looked_up
    assert_equal 2, @requests.size, 'one FGDC is read for each quadrangle'
    assert_equal 'Franklin', quadrangles.name('4207161')
    assert_equal 'Kingston OE S', quadrangles.name('4107144')
  end

  def test_known_quadrangles_and_tiles_without_fgdc_are_not_looked_up
    _quadrangles, looked_up = fill({ '4207161' => 'Franklin', '4107144' => nil },
                                   [tile('ri_m_4207161_sw_19_060_20180930', 2018, 'm_4207161_sw_19_060_20180930.txt'),
                                    tile('ri_m_4107144_ne_19_060_20180816', 2018, 'm_4107144_ne_19_060_20180816.txt'),
                                    tile('ri_m_4107145_ne_19_060_20210826', 2021)])

    assert_equal 0, looked_up
    assert_empty @requests
  end

  # An FGDC that names nothing is kept as null, so it isn't read again; one that can't be read is tried again later
  def test_an_fgdc_without_a_name_is_kept_as_null_and_a_missing_one_is_not_kept
    quadrangles, = fill({}, [tile('ri_m_4207161_ne_19_060_20180930', 2018, 'm_4207161_sw_19_060_20180930.txt'),
                             tile('ri_m_4107145_ne_19_060_20180816', 2018, 'missing.txt')])
    quadrangles.save
    names = JSON.parse(File.read(@file))

    assert_equal({ '4207161' => nil }, names)
  end

  def test_saves_one_quadrangle_to_a_line_in_order_and_only_when_names_were_added
    quadrangles, = fill({ '4207161' => 'Franklin' },
                        [tile('ri_m_4107144_ne_19_060_20180816', 2018, 'm_4107144_ne_19_060_20180816.txt')])

    assert quadrangles.save
    assert_equal "{\n  \"4107144\": \"Kingston OE S\",\n  \"4207161\": \"Franklin\"\n}\n", File.read(@file)
    refute quadrangles.save, 'nothing new to save'
    assert_equal 2, Quadrangles.load(@file).size
  end
end
