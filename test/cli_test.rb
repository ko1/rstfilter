require_relative "test_helper"
require "open3"

class CliTest < Minitest::Test
  def test_file
    stdout_str, status = Open3.capture2(
      "./exe/rstfilter test/fixtures/sample.rb"
    )

    assert status.success?
    assert_equal <<~OUT, stdout_str
      a = 1                                              #=> 1
      b = 2                                              #=> 2
      a + b                                              #=> 3
    OUT
  end

  def test_stdin
    stdin_str = <<~CODE
      a = 1
      b = 2
      a + b
    CODE

    stdout_str, status = Open3.capture2(
      "./exe/rstfilter",
      stdin_data: stdin_str
    )

    assert status.success?
    assert_equal <<~OUT, stdout_str
      a = 1                                              #=> 1
      b = 2                                              #=> 2
      a + b                                              #=> 3
    OUT
  end
end
