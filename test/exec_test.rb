require_relative "test_helper"
require 'stringio'
require 'shellwords'

class ExecTest < Minitest::Test
  def assert_exec src, expected, opt = ''
    $stdout = StringIO.new
    exec = RstFilter::Exec.new "test_exec.rb", src
    exec.update_option Shellwords.split(opt) unless opt.empty?
    exec.process
  ensure
    actual = $stdout.string
    $stdout = STDOUT
    assert_equal expected.strip, actual.strip
  end

  def test_exec
    assert_exec %q{
      a = 1
      b = 2
      a + b
    }, %q{
      a = 1                                        #=> 1
      b = 2                                        #=> 2
      a + b                                        #=> 3
    }
    assert_exec %q{
      a = 1
      b = 2 #=>
      a + b #=> xyzzy
    }, %q{
      a = 1                                        #=> 1
      b = 2 #=> 2
      a + b #=> 3
    }
  end

  def test_exec_indent
    assert_exec %q{
      a = 1
      b = 2
      a + b
    }, %q{
      a = 1                              #=> 1
      b = 2                              #=> 2
      a + b                              #=> 3
    }, '--comment-indent=40'
    assert_exec %q{
      a = 1
      b = 2
      a + b
    }, %q{
      a = 1 #=> 1
      b = 2 #=> 2
      a + b #=> 3
    }, '--comment-indent=0'
  end

  def test_exec_comment
    assert_exec %q{
      a = 1  #=>
      b = 2
      a + b    #=> xyzzy
    }, %q{
      a = 1  #=> 1
      b = 2
      a + b    #=> 3
    }, '-c'
  end

  def test_exec_output
    assert_exec %q{
      a = 1
      b = 2
      p a + b
    }, %q{3

      a = 1                                        #=> 1
      b = 2                                        #=> 2
      p a + b                                      #=> 3
    }

    assert_exec %q{
      a = 1
      b = 2
      p a + b
    }, %q{
      a = 1                                        #=> 1
      b = 2                                        #=> 2
      p a + b                                      #=> 3
    }, '-o' if false # doesn't work on test
  end

  def test_exec_inline_option
    assert_exec %q{
      #rstfilter -c
      a = 1  #=>
      b = 2
      a + b    #=> xyzzy
    }, %q{
      #rstfilter -c
      a = 1  #=> 1
      b = 2
      a + b    #=> 3
    }
  end
end
