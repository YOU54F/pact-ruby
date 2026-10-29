# frozen_string_literal: true

# Pact compatibility suite runner for the V4 plugin features.
#
# Run with compatibility-suite/run-plugins.sh (needs PACT_COMPAT_SUITE).
# Each scenario records whether its main action went through the pact-ruby DSL
# or fell back to the raw FFI bindings; a summary is printed at the end.

require 'json'
require 'base64'
require 'fileutils'
require 'tmpdir'
require 'shellwords'
require 'socket'
require 'timeout'
require 'rspec/expectations'
require 'pact'
require 'pact/ffi'
require 'grpc'

# The plugin builders name the failing RSpec example in mismatch errors; outside
# rspec-core there is no current example, so provide a nil one.
module RSpec
  def self.current_example = nil
end unless RSpec.respond_to?(:current_example)

SUITE_DIR = ENV.fetch('PACT_COMPAT_SUITE', '')
FIXTURES_DIR = File.join(SUITE_DIR, 'fixtures')
PLUGIN_DIR = ENV['PACT_PLUGIN_DIR'] || File.join(Dir.home, '.pact', 'plugins')

# FFI functions the runner needs with pointer-friendly signatures.
module CompatFfi
  module Raw
    extend FFI::Library
    ffi_lib DetectOS.get_bin_path
    attach_function :get_error_message, :pactffi_get_error_message, %i[pointer int32], :int32
  end
end

module CompatFfi
  def self.last_error
    buf = FFI::MemoryPointer.new(:char, 4096)
    len = Raw.get_error_message(buf, 4096)
    len.positive? ? buf.read_string : ''
  end
end

# Tracks which path (DSL or FFI) each scenario took.
module PathTracker
  RESULTS = Hash.new { |h, k| h[k] = Hash.new(0) }
  NOTES = []

  def self.record(feature, path)
    RESULTS[feature][path] += 1
  end

  def self.report
    return if RESULTS.empty?

    lines = ['', 'DSL vs FFI per feature file:']
    RESULTS.sort.each do |feature, counts|
      lines << format('  %-28s DSL=%-3d FFI=%-3d', feature, counts[:dsl], counts[:ffi])
    end
    lines << format('  %-28s DSL=%-3d FFI=%-3d', 'TOTAL', RESULTS.values.sum { |c| c[:dsl] },
                    RESULTS.values.sum { |c| c[:ffi] })
    puts lines.join("\n")
    File.write(ENV['PACT_COMPAT_PATH_REPORT'], JSON.pretty_generate(RESULTS)) if ENV['PACT_COMPAT_PATH_REPORT']
  end
end

at_exit { PathTracker.report }

Before do |scenario|
  if SUITE_DIR.empty? || !Dir.exist?(File.join(SUITE_DIR, 'features', 'V4', 'plugins'))
    skip_this_scenario('PACT_COMPAT_SUITE is not set or has no features/V4/plugins')
  end
  @feature = File.basename(scenario.location.file, '.feature')
  @tmp = Dir.mktmpdir('pact-compat-')
  @path = nil
  @cleanups = []
end

After do |scenario|
  @cleanups&.reverse_each do |c|
    c.call
  rescue StandardError
    nil
  end
  FileUtils.rm_rf(@tmp) if @tmp
  PathTracker.record(@feature, @path || :ffi) unless scenario.status == :skipped
end
