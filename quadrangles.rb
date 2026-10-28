require 'fileutils'
require 'json'
require 'net/http'
require_relative 'planetary_computer'
require_relative 'http_client'
require_relative 'tile'

# USGS's names for the 7.5-minute quadrangles NAIP's tiles quarter, which label the sheets of the index maps:
# Wickford NW, rather than m_4107129_nw. A tile's name is only in its FGDC metadata, which Planetary Computer has
# for 2011 to 2019, as a place keyword: "WICKFORD, NW".
#
# A quadrangle keeps its name from year to year, so each quadrangle's name is read once, from one of its tiles'
# FGDC, and kept in data/quadrangles.json, where tiles from years without FGDC find it too. The harvester reads
# the FGDC of quadrangles new to the file after each state's tiles are fetched, and `ruby quadrangles.rb` does the
# same for a snapshot. A quadrangle whose FGDC was read but names nothing is kept as null, so it isn't read again.
class Quadrangles
  FILE = File.join(__dir__, 'data', 'quadrangles.json')

  # FGDC files are small and the storage account answers quickly, so they're read several at a time
  THREADS = 8

  # Quadrangle names are capitals in the FGDC. Ocean extensions, the sheets USGS adds offshore (Kingston OE S),
  # and the compass points that tell sheets of a name apart (Dallas NE) keep theirs.
  CAPITALS = %w[OE N S E W NE NW SE SW].freeze
  SMALL_WORDS = %w[of and the on in at by].freeze

  def self.load(file = FILE)
    new(File.exist?(file) ? JSON.parse(File.read(file, mode: 'r:bom|utf-8')) : {}, file)
  end

  # The quadrangle's name from a tile's FGDC: the place keyword naming the tile's quarter, e.g.
  # "Place_Keyword: WICKFORD, NW"; nil if there's none
  def self.parse(text, quarter)
    keyword = text.scan(/^\s*Place_Keyword:\s*(.+?)\s*$/).flatten
                  .find { |candidate| candidate.match?(/,\s*#{quarter}\z/i) }
    keyword && title_case(keyword.sub(/\s*,\s*[NS][EW]\z/i, ''))
  end

  # WICKFORD -> Wickford; KINGSTON OE S -> Kingston OE S; MCALLEN -> McAllen; WILKES-BARRE -> Wilkes-Barre
  def self.title_case(name)
    name.split.each_with_index.map do |word, index|
      if index.positive? && CAPITALS.include?(word) then word
      elsif index.positive? && SMALL_WORDS.include?(word.downcase) then word.downcase
      else
        word.downcase.gsub(/(\A|[-'(])([a-z])/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).upcase}" }
            .sub(/\AMc([a-z])/) { "Mc#{Regexp.last_match(1).upcase}" }
      end
    end.join(' ')
  end

  attr_reader :file

  def initialize(names, file = FILE)
    @names = names
    @file = file
    @added = 0
  end

  # The quadrangle's name, or nil if it has none here
  def name(quadrangle)
    @names[quadrangle]
  end

  def size
    @names.size
  end

  # Reads the name of each quadrangle among the tiles that the file has nothing on, from the FGDC of one of its
  # tiles, the latest that has one
  # @return [Integer] how many quadrangles were looked up
  def fill(tiles, http_factory: -> { HttpClient.new(interval: 0.05) })
    sources = tiles.select { |tile| tile.quadrangle && tile.fgdc_url && !@names.key?(tile.quadrangle) }
                   .group_by(&:quadrangle).transform_values { |candidates| candidates.max_by(&:year) }
    return 0 if sources.empty?

    queue = Queue.new
    sources.each_value { |tile| queue << tile }
    queue.close
    found = {}
    lock = Mutex.new
    Array.new([THREADS, sources.size].min) do
      Thread.new do
        http = http_factory.call
        while (tile = queue.pop)
          name = read(http, tile)
          lock.synchronize { found[tile.quadrangle] = name } unless name == :unread
        end
      end
    end.each(&:join)
    @names.merge!(found)
    @added += found.size
    sources.size
  end

  # Writes the file if names were added, one quadrangle to a line in order, so that new names are new lines
  # @return [Boolean] whether it was written
  def save
    return false if @added.zero?

    lines = @names.sort.map { |quadrangle, name| "  #{quadrangle.to_json}: #{name.to_json}" }
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "{\n#{lines.join(",\n")}\n}\n", mode: 'w:utf-8')
    @added = 0
    true
  end

  private

  # The quadrangle's name from the tile's FGDC, nil if the FGDC names none, or :unread if it couldn't be read, so
  # that a later run tries again
  def read(http, tile)
    response = http.get(tile.fgdc_url)
    return :unread unless response.is_a?(Net::HTTPSuccess)

    self.class.parse(text(response.body), tile.quarter)
  rescue HttpClient::Error
    :unread
  end

  # NAIP's FGDC is ASCII, or Latin-1 for the odd accented name
  def text(body)
    utf8 = body.to_s.dup.force_encoding(Encoding::UTF_8)
    utf8.valid_encoding? ? utf8 : body.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
  end
end

if __FILE__ == $0
  $stdout.sync = true
  dir = ARGV.first || 'tmp/snapshot'
  quadrangles = Quadrangles.load
  PlanetaryComputer.each_state(dir) do |state, rows|
    looked_up = quadrangles.fill(rows.map { |row| Tile.new(row) })
    puts "#{state}: looked up #{looked_up} quadrangles" if looked_up.positive?
  end
  puts quadrangles.save ? "#{Quadrangles::FILE}: #{quadrangles.size} quadrangles" : 'No quadrangles to add'
end
