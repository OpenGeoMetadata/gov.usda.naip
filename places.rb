# The states and territories NAIP could cover, by the lowercase codes Planetary Computer's naip:state property
# uses. Named as gov.usgs.htmc and gov.usgs.tnm name them, so that the repositories name places alike.
module Places
  NAMES = {
    'al' => 'Alabama', 'ak' => 'Alaska', 'az' => 'Arizona', 'ar' => 'Arkansas', 'ca' => 'California',
    'co' => 'Colorado', 'ct' => 'Connecticut', 'de' => 'Delaware', 'dc' => 'District of Columbia',
    'fl' => 'Florida', 'ga' => 'Georgia', 'hi' => 'Hawaii', 'id' => 'Idaho', 'il' => 'Illinois',
    'in' => 'Indiana', 'ia' => 'Iowa', 'ks' => 'Kansas', 'ky' => 'Kentucky', 'la' => 'Louisiana',
    'me' => 'Maine', 'md' => 'Maryland', 'ma' => 'Massachusetts', 'mi' => 'Michigan', 'mn' => 'Minnesota',
    'ms' => 'Mississippi', 'mo' => 'Missouri', 'mt' => 'Montana', 'ne' => 'Nebraska', 'nv' => 'Nevada',
    'nh' => 'New Hampshire', 'nj' => 'New Jersey', 'nm' => 'New Mexico', 'ny' => 'New York',
    'nc' => 'North Carolina', 'nd' => 'North Dakota', 'oh' => 'Ohio', 'ok' => 'Oklahoma', 'or' => 'Oregon',
    'pa' => 'Pennsylvania', 'ri' => 'Rhode Island', 'sc' => 'South Carolina', 'sd' => 'South Dakota',
    'tn' => 'Tennessee', 'tx' => 'Texas', 'ut' => 'Utah', 'vt' => 'Vermont', 'va' => 'Virginia',
    'wa' => 'Washington', 'wv' => 'West Virginia', 'wi' => 'Wisconsin', 'wy' => 'Wyoming',
    'as' => 'American Samoa', 'gu' => 'Guam', 'mp' => 'Northern Mariana Islands', 'pr' => 'Puerto Rico',
    'vi' => 'Virgin Islands'
  }.freeze

  # Every code the catalog is asked about, so that a state NAIP adds is found without a change here
  CODES = NAMES.keys.sort.freeze

  # Names that read with "the" in a title: "of the Virgin Islands"
  ARTICLED = %w[dc mp vi].freeze

  def self.name(code)
    NAMES[code]
  end

  # The codes of the states a title names, by name or by code: "2018 West Virginia Image Dates" -> wv, "AL 2013" ->
  # al, "2021 Puerto Rico/Virgin Islands" -> pr, vi. Longer names are matched first, so that West Virginia isn't
  # Virginia too.
  def self.codes_in(text)
    rest = text.dup
    found = NAMES.sort_by { |_code, name| -name.length }.filter_map do |code, name|
      code if rest.sub!(/\b#{Regexp.escape(name)}\b/, ' ')
    end
    found += rest.scan(/\b[A-Z]{2}\b/).map(&:downcase).select { |code| NAMES.key?(code) }
    found.uniq.sort
  end

  # e.g. "Rhode Island", "the Virgin Islands"
  def self.phrase(code)
    ARTICLED.include?(code) ? "the #{name(code)}" : name(code)
  end
end
