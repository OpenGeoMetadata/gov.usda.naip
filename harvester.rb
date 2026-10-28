require 'date'
require 'fileutils'
require 'json'
require 'set'
require_relative 'extent'
require_relative 'http_client'
require_relative 'image_dates'
require_relative 'image_service'
require_relative 'index_map'
require_relative 'iso_record'
require_relative 'mapper'
require_relative 'planetary_computer'
require_relative 'quadrangles'
require_relative 'snapshot'
require_relative 'tile'

# Regenerates the NAIP records in metadata-aardvark/, and the index maps in index-maps/, and logs records that leave
# the repository in withdrawn.json. The records come from four sources:
# - USDA's ISO metadata for NAIP, for the collection record;
# - USDA's image service of the latest imagery of each state, which gets a record of its own;
# - USDA's image dates hub, whose layers of each state's flights each get a record;
# - the NAIP tiles Microsoft's Planetary Computer hosts, an index map of each state's from each year.
#
# Each source lists everything on every run, so there is no incremental state to keep beyond the quadrangles' names:
# each run rebuilds every record and writes only the files whose contents changed, and unchanged sources leave the
# repository untouched. What each run fetched is kept in tmp/snapshot, so it can be rerun offline with
# SOURCE=tmp/snapshot. Nothing is written until everything has been fetched and checked.
class Harvester
  METADATA_DIR = 'metadata-aardvark'
  WITHDRAWN_FILE = 'withdrawn.json'
  SNAPSHOT_DIR = 'tmp/snapshot'

  # Index maps' GeoJSON is kept out of metadata-aardvark/ and named .geojson, so that harvesters looking for records
  # don't mistake it for one, and their records say it's where GitHub serves it
  INDEX_MAP_DIR = 'index-maps'
  INDEX_MAP_URL = 'https://raw.githubusercontent.com/OpenGeoMetadata/gov.usda.naip/main/index-maps'

  WITHDRAWALS_SCHEMA = 'https://opengeometadata.org/schema/ogm-withdrawals-1.0.json'

  # Refuse to change anything if a run would shrink the repository, or an index map, by more than this fraction, so
  # that a listing cut short can't empty them. Rerun with FORCE=1 when the drop is real.
  MAX_SHRINK = 0.02

  # An index map losing this many sheets or fewer isn't stopped for it, however small the map
  MIN_SHEET_DROP = 10

  # A pause between requests to each host, in seconds: the STAC API is asked about 1,500 times a run, a page of 1,000
  # tiles at a time, and the image dates' layers about 330 times, once each
  INTERVALS = { 'planetarycomputer.microsoft.com' => 0.2, 'naipeuwest.blob.core.windows.net' => 0.05,
                'services.arcgis.com' => 0.2 }.freeze

  # What leaves the repository when its source stops listing it
  REMOVED = {
    Mapper::INDEX_MAP_PREFIX => 'Planetary Computer no longer lists NAIP tiles for this state and year.',
    Mapper::IMAGE_DATES_PREFIX => "USDA's image dates hub no longer lists this layer.",
    Mapper::IMAGE_SERVICE_ID => 'USDA no longer publishes this image service.'
  }.freeze

  # What a run reads: the snapshot's directory, where Planetary Computer's tiles are read from a state at a time, and
  # USDA's sources
  Sources = Struct.new(:dir, :image_dates, :service, :iso)

  class Error < StandardError; end

  def self.run(**options)
    new(**options).run
  end

  attr_reader :source, :metadata_dir, :index_map_dir, :index_map_url, :withdrawn_file, :snapshot_dir, :states,
              :quadrangles, :dry_run, :force, :max_shrink, :today, :log

  # @param states [Array<String>] the states to ask Planetary Computer about; every state and territory but in tests
  # @param quadrangles [Quadrangles] the quadrangle names, from data/quadrangles.json but in tests
  def initialize(source: nil, metadata_dir: METADATA_DIR, index_map_dir: INDEX_MAP_DIR, index_map_url: INDEX_MAP_URL,
                 withdrawn_file: WITHDRAWN_FILE, snapshot_dir: SNAPSHOT_DIR, states: Places::CODES,
                 quadrangles: nil, dry_run: false, force: false, max_shrink: MAX_SHRINK, today: Date.today,
                 log: $stdout, http: nil)
    @source = source
    @metadata_dir = metadata_dir
    @index_map_dir = index_map_dir
    @index_map_url = index_map_url.chomp('/')
    @withdrawn_file = withdrawn_file
    @snapshot_dir = snapshot_dir
    @states = states
    @quadrangles = quadrangles || Quadrangles.load
    @dry_run = dry_run
    @force = force
    @max_shrink = max_shrink
    @today = today
    @log = log
    @http = http
  end

  # @return [Hash] counts of what the run did
  def run
    sources = source ? load(source) : fetch
    planned = plan(sources.dir)
    counts = Hash.new(0)
    layers = image_date_layers(sources.image_dates, counts)
    existing = existing_records
    published = planned.keys + layers.keys + [Mapper::IMAGE_SERVICE_ID]
    check_complete(planned, layers, existing)
    check_shrinkage(existing.size, published.size)
    check_sheets(planned, existing)

    # The collection's description, USDA's own, stands in for any record's that USDA and Microsoft don't describe
    description = Mapper.description(sources.iso)
    summaries = write_index_maps(sources.dir, description, counts)
    layers.each_value do |layer|
      index_maps = layer.states.map { |state| Mapper.index_map_id(state, layer.year) }.select { |id| planned.key?(id) }
      record = Mapper.image_dates(layer, description: description, index_maps: index_maps)
      counts[:"image_dates_#{write_json(record_path(layer.id), record)}"] += 1
      counts[:image_dates_undescribed] += 1 if layer.description.empty?
      counts[:image_dates_with_index_maps] += 1 if index_maps.any?
      summaries << [layer.bounds, layer.years, layer.modified] if layer.bounds
    end
    service = Mapper.image_service(sources.service, description: description)
    counts[:image_service] = write_json(record_path(Mapper::IMAGE_SERVICE_ID), service)
    summaries << [sources.service['extent'].values_at(0, 2, 3, 1), service['gbl_indexYear_im'].minmax,
                  service['gbl_mdModified_dt']]
    collection = collection_record(sources, summaries)
    counts[:collection] = write_json(record_path(Mapper::COLLECTION_ID), collection)
    counts.merge!(withdraw(removals(existing, published.to_set), published.to_set))

    report(counts)
    counts
  end

  private

  # Fetches USDA's sources and then every state's tiles from Planetary Computer into the snapshot, measuring layers of
  # image dates new to data/image-date-extents.json and reading the names of quadrangles new to data/quadrangles.json,
  # and saves both before anything else is written: they're right whatever the checks find
  def fetch
    http = @http || HttpClient.new(interval: INTERVALS)
    iso = IsoRecord.fetch(snapshot_dir, http: http)
    service = ImageService.fetch(snapshot_dir, http: http, log: log)
    extents = ImageDates::Extents.load
    measurer = HttpClient.new(interval: INTERVALS, timeout: ImageDates::MEASURE_TIMEOUT, retries: 0)
    image_dates = ImageDates.fetch(snapshot_dir, http: http, log: log, extents: extents, measurer: measurer)
    extents.save unless dry_run
    PlanetaryComputer.fetch(snapshot_dir, states: states, http: http, log: log) do |state, rows|
      looked_up = quadrangles.fill(rows.map { |row| Tile.new(row) })
      log.puts "#{state}: read the names of #{looked_up} quadrangles from their FGDC" if looked_up.positive?
    end
    quadrangles.save unless dry_run
    Sources.new(snapshot_dir, image_dates, service, iso)
  end

  def load(dir)
    Sources.new(dir, ImageDates.load(dir), ImageService.load(dir), IsoRecord.load(dir))
  end

  # How many sheets each index map the snapshot makes will have, by id
  def plan(dir)
    planned = {}
    PlanetaryComputer.each_state(dir, states: states) do |_state, rows|
      IndexMap.build(rows.map { |row| Tile.new(row) }).each { |index_map| planned[index_map.id] = index_map.sheets }
    end
    planned
  end

  # The image dates' layers by record id. Should two layers ever make the same id, the one USDA modified last is
  # kept.
  def image_date_layers(rows, counts)
    layers = rows.map { |row| ImageDates::Layer.new(row) }.group_by(&:id)
    counts[:image_dates_duplicates] = layers.sum { |_id, namesakes| namesakes.size - 1 }
    layers.transform_values { |namesakes| namesakes.max_by { |layer| layer.modified.to_s } }
  end

  # Writes every index map, a state at a time
  # @param description [Array<String>] the collection's description
  # @return [Array] each index map's bounds, years and modification date
  def write_index_maps(dir, description, counts)
    summaries = []
    misaligned = []
    PlanetaryComputer.each_state(dir, states: states) do |_state, rows|
      IndexMap.build(rows.map { |row| Tile.new(row) }).each do |index_map|
        counts[:"index_maps_#{write_index_map(index_map, description)}"] += 1
        counts[:sheets] += index_map.sheets
        counts[:twins] += index_map.twins
        counts[:unnamed] += index_map.tiles.count { |tile| !(tile.quadrangle && quadrangles.name(tile.quadrangle)) }
        misaligned.concat(index_map.misaligned.map(&:id))
        summaries << [index_map.bounds, index_map.years, index_map.modified]
      end
    end
    counts[:misaligned] = misaligned.size
    counts[:misaligned_ids] = misaligned.first(10)
    summaries
  end

  # Planetary Computer listing nothing for a state with index maps, or the hub listing no image dates while the
  # repository has some, means a source came back broken, not that its records were taken down
  def check_complete(planned, layers, existing)
    raise Error, 'Planetary Computer lists no NAIP tiles' if planned.empty?

    planned_states = planned.keys.map { |id| state_of(id) }.to_set
    index_maps = existing.keys.select { |id| id.start_with?(Mapper::INDEX_MAP_PREFIX) }
    vanished = index_maps.map { |id| state_of(id) }.uniq.reject { |state| planned_states.include?(state) }
    if vanished.any? && !force
      raise Error, "Planetary Computer lists no tiles for #{vanished.sort.join(', ')}, which have index maps. " \
                   'Nothing was changed; rerun with FORCE=1 if that is real.'
    end
    return unless layers.empty? && existing.keys.any? { |id| id.start_with?(Mapper::IMAGE_DATES_PREFIX) } && !force

    raise Error, "USDA's image dates hub lists no layers. Nothing was changed; rerun with FORCE=1 if that is real."
  end

  def check_shrinkage(existing_count, kept_count)
    return if force || existing_count.zero? || kept_count >= existing_count * (1 - max_shrink)

    raise Error, "This run would leave #{kept_count} records, down from #{existing_count}: more than " \
                 "#{(max_shrink * 100).round}% fewer. Nothing was changed; rerun with FORCE=1 if the drop is real."
  end

  # An index map that would lose more than MAX_SHRINK of its sheets, and more than MIN_SHEET_DROP, stops the run
  def check_sheets(planned, existing)
    return if force

    shrunk = planned.filter_map do |id, sheets|
      path = index_map_path(id)
      next unless existing.key?(id) && File.exist?(path)

      # One sheet to a line, between the collection's opening and closing lines
      before = File.foreach(path).count - 2
      "#{id} (#{before} to #{sheets})" if before - sheets > [before * max_shrink, MIN_SHEET_DROP].max
    end
    return if shrunk.empty?

    raise Error, "These index maps would lose more than #{(max_shrink * 100).round}% of their sheets: " \
                 "#{shrunk.join(', ')}. Nothing was changed; rerun with FORCE=1 if the drop is real."
  end

  # usda-naip-index-ri-2018 -> ri
  def state_of(id)
    id.delete_prefix(Mapper::INDEX_MAP_PREFIX).split('-').first
  end

  # Index maps' and image dates' records are kept in directories of their own, beside the collection record and the
  # image service's
  def record_path(id)
    directory = { Mapper::INDEX_MAP_PREFIX => 'index-maps', Mapper::IMAGE_DATES_PREFIX => 'image-dates' }
                .find { |prefix, _directory| id.start_with?(prefix) }&.last
    File.join(*[metadata_dir, directory, "#{id}.json"].compact)
  end

  def index_map_path(id)
    File.join(index_map_dir, "#{id}.geojson")
  end

  # Every record currently in the repository but the collection's, by id
  def existing_records
    Dir.glob(File.join(metadata_dir, '**', "#{Mapper::COLLECTION_ID}-*.json")).to_h do |path|
      [File.basename(path, '.json'), path]
    end
  end

  # Writes an index map's GeoJSON, and the record that points to it
  # @param description [Array<String>] the collection's description
  # @return [Symbol] :created, :updated, or :unchanged, for whichever of the two changed most
  def write_index_map(index_map, description)
    geojson = index_map.geojson(quadrangles)
    record = index_map.record("#{index_map_url}/#{File.basename(index_map_path(index_map.id))}", geojson.bytesize,
                              description: description)
    statuses = [write_file(index_map_path(index_map.id), geojson), write_json(record_path(index_map.id), record)]
    %i[created updated unchanged].find { |status| statuses.include?(status) }
  end

  # @param summaries [Array] each member's bounds, years and modification date
  def collection_record(sources, summaries)
    extent = Extent.new
    summaries.each { |bounds, _years, _modified| extent.add(*bounds) }
    west, east = extent.longitudes
    years = summaries.flat_map { |_bounds, span, _modified| span }
    Mapper.collection(iso: sources.iso, west: west, east: east, north: extent.north, south: extent.south,
                      first_year: years.min, last_year: years.max, modified: summaries.filter_map(&:last).max,
                      service_url: sources.service['url'])
  end

  def write_json(path, data)
    write_file(path, "#{JSON.pretty_generate(data)}\n")
  end

  # Writes the file only when its contents change, so unchanged records don't show up in git
  # @return [Symbol] :created, :updated, or :unchanged
  def write_file(path, content)
    exists = File.exist?(path)
    return :unchanged if exists && File.read(path, mode: 'r:bom|utf-8') == content

    unless dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content, mode: 'w:utf-8')
    end
    exists ? :updated : :created
  end

  # The records leaving the repository, each with its withdrawal entry and the files to delete: an index map's
  # GeoJSON goes with its record
  def removals(existing, published)
    existing.reject { |id, _path| published.include?(id) }.sort.map do |id, path|
      note = REMOVED.find { |prefix, _note| id.start_with?(prefix) }&.last
      entry = { 'id' => id, 'date' => today.iso8601, 'reason' => 'upstream-removed', 'note' => note }.compact
      paths = id.start_with?(Mapper::INDEX_MAP_PREFIX) ? [path, index_map_path(id)] : [path]
      [entry, paths]
    end
  end

  # Records that leave the repository are deleted and logged in withdrawn.json, following the proposed
  # OpenGeoMetadata withdrawal convention: deleting a file alone doesn't tell harvesters to delete the record.
  # Entries are only ever removed for records that have come back.
  # @param published [Set] the id of every record the repository now has
  def withdraw(removals, published)
    withdrawals = read_withdrawals
    republished, entries = withdrawals['withdrawn'].partition { |entry| published.include?(entry['id']) }

    removals.each do |entry, paths|
      entries = entries.reject { |other| other['id'] == entry['id'] } << entry
      paths.each { |path| File.delete(path) if File.exist?(path) } unless dry_run
    end

    if !dry_run && (removals.any? || republished.any?)
      content = JSON.pretty_generate(withdrawals.merge('withdrawn' => entries))
      File.write(withdrawn_file, "#{content}\n", mode: 'w:utf-8')
    end
    { withdrawn: removals.size, republished: republished.size }
  end

  def read_withdrawals
    unless File.exist?(withdrawn_file)
      return { '$schema' => WITHDRAWALS_SCHEMA, 'ogm_version' => '1.0', 'withdrawn' => [] }
    end

    JSON.parse(File.read(withdrawn_file, mode: 'r:bom|utf-8'))
  end

  def report(counts)
    log.puts "Index maps: #{counts[:index_maps_created]} created, #{counts[:index_maps_updated]} updated, " \
             "#{counts[:index_maps_unchanged]} unchanged"
    log.puts "Sheets: #{counts[:sheets]}, #{counts[:unnamed]} labeled by code for want of a quadrangle name; " \
             "#{counts[:twins]} tiles skipped as earlier processings of another"
    if counts[:misaligned].positive?
      log.puts "Outlined by their footprints, since their codes don't place them: #{counts[:misaligned]} tiles " \
               "(#{counts[:misaligned_ids].join(', ')}#{', ...' if counts[:misaligned] > 10})"
    end
    log.puts "Image dates: #{counts[:image_dates_created]} created, #{counts[:image_dates_updated]} updated, " \
             "#{counts[:image_dates_unchanged]} unchanged; #{counts[:image_dates_duplicates]} duplicate layers " \
             "skipped; #{counts[:image_dates_undescribed]} without a description of their own; " \
             "#{counts[:image_dates_with_index_maps]} with an index map as their source"
    log.puts "Image service record #{counts[:image_service]}; collection record #{counts[:collection]}"
    log.puts "Withdrawn: #{counts[:withdrawn]}; republished: #{counts[:republished]}"
    log.puts 'Dry run: nothing was written' if dry_run
  end
end

if __FILE__ == $0
  # Report progress as it happens, rather than all at the end, when the log is a file or GitHub's
  $stdout.sync = true
  begin
    Harvester.run(source: ENV['SOURCE'].to_s.empty? ? nil : ENV['SOURCE'], dry_run: !ENV['DRY_RUN'].to_s.empty?,
                  force: !ENV['FORCE'].to_s.empty?,
                  index_map_url: ENV['INDEX_MAP_URL'].to_s.empty? ? Harvester::INDEX_MAP_URL : ENV['INDEX_MAP_URL'])
  rescue Harvester::Error, PlanetaryComputer::Error, ImageDates::Error, ImageService::Error, IsoRecord::Error,
         Snapshot::Error, HttpClient::Error => e
    warn "Harvest stopped: #{e.message}"
    exit 1
  end
end
