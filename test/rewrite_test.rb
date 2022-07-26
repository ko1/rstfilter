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
      # ideally we'd use Ruby's actual parser to check that the code we've
      # generated is parseable, but that's not possible unless
      # RubyVM::AbstractSyntaxTree.parse is defined, which is only on MRI
      if defined?(RubyVM::AbstractSyntaxTree.parse)
        RubyVM::AbstractSyntaxTree.parse(src)
      else
        Parser::CurrentRuby.parse(src)
      end
    rescue SyntaxError
      # skip non-ruby code
      return
    end

    begin
      mod_src, _comments = @rewriter.rewrite src, filename

      # as above, we can only use RubyVM::AbstractSyntaxTree.parse on MRI
      if defined?(RubyVM::AbstractSyntaxTree.parse)
        ast = RubyVM::AbstractSyntaxTree.parse(mod_src)
      else
        ast = Parser::CurrentRuby.parse(mod_src)
      end
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
