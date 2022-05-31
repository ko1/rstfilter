# require "rstfilter/version"

require_relative 'rstfilter/rewriter'
require_relative 'rstfilter/exec'

if __FILE__ == $0
  filter = RstFilter::Exec.new
  filter.optparse! ['-o', '-v']
  file = ARGV.shift || File.expand_path(__dir__ + '/../sample.rb')
  filter.process File.expand_path(file)
end
