require 'cgi/escape'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require_relative 'http_client'
require_relative 'places'
require_relative 'snapshot'

# USDA's image dates: for each state and year, a hosted feature layer with a polygon for each exposure the NAIP
# imagery was made from, giving the day and time it was flown and the camera and aircraft that flew it. USDA lists
# them in the DCAT feed of its NAIP image dates hub, with a description of each, and each layer is summarized with
# one statistics query: how many polygons were flown on each day, which says what years the layer covers.
#
# The feed's box for a layer isn't always where its polygons are: 2024 Idaho's reaches 51°N and misses western Idaho.
# So each layer's polygons are measured, and kept in data/image-date-extents.json until USDA modifies the layer.
# ArcGIS gives up measuring the biggest layers, like 2024 Texas's 22,634 polygons, after almost a minute, so a
# measurement that takes longer than MEASURE_TIMEOUT is abandoned, and the layer keeps the feed's box.
module ImageDates
  FEED_URL = 'https://naip-image-dates-usdaonline.hub.arcgis.com/api/feed/dcat-us/1.1.json'
  FILE = 'image-dates.jsonl'
  EXTENTS_FILE = File.join(__dir__, 'data', 'image-date-extents.json')
  MEASURE_TIMEOUT = 15

  # 2012's layer covers every state flown that year, and says which in a field of its own
  STATE_FIELD = 'State'

  class Error < StandardError; end

  # Every layer the feed lists, each with its statistics and the extent of its polygons
  # @param extents [Extents] the layers' measured extents
  # @param measurer [#get] the client that measures them, which gives up after MEASURE_TIMEOUT
  # @return [Array<Hash>] the layers, as snapshot rows
  def self.fetch(dir, http: HttpClient.new, log: $stdout, extents: Extents.load,
                 measurer: HttpClient.new(timeout: MEASURE_TIMEOUT, retries: 0))
    listed = layers(request(http, FEED_URL))
    rows = listed.each_with_index.filter_map do |layer, index|
      # Measuring every layer the first time takes about half an hour, so say how far it's got
      log.puts "Image dates: #{index} of #{listed.size} layers" if index.positive? && (index % 50).zero?
      groups = statistics(http, layer)
      next log.puts("Image dates: #{layer['title']} (#{layer['service']}) can't be queried, so it's left out") unless groups

      layer.merge('groups' => groups, 'extent' => extents.fetch(layer) { extent(measurer, layer) }).compact
    end
    log.puts "Image dates: #{rows.size} layers, #{extents.measured} newly measured"
    Snapshot.write(dir, FILE, rows)
    rows
  end

  # Each layer's measured extent, by its service, with the modification date it was measured at. A layer that
  # couldn't be measured is kept with a null extent, so it isn't tried again until USDA modifies it.
  class Extents
    attr_reader :measured

    def self.load(file = EXTENTS_FILE)
      new(File.exist?(file) ? JSON.parse(File.read(file, mode: 'r:bom|utf-8')) : {}, file)
    end

    def initialize(entries, file = EXTENTS_FILE)
      @entries = entries
      @file = file
      @measured = 0
    end

    # The layer's extent, measured by the block unless it was measured since USDA last modified the layer; nil if it
    # couldn't be
    def fetch(layer)
      entry = @entries[layer['service']]
      return entry['extent'] if entry && entry['modified'] == layer['modified']

      extent = yield
      @measured += 1
      @entries[layer['service']] = { 'modified' => layer['modified'], 'extent' => extent }
      extent
    end

    # Writes the file if layers were measured, one to a line in order
    def save
      return false if @measured.zero?

      lines = @entries.sort.map { |service, entry| "  #{service.to_json}: #{JSON.generate(entry)}" }
      FileUtils.mkdir_p(File.dirname(@file))
      File.write(@file, "{\n#{lines.join(",\n")}\n}\n", mode: 'w:utf-8')
      @measured = 0
      true
    end
  end

  def self.load(dir)
    Snapshot.read(dir, FILE)
  end

  # The feed's datasets that are layers of image dates, as snapshot rows without their statistics and extents. Left
  # out: the multi-layer services of 2011, 2013, 2014 and 2015, whose layers are listed one by one too, and anything
  # that isn't a feature layer, like 2022 New Jersey's, which is a folder on Box.
  def self.layers(feed)
    (feed['dataset'] || []).filter_map do |dataset|
      service = distribution(dataset, 'ArcGIS GeoServices REST API')
      next unless service&.match?(%r{/FeatureServer/\d+\z})

      year = dataset['title'].to_s[/\b(20\d\d)\b/, 1]
      next unless year

      {
        'item' => dataset['identifier'].to_s[/[?&]id=(\h+)/, 1], 'title' => dataset['title'].strip,
        'states' => Places.codes_in(dataset['title']), 'year' => year.to_i, 'service' => service,
        'landing' => dataset['landingPage'], 'geojson' => distribution(dataset, 'GeoJSON'),
        'csv' => distribution(dataset, 'CSV'), 'bbox' => bbox(dataset['spatial']),
        'issued' => dataset['issued'], 'modified' => dataset['modified'],
        'description' => paragraphs(dataset['description']), 'license' => text(dataset['license'])
      }.compact.reject { |key, value| key == 'description' && value.empty? }
    end
  end

  def self.distribution(dataset, format)
    found = (dataset['distribution'] || []).find { |distribution| distribution['format'] == format }
    found && (found['accessURL'] || found['downloadURL'])
  end

  # "-71.9524,41.1145,-71.0484,42.0731" -> [west, south, east, north]
  def self.bbox(spatial)
    values = spatial.to_s.split(',').map { |value| Float(value, exception: false) }
    values.size == 4 && values.none?(&:nil?) ? values : nil
  end

  # The paragraphs of the feed's HTML as plain text, as USDA wrote them: its paragraphs, headings and list items, each
  # with its runs of spaces closed up
  def self.paragraphs(html)
    html.to_s.gsub(%r{<br\s*/?>|</?(p|div|li|ul|ol|h[1-6])\b[^>]*>}i, "\n").gsub(/<[^>]+>/, '').gsub('&nbsp;', ' ')
        .then { |plain| CGI.unescapeHTML(plain) }.tr("\u00a0", ' ').split("\n")
        .map { |line| line.gsub(/\s+/, ' ').strip }.reject(&:empty?)
  end

  # The feed's HTML as one paragraph of plain text
  def self.text(html)
    lines = paragraphs(html)
    lines.empty? ? nil : lines.join(' ')
  end

  # How many polygons were flown on each day, in each state for the 2012 layer
  # @return [Array<Array>] [date, state, count] for each group; nil if the layer can't be queried
  def self.statistics(http, layer, sleeper: method(:sleep))
    by_state = layer['states'].empty?
    fields = %w[IDATE] + (by_state ? [STATE_FIELD] : [])
    params = { 'where' => '1=1', 'groupByFieldsForStatistics' => fields.join(','), 'f' => 'json',
               'outStatistics' => JSON.generate([{ 'statisticType' => 'count', 'onStatisticField' => 'IDATE',
                                                   'outStatisticFieldName' => 'polygons' }]) }
    page = query(http, "#{layer['service']}/query?#{URI.encode_www_form(params)}", sleeper: sleeper)
    return nil unless page

    page['features'].map do |feature|
      values = feature['attributes']
      [values['IDATE'], by_state ? values[STATE_FIELD] : nil, values['polygons']]
        .map { |value| value.is_a?(String) ? value.strip : value }
    end
  end

  # ArcGIS answers a failed query with 200 and an error in the JSON: a 400 for a layer that can't answer it, which
  # is final, or a 500 when it's busy, which is worth asking again about
  # @return [Hash, nil] the answer, or nil for a layer that can't be queried
  def self.query(http, url, attempts: 3, sleeper: method(:sleep))
    attempts.times do |attempt|
      page = request(http, url)
      code = page.dig('error', 'code').to_i
      return page unless page['error']
      return nil if code.between?(400, 499)
      raise Error, "#{url} answered #{code} #{page.dig('error', 'message')}" if attempt == attempts - 1

      sleeper.call(2**attempt)
    end
  end

  # One layer of image dates, from its snapshot row
  class Layer
    PREFIX = 'usda-naip-dates-'

    attr_reader :row

    def initialize(row)
      @row = row
    end

    # e.g. usda-naip-dates-ri-2021, usda-naip-dates-pr-vi-2021, or usda-naip-dates-2012 for a layer of every state
    def id
      "#{PREFIX}#{(row['states'] + [year]).join('-')}"
    end

    def year
      row['year']
    end

    # The states the layer covers: those its title names, or for 2012's, those its polygons name
    def states
      return row['states'] unless national?

      groups.map { |group| group[1] }.compact.flat_map { |state| Places.codes_in(state) }.uniq.sort
    end

    # Whether the layer covers every state flown that year rather than the ones its title names
    def national?
      row['states'].empty?
    end

    def title
      row['title']
    end

    # The first and last days flown, as YYYY-MM-DD; nil when no polygon has a date
    def dates
      days = groups.map(&:first).grep(/\A\d{4}-\d{2}-\d{2}\z/)
      days.empty? ? nil : days.minmax
    end

    # The year of the imagery, and the years it was flown, which can run into the next
    def years
      ([year] + (dates || []).map { |day| day[0, 4].to_i }).minmax
    end

    # USDA's description of the layer, a paragraph to an entry; empty for the few it gave none
    def description
      row['description'] || []
    end

    # [west, east, north, south] of the polygons, or failing that the feed's box
    def bounds
      box = row['extent'] || row['bbox']
      west, south, east, north = box
      box && [west, east, north, south]
    end

    def modified
      row['modified'] && "#{row['modified'][0, 19]}Z"
    end

    def groups
      row['groups'] || []
    end
  end

  # [west, south, east, north] of the layer's polygons; nil if the layer can't be measured in time
  def self.extent(http, layer)
    params = { 'where' => '1=1', 'returnExtentOnly' => 'true', 'outSR' => '4326', 'f' => 'json' }
    extent = query(http, "#{layer['service']}/query?#{URI.encode_www_form(params)}", attempts: 1)&.dig('extent')
    values = extent && %w[xmin ymin xmax ymax].map { |key| extent[key] }
    values&.all?(Numeric) ? values.map { |value| value.round(6) } : nil
  rescue HttpClient::Error, Error
    nil
  end

  def self.request(http, url)
    response = http.get(url)
    raise Error, "#{url} answered #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise Error, "#{url} answered with something other than JSON"
  end
end
