require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../iso_record'

# test/fixtures/iso.xml is USDA's ISO 19115-2 record for NAIP, as fetched on 2026-10-27
class IsoRecordTest < Minitest::Test
  XML = File.read(File.join(__dir__, 'fixtures', 'iso.xml'))

  class FakeServer
    Response = Struct.new(:code, :body, :message) do
      def is_a?(type)
        type == Net::HTTPSuccess ? code == '200' : super
      end
    end

    def initialize(body, code = '200')
      @body = body
      @code = code
    end

    def get(_url)
      Response.new(@code, @body, 'OK')
    end
  end

  def test_reads_the_title_abstract_purpose_and_first_year
    record = IsoRecord.new(XML)

    assert_equal 'National Agriculture Imagery Program (NAIP) Imagery', record.title
    assert_match(/\AThe National Agriculture Imagery Program \(NAIP\) is administered by the U\.S\. Department/,
                 record.abstract)
    refute_match(/\n|  /, record.abstract, 'line breaks and runs of spaces are closed up')
    assert_match(/\ANAIP imagery provides the ability to effectively administer farm programs/, record.purpose)
    assert_equal 2002, record.first_year
  end

  def test_fetching_keeps_the_record_in_the_snapshot
    dir = Dir.mktmpdir
    IsoRecord.fetch(dir, http: FakeServer.new(XML))

    assert_equal 'National Agriculture Imagery Program (NAIP) Imagery', IsoRecord.load(dir).title
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_a_failed_or_empty_answer_stops_the_fetch
    Dir.mktmpdir do |dir|
      assert_raises(IsoRecord::Error) { IsoRecord.fetch(dir, http: FakeServer.new('', '404')) }
      assert_raises(IsoRecord::Error) { IsoRecord.fetch(dir, http: FakeServer.new('<gmd:MD_Metadata/>')) }
    end
  end
end
