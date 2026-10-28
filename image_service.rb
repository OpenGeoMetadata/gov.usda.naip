require 'json'
require 'net/http'
require 'uri'
require_relative 'http_client'
require_relative 'snapshot'

# USDA's image service of the latest NAIP imagery of each state, which replaces a state's imagery when NAIP flies it
# again. It draws the imagery for viewing and analysis, but doesn't offer it for download. Its catalog of tiles is
# summarized with one statistics query: how many tiles of each state and year it has, and when the last was added.
module ImageService
  URL = 'https://apps.geo.fpac.usda.gov/geo-imagery/rest/services/naip/conus_naip/ImageServer'
  FILE = 'image-service.jsonl'

  class Error < StandardError; end

  # @return [Hash] the service, as the snapshot's row
  def self.fetch(dir, http: HttpClient.new, log: $stdout)
    service = request(http, "#{URL}?f=json")
    extent = service['extent'] || {}
    row = {
      'url' => URL, 'bands' => service['bandCount'],
      'extent' => %w[xmin ymin xmax ymax].map { |key| extent[key] },
      'groups' => statistics(http)
    }
    log.puts "Image service: #{row['groups'].sum { |group| group['tiles'] }} tiles"
    Snapshot.write(dir, FILE, [row])
    row
  end

  def self.load(dir)
    Snapshot.read(dir, FILE).first or raise Snapshot::Error, "No image service in the snapshot at #{dir}"
  end

  # The tiles of each state and year, and when the last was added. Tiles without a year are overviews, which draw the
  # imagery at small scales.
  def self.statistics(http)
    stats = [%w[count OBJECTID tiles], %w[max iDate_ts added]]
    params = {
      'where' => 'year_ts IS NOT NULL', 'groupByFieldsForStatistics' => 'year_ts,ST', 'f' => 'json',
      'outStatistics' => JSON.generate(stats.map do |type, field, name|
        { 'statisticType' => type, 'onStatisticField' => field, 'outStatisticFieldName' => name }
      end)
    }
    page = request(http, "#{URL}/query?#{URI.encode_www_form(params)}")
    page['features'].map do |feature|
      values = feature['attributes']
      { 'year' => values['year_ts'], 'state' => values['ST'].to_s.strip.downcase, 'tiles' => values['tiles'],
        'added' => instant(values['added']) }
    end
  end

  # ArcGIS dates are milliseconds since 1970, in UTC
  def self.instant(milliseconds)
    milliseconds && Time.at(milliseconds / 1000, in: 'UTC').strftime('%Y-%m-%dT%H:%M:%SZ')
  end

  def self.request(http, url)
    response = http.get(url)
    raise Error, "#{url} answered #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    page = JSON.parse(response.body.to_s)
    raise Error, "#{url} answered #{page.dig('error', 'code')} #{page.dig('error', 'message')}" if page['error']

    page
  rescue JSON::ParserError
    raise Error, "#{url} answered with something other than JSON"
  end
end
