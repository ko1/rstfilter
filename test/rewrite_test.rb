require_relative "test_helper"
require 'rbconfig'

class RewriteTest < Minitest::Test
  def setup
    @rewriter = RstFilter::Rewriter.new(RstFilter::Config::DEFAULT)
  end

  def mod_src_check_file f
    mod_src_check File.read(f), f
  end

  def mod_src_check src, filename = nil
    begin
      mod_src, _comments = @rewriter.rewrite src, filename
      ast = RubyVM::AbstractSyntaxTree.parse(mod_src)
    rescue Parser::SyntaxError, EncodingError
      # memo: https://github.com/whitequark/parser/issues/854
      ast = true
    rescue SyntaxError => e
      assert false, "#{filename}:\n#{e}"
    end
    assert ast, "#{filename} should be nonnull"
  end

  def test_mod_src_self
    Dir.glob(File.join(__dir__, '../**/*.rb')){|f|
      mod_src_check_file f
    }
  end

  def test_mod_src_srcdir
    if dir = ENV['RSTFILTER_TEST_SRCDIR']
      Dir.glob(File.join(dir, '**/*.rb')){|f|
        mod_src_check_file f
      }
    end
  end

  def test_mod_src_ruby
    Dir.glob(File.join(RbConfig::CONFIG['libdir'], '**/*.rb')){|f|
      mod_src_check_file f
    }
  end
end
