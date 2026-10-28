require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require_relative '../harvester'

# The fixture is a real snapshot, cut down to a few tiles of four states and a few layers of image dates: see
# test/fixtures/README.md
class HarvesterTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'snapshot')
  STATES = %w[hi ia ny ri].freeze
  ROWS = STATES.to_h { |state| [state, Snapshot.read(FIXTURE, PlanetaryComputer.file(state))] }
  IMAGE_DATES = Snapshot.read(FIXTURE, ImageDates::FILE)
  SERVICE = Snapshot.read(FIXTURE, ImageService::FILE)
  ISO = [{ 'url' => IsoRecord::URL, 'xml' => File.read(File.join(__dir__, 'fixtures', 'iso.xml')) }].freeze
  QUADRANGLES = File.join(__dir__, 'fixtures', 'quadrangles.json')
  INDEX_MAPS = %w[usda-naip-index-hi-2021 usda-naip-index-ia-2023 usda-naip-index-ny-2022 usda-naip-index-ri-2018
                  usda-naip-index-ri-2021].freeze
  DATES = IMAGE_DATES.map { |row| ImageDates::Layer.new(row).id }.sort.freeze
  TODAY = Date.new(2026, 10, 27)

  def setup
    @tmp_dir = Dir.mktmpdir
    @metadata_dir = File.join(@tmp_dir, 'metadata-aardvark')
    @index_map_dir = File.join(@tmp_dir, 'index-maps')
    @withdrawn_file = File.join(@tmp_dir, 'withdrawn.json')
    @sources = 0
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
  end

  # A snapshot directory holding the given tiles of each state, and USDA's sources
  def snapshot(rows = ROWS, image_dates: IMAGE_DATES)
    dir = File.join(@tmp_dir, "snapshot-#{@sources += 1}")
    FileUtils.mkdir_p(dir)
    files = rows.to_h { |state, state_rows| [PlanetaryComputer.file(state), state_rows] }
    files.merge(ImageDates::FILE => image_dates, ImageService::FILE => SERVICE, IsoRecord::FILE => ISO)
         .each { |name, lines| File.write(File.join(dir, name), lines.map { |line| "#{JSON.generate(line)}\n" }.join) }
    dir
  end

  def harvest(source, **options)
    Harvester.run(source: source, metadata_dir: @metadata_dir, index_map_dir: @index_map_dir,
                  withdrawn_file: @withdrawn_file, states: STATES, quadrangles: Quadrangles.load(QUADRANGLES),
                  today: TODAY, log: StringIO.new, **options)
  end

  def record_path(id)
    directory = if id.start_with?('usda-naip-index-') then 'index-maps'
                elsif id.start_with?('usda-naip-dates-') then 'image-dates'
                end
    File.join(*[@metadata_dir, directory, "#{id}.json"].compact)
  end

  def record(id)
    JSON.parse(File.read(record_path(id)))
  end

  def geojson(id)
    File.join(@index_map_dir, "#{id}.geojson")
  end

  def withdrawals
    JSON.parse(File.read(@withdrawn_file))['withdrawn']
  end

  # The rows without Rhode Island's 2021 tiles
  def without_ri_2021
    ROWS.merge('ri' => ROWS['ri'].reject { |row| row['year'] == 2021 })
  end

  def test_writes_every_kind_of_record_in_its_place
    counts = harvest(snapshot)

    assert_equal INDEX_MAPS.size, counts[:index_maps_created]
    INDEX_MAPS.each do |id|
      assert File.exist?(geojson(id)), "#{id}'s GeoJSON"
      assert_equal id, record(id)['id']
    end
    assert_equal DATES.size, counts[:image_dates_created]
    DATES.each { |id| assert_equal id, record(id)['id'] }
    assert_equal 'usda-naip-latest', record('usda-naip-latest')['id']
    assert_equal 'usda-naip', record('usda-naip')['id']
    assert_equal 13, counts[:sheets]
    assert_equal 1, counts[:twins]
    assert_equal 3, counts[:unnamed], "Hawaii's two tiles and Iowa's one have no name"
    refute File.exist?(@withdrawn_file), 'nothing was withdrawn, so there should be no log'
  end

  # Planetary Computer hosts what the index maps outline; everything else is USDA's
  def test_index_maps_are_provided_by_planetary_computer_and_the_rest_by_usda
    harvest(snapshot)

    INDEX_MAPS.each { |id| assert_equal 'Microsoft Planetary Computer', record(id)['schema_provider_s'], id }
    (DATES + %w[usda-naip-latest usda-naip]).each do |id|
      assert_equal 'U.S. Department of Agriculture', record(id)['schema_provider_s'], id
    end
  end

  # The image dates say when each of the index map's tiles was flown, so the index map is their source. Only the
  # image dates say so: a viewer finds what an index map is the source of from them.
  def test_an_index_map_is_the_source_of_the_image_dates_of_its_imagery
    harvest(snapshot)

    assert_equal ['usda-naip-index-ri-2018'], record('usda-naip-dates-ri-2018')['dct_source_sm']
    assert_equal ['usda-naip-index-hi-2021'], record('usda-naip-dates-hi-2021')['dct_source_sm']
    (INDEX_MAPS + DATES).each { |id| refute record(id).key?('dct_relation_sm'), id }
    INDEX_MAPS.each { |id| refute record(id).key?('dct_source_sm'), id }
  end

  # No description is written here: the collection's is USDA's abstract and purpose of NAIP, each layer of image
  # dates has USDA's description of it, and the rest repeat the collection's
  def test_every_description_is_usdas_own
    harvest(snapshot)
    iso = IsoRecord.new(ISO.first['xml'])
    collection = [iso.abstract, iso.purpose]
    layers = IMAGE_DATES.to_h { |row| [ImageDates::Layer.new(row).id, row['description']] }

    assert_equal collection, record('usda-naip')['dct_description_sm']
    (INDEX_MAPS + ['usda-naip-latest']).each { |id| assert_equal collection, record(id)['dct_description_sm'], id }
    layers.each { |id, description| assert_equal description || collection, record(id)['dct_description_sm'], id }
    assert_nil layers['usda-naip-dates-wi-2024'], "Wisconsin's 2024 layer is one USDA gave no description"
  end

  def test_image_dates_without_an_index_map_have_no_source
    harvest(snapshot)
    alone = DATES.reject { |id| INDEX_MAPS.include?(id.sub('-dates-', '-index-')) }

    refute_empty alone
    alone.each { |id| refute record(id).key?('dct_source_sm'), id }
  end

  def test_a_record_points_to_its_geojson_where_github_serves_it
    harvest(snapshot)
    refs = JSON.parse(record('usda-naip-index-ri-2018')['dct_references_s'])
    size = File.size(geojson('usda-naip-index-ri-2018'))

    assert_equal "#{Harvester::INDEX_MAP_URL}/usda-naip-index-ri-2018.geojson", refs['https://openindexmaps.org']
    assert_equal 'https://raw.githubusercontent.com/OpenGeoMetadata/gov.usda.naip/main/index-maps/' \
                 'usda-naip-index-ri-2018.geojson', refs['https://openindexmaps.org']
    assert_equal "GeoJSON (#{Mapper.size_label(size)})", refs['http://schema.org/downloadUrl'].first['label']
  end

  def test_index_map_url_can_point_elsewhere
    harvest(snapshot, index_map_url: 'http://localhost:8000/index-maps/')
    refs = JSON.parse(record('usda-naip-index-ri-2018')['dct_references_s'])

    assert_equal 'http://localhost:8000/index-maps/usda-naip-index-ri-2018.geojson', refs['https://openindexmaps.org']
  end

  def test_writes_a_collection_record_covering_every_member
    harvest(snapshot)
    collection = record('usda-naip')
    members = (INDEX_MAPS + DATES + ['usda-naip-latest']).map { |id| record(id) }

    assert_equal 'National Agriculture Imagery Program (NAIP) Imagery', collection['dct_title_s']
    assert_equal ["2002-#{members.flat_map { |member| member['gbl_indexYear_im'] }.max}"], collection['dct_temporal_sm']
    assert_equal members.map { |member| member['gbl_mdModified_dt'] }.max, collection['gbl_mdModified_dt']
    members.each { |member| assert_equal ['usda-naip'], member['pcdm_memberOf_sm'] }
  end

  def test_files_are_pretty_printed_utf8_with_a_trailing_newline
    harvest(snapshot)
    content = File.read(record_path('usda-naip-index-ri-2018'), mode: 'r:utf-8')

    assert content.end_with?("}\n")
    assert_equal JSON.pretty_generate(JSON.parse(content)), content.chomp
  end

  def test_second_run_changes_nothing
    source = snapshot
    harvest(source)
    counts = harvest(source)

    assert_equal INDEX_MAPS.size, counts[:index_maps_unchanged]
    assert_equal DATES.size, counts[:image_dates_unchanged]
    assert_equal :unchanged, counts[:image_service]
    assert_equal :unchanged, counts[:collection]
  end

  def test_changed_tile_updates_its_index_map
    harvest(snapshot)
    rows = ROWS.merge('ri' => ROWS['ri'].map do |row|
      row['id'].start_with?('ri_m_4207161_sw_19_060_2018') ? row.merge('datetime' => '2018-10-01T00:00:00Z') : row
    end)
    counts = harvest(snapshot(rows))

    assert_equal 1, counts[:index_maps_updated]
    assert_match(/2018-10-01/, File.read(geojson('usda-naip-index-ri-2018')))
  end

  def test_withdraws_an_index_map_whose_tiles_leave_planetary_computer
    harvest(snapshot)
    counts = harvest(snapshot(without_ri_2021), force: true)

    assert_equal 1, counts[:withdrawn]
    refute File.exist?(record_path('usda-naip-index-ri-2021'))
    refute File.exist?(geojson('usda-naip-index-ri-2021'))
    assert_equal [{ 'id' => 'usda-naip-index-ri-2021', 'date' => '2026-10-27', 'reason' => 'upstream-removed',
                    'note' => 'Planetary Computer no longer lists NAIP tiles for this state and year.' }], withdrawals
  end

  def test_withdraws_image_dates_the_hub_stops_listing
    harvest(snapshot)
    gone = IMAGE_DATES.first
    counts = harvest(snapshot(image_dates: IMAGE_DATES.drop(1)), force: true)
    id = ImageDates::Layer.new(gone).id

    assert_equal 1, counts[:withdrawn]
    refute File.exist?(record_path(id))
    assert_equal [{ 'id' => id, 'date' => '2026-10-27', 'reason' => 'upstream-removed',
                    'note' => "USDA's image dates hub no longer lists this layer." }], withdrawals
  end

  def test_republished_index_map_leaves_the_log
    harvest(snapshot)
    harvest(snapshot(without_ri_2021), force: true)
    counts = harvest(snapshot)

    assert_equal 1, counts[:republished]
    assert_empty withdrawals
  end

  def test_refuses_to_withdraw_after_a_large_drop
    harvest(snapshot)
    total = INDEX_MAPS.size + DATES.size + 1
    error = assert_raises(Harvester::Error) { harvest(snapshot(without_ri_2021)) }

    assert_match(/would leave #{total - 1} records, down from #{total}/, error.message)
    assert File.exist?(geojson('usda-naip-index-ri-2021')), 'nothing should have been deleted'
  end

  def test_refuses_a_listing_that_lost_a_state
    harvest(snapshot)
    error = assert_raises(Harvester::Error) { harvest(snapshot(ROWS.merge('hi' => [])), max_shrink: 0.5) }

    assert_match(/no tiles for hi/, error.message)
  end

  def test_refuses_a_hub_that_lists_no_image_dates
    harvest(snapshot)
    error = assert_raises(Harvester::Error) { harvest(snapshot(image_dates: []), max_shrink: 1) }

    assert_match(/image dates hub lists no layers/, error.message)
  end

  def test_refuses_an_index_map_that_lost_many_sheets
    harvest(snapshot)
    File.write(geojson('usda-naip-index-ri-2018'),
               "{\"type\":\"FeatureCollection\",\"features\":[\n#{Array.new(50, '{}').join(",\n")}\n]}\n")
    error = assert_raises(Harvester::Error) { harvest(snapshot) }

    assert_match(/usda-naip-index-ri-2018 \(50 to 4\)/, error.message)
    assert harvest(snapshot, force: true)
  end

  def test_refuses_an_empty_listing
    assert_raises(Harvester::Error) { harvest(snapshot(STATES.to_h { |state| [state, []] })) }
  end

  def test_a_state_missing_from_the_snapshot_stops_the_run
    assert_raises(Snapshot::Error) { harvest(snapshot(ROWS.except('ny'))) }
  end

  def test_dry_run_writes_nothing
    counts = harvest(snapshot, dry_run: true)

    assert_equal INDEX_MAPS.size, counts[:index_maps_created]
    refute Dir.exist?(@metadata_dir)
    refute Dir.exist?(@index_map_dir)
  end
end
