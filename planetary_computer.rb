require 'json'
require 'net/http'
require 'uri'
require_relative 'http_client'
require_relative 'places'
require_relative 'snapshot'
require_relative 'tile'

# Every NAIP tile Planetary Computer's STAC API lists, fetched a state at a time into a snapshot: one file per state,
# so that a run holds only one state's tiles at once. The API counts nothing, so a state's tiles are paged through
# until there's no next page.
module PlanetaryComputer
  SEARCH_URL = 'https://planetarycomputer.microsoft.com/api/stac/v1/search'
  COLLECTION = 'naip'
  PAGE_SIZE = 1000

  # The parts of each item the snapshot keeps (see Tile.row), which make a page a fifth the size of whole items
  FIELDS = %w[id bbox _msft:ts properties.datetime properties.naip:state properties.naip:year properties.proj:epsg
              assets.image.href assets.thumbnail.href assets.metadata.href].freeze

  class Error < StandardError; end

  def self.file(state)
    "naip-#{state}.jsonl"
  end

  # Fetches each state's tiles and saves them in the snapshot, yielding them as each state is done. A state NAIP
  # doesn't cover gets an empty file, so that a snapshot shows every state was asked about.
  def self.fetch(dir, states: Places::CODES, http: HttpClient.new, log: $stdout)
    states.each do |state|
      rows = fetch_state(http, state)
      log.puts "#{state}: #{rows.size} tiles" if rows.any?
      Snapshot.write(dir, file(state), rows)
      yield state, rows if block_given?
    end
  end

  # Each state's tiles from a snapshot, as rows. A state missing from it raises Snapshot::Error.
  def self.each_state(dir, states: Places::CODES)
    states.each { |state| yield state, Snapshot.read(dir, file(state)) }
  end

  # @return [Array<Hash>] the state's tiles as snapshot rows, without repeats
  def self.fetch_state(http, state)
    params = { 'collections' => COLLECTION, 'filter-lang' => 'cql2-text', 'filter' => "\"naip:state\" = '#{state}'",
               'limit' => PAGE_SIZE, 'fields' => FIELDS.join(',') }
    url = "#{SEARCH_URL}?#{URI.encode_www_form(params)}"
    rows = {}
    while url
      page = request(http, url)
      page['features'].each do |item|
        row = Tile.row(item)
        raise Error, "#{state}: an item lists naip:state #{row['state'].inspect}" unless row['state'] == state

        rows[row['id']] = row
      end
      url = page['features'].empty? ? nil : next_url(page)
    end
    rows.values
  end

  def self.next_url(page)
    (page['links'] || []).find { |link| link['rel'] == 'next' }&.dig('href')
  end

  def self.request(http, url)
    response = http.get(url)
    raise Error, "#{url} answered #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    page = JSON.parse(response.body.to_s)
    raise Error, "#{url} answered without a list of items" unless page.is_a?(Hash) && page['features'].is_a?(Array)

    page
  rescue JSON::ParserError
    raise Error, "#{url} answered with something other than JSON"
  end
end
