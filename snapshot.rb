require 'fileutils'
require 'json'
require 'zlib'

# A run's snapshot: what it fetched, as gzipped JSON lines in tmp/, so that a run can be repeated or debugged
# without fetching everything again. Plain .jsonl files work too, which is what the tests use.
module Snapshot
  class Error < StandardError; end

  def self.write(dir, name, rows)
    FileUtils.mkdir_p(dir)
    Zlib::GzipWriter.open(File.join(dir, "#{name}.gz")) do |gzip|
      rows.each { |row| gzip.puts(JSON.generate(row)) }
    end
  end

  def self.read(dir, name)
    gzipped = File.join(dir, "#{name}.gz")
    plain = File.join(dir, name)
    if File.exist?(gzipped)
      # Read as UTF-8 whatever the locale
      Zlib::GzipReader.open(gzipped) { |gzip| gzip.each_line.map { |line| JSON.parse(line.force_encoding(Encoding::UTF_8)) } }
    elsif File.exist?(plain)
      File.foreach(plain, mode: 'r:bom|utf-8').reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
    else
      raise Error, "No #{name} in the snapshot at #{dir}"
    end
  end
end
