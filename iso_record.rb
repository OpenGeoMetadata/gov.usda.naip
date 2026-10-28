require 'json'
require 'net/http'
require 'rexml/document'
require_relative 'http_client'
require_relative 'snapshot'

# USDA's ISO 19115-2 metadata for NAIP as a whole, which the collection record takes its title and description from,
# and links to. It's kept in the snapshot as fetched.
class IsoRecord
  URL = 'https://geodata.nal.usda.gov/geonetwork/srv/api/records/e2442795-2136-424f-afd1-291397b51c3d/formatters/xml'
  FILE = 'iso.jsonl'
  NAMESPACES = { 'gmd' => 'http://www.isotc211.org/2005/gmd', 'gco' => 'http://www.isotc211.org/2005/gco',
                 'gml' => 'http://www.opengis.net/gml/3.2' }.freeze

  class Error < StandardError; end

  def self.fetch(dir, http: HttpClient.new)
    response = http.get(URL)
    raise Error, "#{URL} answered #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

    xml = response.body.to_s.dup.force_encoding(Encoding::UTF_8)
    record = new(xml)
    raise Error, "#{URL} has no title" unless record.title

    Snapshot.write(dir, FILE, [{ 'url' => URL, 'xml' => xml }])
    record
  rescue REXML::ParseException => e
    raise Error, "#{URL} answered with something other than ISO metadata: #{e.message.lines.first&.strip}"
  end

  def self.load(dir)
    row = Snapshot.read(dir, FILE).first or raise Snapshot::Error, "No ISO record in the snapshot at #{dir}"
    new(row['xml'])
  end

  def initialize(xml)
    @document = REXML::Document.new(xml)
  end

  def url
    URL
  end

  # National Agriculture Imagery Program (NAIP) Imagery
  def title
    text('//gmd:identificationInfo//gmd:citation//gmd:title')
  end

  def abstract
    text('//gmd:identificationInfo//gmd:abstract')
  end

  def purpose
    text('//gmd:identificationInfo//gmd:purpose')
  end

  # The year NAIP's extent begins, 2002
  def first_year
    REXML::XPath.first(@document, '//gml:beginPosition', NAMESPACES)&.text.to_s[/\A\d{4}/]&.to_i
  end

  private

  # An element's text, with its line breaks and runs of spaces closed up
  def text(path)
    element = REXML::XPath.first(@document, "#{path}/gco:CharacterString", NAMESPACES)
    value = element&.text.to_s.gsub(/\s+/, ' ').strip
    value.empty? ? nil : value
  end
end
