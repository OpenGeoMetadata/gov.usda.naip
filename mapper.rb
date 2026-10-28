require 'json'
require 'set'
require_relative 'places'

# Builds the OGM Aardvark records: the collection record for NAIP; an index map of the tiles Microsoft's Planetary
# Computer hosts for each state and year; a record of USDA's image dates for each state and year; and a record of
# USDA's image service of the latest imagery.
#
# Descriptions are only ever USDA's or Microsoft's own words, never written here. The collection's is USDA's
# abstract and purpose of NAIP, and each layer of image dates has USDA's description of it; every record USDA and
# Microsoft give no description of their own repeats the collection's.
class Mapper
  COLLECTION_ID = 'usda-naip'
  INDEX_MAP_PREFIX = "#{COLLECTION_ID}-index-".freeze
  IMAGE_DATES_PREFIX = "#{COLLECTION_ID}-dates-".freeze
  IMAGE_SERVICE_ID = "#{COLLECTION_ID}-latest".freeze

  # The index maps point at what Planetary Computer hosts, so it provides them; USDA provides everything else
  PLANETARY_COMPUTER = 'Microsoft Planetary Computer'
  USDA = 'U.S. Department of Agriculture'

  HUB_URL = 'https://naip-usdaonline.hub.arcgis.com/'
  DATASET_URL = 'https://planetarycomputer.microsoft.com/dataset/naip'

  OPENINDEXMAPS = 'https://openindexmaps.org'
  DOWNLOAD = 'http://schema.org/downloadUrl'
  WEB_PAGE = 'http://schema.org/url'
  THUMBNAIL = 'http://schema.org/thumbnailUrl'
  ISO = 'http://www.isotc211.org/schemas/2005/gmd/'
  FEATURE_LAYER = 'urn:x-esri:serviceType:ArcGIS#FeatureLayer'
  IMAGE_MAP_LAYER = 'urn:x-esri:serviceType:ArcGIS#ImageMapLayer'

  # The Library of Congress name heading for USDA's Farm Service Agency, whose program NAIP is
  FSA = 'United States. Farm Service Agency'

  KEYWORDS = ['National Agriculture Imagery Program', 'Orthoimagery'].freeze

  # USDA's ISO metadata for NAIP: "The Farm Production and Conservation Business Center (FPAC-BC) Geospatial
  # Enterprise Operations (GEO) Branch asks to be credited for derived products." Its FGDC for 2011 to 2019 named the
  # branch's predecessor, the Aerial Photography Field Office.
  CREDIT = "USDA's Farm Production and Conservation Business Center asks to be credited in derived products."
  RIGHTS = "NAIP imagery is in the U.S. Public Domain. #{CREDIT}".freeze
  PUBLIC_DOMAIN_MARK = 'https://creativecommons.org/publicdomain/mark/1.0/'

  # Index maps are generated here rather than by USDA or Microsoft, so they carry this repository's own license
  INDEX_MAP_RIGHTS = 'This index map is dedicated to the public domain under CC0 1.0. The imagery it outlines is in ' \
                     "the U.S. Public Domain. #{CREDIT}".freeze
  CC0 = 'https://creativecommons.org/publicdomain/zero/1.0/'

  # The image service's mosaic of the conterminous United States, a small picture of the latest imagery
  def self.thumbnail(service_url)
    "#{service_url}/exportImage?bbox=-125,24,-66,50&bboxSR=4326&imageSR=3857&size=600,300&format=jpg&f=image"
  end

  # e.g. usda-naip-index-ri-2018, the index map of Rhode Island's tiles from 2018
  def self.index_map_id(state, year)
    "#{INDEX_MAP_PREFIX}#{state}-#{year}"
  end

  # USDA's description of NAIP, from its ISO metadata: the abstract and purpose
  def self.description(iso)
    [iso.abstract, iso.purpose].compact
  end

  # The collection record, from USDA's ISO metadata. Its extent, years and modification date summarize its members',
  # so it only changes when they do.
  # @param iso [IsoRecord]
  def self.collection(iso:, west:, east:, north:, south:, first_year:, last_year:, modified:, service_url:)
    envelope = format_envelope(west, east, north, south)
    first_year = [iso.first_year, first_year].compact.min
    compact(
      'id' => COLLECTION_ID,
      'dct_title_s' => iso.title,
      'dct_description_sm' => description(iso),
      'dct_creator_sm' => [FSA],
      'dct_publisher_sm' => [FSA],
      'schema_provider_s' => USDA,
      'dct_temporal_sm' => [[first_year, last_year].uniq.join('-')],
      'gbl_indexYear_im' => (first_year..last_year).to_a,
      'gbl_dateRange_drsim' => ["[#{first_year} TO #{last_year}]"],
      'dct_spatial_sm' => ['United States'],
      'dct_language_sm' => ['eng'],
      'gbl_resourceClass_sm' => %w[Collections Imagery],
      'gbl_resourceType_sm' => ['Aerial photographs'],
      'dcat_theme_sm' => ['Imagery'],
      'dcat_keyword_sm' => KEYWORDS,
      'locn_geometry' => envelope,
      'dcat_bbox' => envelope,
      'dct_rights_sm' => [RIGHTS],
      'dct_license_sm' => [PUBLIC_DOMAIN_MARK],
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => modified,
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => {
        WEB_PAGE => HUB_URL,
        ISO => iso.url,
        THUMBNAIL => thumbnail(service_url)
      }.to_json
    )
  end

  # The record for one index map: a state's tiles from one year, as Planetary Computer hosts them. Like the collection
  # record, it summarizes its tiles, so it only changes when they do.
  # @param index_map [IndexMap]
  # @param url [String] where the index map's GeoJSON is published
  # @param bytes [Integer] the GeoJSON's size
  # @param description [Array<String>] the collection's description: neither USDA nor Microsoft describes an index map
  def self.index_map(index_map, url:, bytes:, description:)
    envelope = format_envelope(*index_map.bounds)
    years = index_map.years
    compact(
      'id' => index_map.id,
      'dct_title_s' => "Index to NAIP Aerial Imagery of #{Places.phrase(index_map.state)}, #{index_map.year}",
      'dct_description_sm' => description,
      'dct_creator_sm' => [FSA],
      'dct_publisher_sm' => [FSA],
      'schema_provider_s' => PLANETARY_COMPUTER,
      'dct_temporal_sm' => [[years.first, years.last].uniq.join('-')],
      'gbl_indexYear_im' => (years.first..years.last).to_a,
      'gbl_dateRange_drsim' => ["[#{years.first} TO #{years.last}]"],
      'dct_spatial_sm' => [Places.name(index_map.state)],
      'dct_language_sm' => ['eng'],
      'gbl_resourceClass_sm' => %w[Maps Imagery],
      'gbl_resourceType_sm' => ['Index maps', 'Aerial photographs'],
      'dcat_theme_sm' => ['Imagery'],
      'dcat_keyword_sm' => KEYWORDS,
      'dct_format_s' => 'GeoJSON',
      'locn_geometry' => envelope,
      'dcat_bbox' => envelope,
      'pcdm_memberOf_sm' => [COLLECTION_ID],
      'dct_rights_sm' => [INDEX_MAP_RIGHTS],
      'dct_license_sm' => [CC0],
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => index_map.modified,
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => {
        OPENINDEXMAPS => url,
        DOWNLOAD => [{ 'url' => url, 'label' => "GeoJSON (#{size_label(bytes)})" }],
        WEB_PAGE => DATASET_URL
      }.to_json
    )
  end

  # The record of one layer of USDA's image dates
  # @param layer [ImageDates::Layer]
  # @param description [Array<String>] the collection's description, for a layer USDA gives none
  # @param index_maps [Array<String>] the ids of the index maps of the same imagery, its source: the image dates
  #   record when each of the index map's tiles was flown
  def self.image_dates(layer, description:, index_maps: [])
    years = layer.years
    states = layer.states
    place = layer.national? ? nil : list(states.map { |state| Places.phrase(state) })
    envelope = layer.bounds && format_envelope(*layer.bounds)
    compact(
      'id' => layer.id,
      'dct_title_s' => "NAIP Image Dates#{" of #{place}" if place}, #{layer.year}",
      'dct_alternative_sm' => [layer.title],
      'dct_description_sm' => layer.description.empty? ? description : layer.description,
      'dct_creator_sm' => [FSA],
      'dct_publisher_sm' => [FSA],
      'schema_provider_s' => USDA,
      'dct_issued_s' => layer.row['issued'].to_s[0, 10],
      'dct_temporal_sm' => [[years.first, years.last].uniq.join('-')],
      'gbl_indexYear_im' => (years.first..years.last).to_a,
      'gbl_dateRange_drsim' => ["[#{years.first} TO #{years.last}]"],
      'dct_spatial_sm' => layer.national? ? ['United States'] + states.map { |state| Places.name(state) } :
                                            states.map { |state| Places.name(state) },
      'dct_language_sm' => ['eng'],
      'gbl_resourceClass_sm' => ['Datasets'],
      'gbl_resourceType_sm' => ['Polygon data'],
      'dcat_theme_sm' => ['Imagery'],
      'dcat_keyword_sm' => ['National Agriculture Imagery Program', 'Image acquisition dates'],
      'dct_format_s' => 'GeoJSON',
      'locn_geometry' => envelope,
      'dcat_bbox' => envelope,
      'pcdm_memberOf_sm' => [COLLECTION_ID],
      'dct_source_sm' => index_maps,
      'dct_rights_sm' => [layer.row['license'], CREDIT].compact,
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => layer.modified,
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => compact(
        FEATURE_LAYER => layer.row['service'],
        DOWNLOAD => [['geojson', 'GeoJSON'], ['csv', 'CSV']].filter_map do |key, label|
          { 'url' => layer.row[key], 'label' => label } if layer.row[key]
        end,
        WEB_PAGE => layer.row['landing']
      ).to_json
    )
  end

  # The record of USDA's image service of the latest imagery of each state
  # @param service [Hash] the service, as the snapshot's row
  # @param description [Array<String>] the collection's description: the service's own is a placeholder, "Purpose:
  #   test:202407180638 naip service", updated "as new USGS NED data is aquired"
  def self.image_service(service, description:)
    groups = service['groups']
    years = groups.map { |group| group['year'] }.uniq.sort
    states = groups.map { |group| group['state'] }.uniq.select { |state| Places.name(state) }.sort
    west, south, east, north = service['extent']
    envelope = format_envelope(west, east, north, south)
    compact(
      'id' => IMAGE_SERVICE_ID,
      'dct_title_s' => 'NAIP Aerial Imagery, Latest of Each State',
      'dct_description_sm' => description,
      'dct_creator_sm' => [FSA],
      'dct_publisher_sm' => [FSA],
      'schema_provider_s' => USDA,
      'dct_temporal_sm' => [[years.first, years.last].uniq.join('-')],
      'gbl_indexYear_im' => years,
      'gbl_dateRange_drsim' => ["[#{years.first} TO #{years.last}]"],
      'dct_spatial_sm' => ['United States'] + states.map { |state| Places.name(state) },
      'dct_language_sm' => ['eng'],
      'gbl_resourceClass_sm' => ['Imagery'],
      'gbl_resourceType_sm' => ['Aerial photographs'],
      'dcat_theme_sm' => ['Imagery'],
      'dcat_keyword_sm' => KEYWORDS,
      'locn_geometry' => envelope,
      'dcat_bbox' => envelope,
      'pcdm_memberOf_sm' => [COLLECTION_ID],
      'dct_rights_sm' => [RIGHTS],
      'dct_license_sm' => [PUBLIC_DOMAIN_MARK],
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => groups.filter_map { |group| group['added'] }.max,
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => {
        IMAGE_MAP_LAYER => service['url'],
        THUMBNAIL => thumbnail(service['url']),
        WEB_PAGE => HUB_URL
      }.to_json
    )
  end

  # Solr's ENVELOPE(west, east, north, south) syntax. west > east crosses the antimeridian.
  def self.format_envelope(west, east, north, south)
    "ENVELOPE(#{[west, east, north, south].map { |coordinate| format_coordinate(coordinate) }.join(', ')})"
  end

  # Six decimals, about 10 centimeters, without trailing zeros
  def self.format_coordinate(value)
    format('%.6f', Float(value)).sub(/0+\z/, '').sub(/\.\z/, '')
  end

  # A coordinate as a JSON number: 42 rather than 42.0
  def self.coordinate(value)
    text = format_coordinate(value)
    text.include?('.') ? Float(text) : Integer(text)
  end

  # e.g. "Puerto Rico and the Virgin Islands", for a title
  def self.list(words)
    words.size > 1 ? "#{words[0..-2].join(', ')} and #{words.last}" : words.first
  end

  # e.g. "8.0 MB", or "3 KB" for a small file
  def self.size_label(bytes)
    bytes >= 100_000 ? format('%.1f MB', bytes / 1_000_000.0) : "#{(bytes / 1000.0).ceil} KB"
  end

  # Drop fields with nothing to say, so records don't carry empty strings or arrays
  def self.compact(record)
    record.reject { |_key, field| field.nil? || (field.respond_to?(:empty?) && field.empty?) }
  end
end
