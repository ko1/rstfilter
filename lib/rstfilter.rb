# require "rstfilter/version"

require 'parser/current'
require 'stringio'
require 'optparse'
require 'ostruct'
require 'pp'

module RstFilter
  class RecordAll < Parser::TreeRewriter
    def initialize opt
      @decl = opt.show_decl || (opt.show_all_results == false)

      super()
    end

    def add_record node
      if le = node&.location&.expression
        insert_before(le.begin, '(')
        insert_after(le.end, ").__rst_record__(#{[le.begin.line, le.begin.column, le.end.line, le.end.column].join(',')})")
      end
    end

    def process node
      return unless node

      case node.type
      when :begin,
           :resbody, :rescue,
           :ensure,
           :return,
           :next,
           :redo,
           :retry,
           :splat,
           :lvasgn,
           :when
        # skip
      when :def, :class
        add_record node if @decl
      when :if
        unless node.loc.expression.source.start_with? 'elsif'
          add_record node
        end
      else
        add_record node
      end

      super
    end

    def on_dstr node
    end

    def on_regexp node
    end

    def on_const node
    end

    def on_masgn node
      _mlhs, rhs = node.children
      if rhs.type == :array
        rhs.children.each{|r| process r}
      end
    end

    def on_class node
      _name, sup, body = node.children
      process sup
      process body
    end

    def on_module node
      _name, body = node.children
      process body
    end

    def on_def node
      _name, args, body = node.children
      args.children.each{|arg|
        case arg.type
        when :optarg
          _name, opexpr = arg.children
          process opexpr
        when :kwoptarg
          _name, kwexpr = arg.children
          process kwexpr
        end
      }
      process body
    end

    def process_pairs pairs
      pairs.each{|pair|
        key, val = pair.children
        if key.type != :sym
          process key
        end
        process val
      }
    end

    def on_hash node
      process_pairs node.children
    end

    def on_send node
      recv, _name, *args = *node.children
      process recv if recv

      args.each{|arg|
        if arg.type == :hash
          process_pairs arg.children
        else
          process arg
        end
      }
    end

    def on_block node
      _send, _args, block = *node.children
      process block
    end
  end

  class Exec
    DEFAULT_SETTING = {
      # default setting
      show_all_results: true,
      show_exceptions: true,
      show_output: false,
      show_decl: false,
      show_specific_line: nil,

      use_pp: false,
      comment_indent: 50,
      comment_pattern: '#=>',
      verbose: false,
    }

    ConfigOption = Struct.new(*DEFAULT_SETTING.keys, keyword_init: true)

    def update_opt opt = {}
      opt = @opt.to_h.merge(opt)
      @opt = ConfigOption.new(**opt)
    end

    def initialize
      @opt = ConfigOption.new(**DEFAULT_SETTING)
    end

    def optparse! argv
      opt = {}
      o = OptionParser.new
      o.on('-c', '--comment', 'Show result only on comment'){
        opt[:show_all_results] = false
      }
      o.on('-o', '--output', 'Show output results'){
        opt[:show_output] = true
      }
      o.on('-d', '--decl', 'Show results on declaration'){
        opt[:show_decl] = true
      }
      o.on('--no-exception', 'Do not show exception'){
        opt[:show_exception] = false
      }
      o.on('-a', '--all', 'Show all results/output'){
        opt[:show_output]      = true
        opt[:show_all_results] = true
        opt[:show_exceptions]  = true
      }
      o.on('--pp', 'Use pp to represent objects'){
        opt[:use_pp] = true
      }
      o.on('--comment-indent=NUM', "Specify comment indent size (default: #{DEFAULT_SETTING[:comment_indent]})"){|n|
        opt[:comment_indent] = n.to_i
      }
      o.on('--verbose', 'Verbose mode'){
        opt[:verbose] = true
      }
      o.parse!(argv)
      update_opt opt
    end

    def capture_out
      return yield unless @opt.show_output

      begin
        prev_out = $stdout
        prev_err = $stderr

        $captured_out = $stdout = StringIO.new
        if false # debug
          $captured_err = $captured_out
        else
          $captured_err = $stderr = StringIO.new
        end

        yield
      ensure
        $stdout = prev_out
        $stderr = prev_err
      end
    end

    def record_rescue
      if @opt.show_exceptions
        TracePoint.new(:raise) do |tp|
          caller_locations.each{|loc|
            if loc.path == @filename
              $__rst_record[loc.lineno][0] = [tp.raised_exception, '', '']
              break
            end
          }
        end.enable do
          yield
        end
      else
        yield
      end
    end

    class ::BasicObject
      def __rst_record__ begin_line, begin_col, end_line, end_col
        out, err = *[$captured_out, $captured_err].map{|o|
          str = o.string
          o.string = ''
          str
        } if $captured_out

        $__rst_record[end_line][end_col] = [self, out, err]

        self
      end
    end

    $__rst_record = Hash.new{|h, k| h[k] = []}
    $captured_out = nil
    $captured_err = nil

    def err msg
      msg.each_line{|line|
        STDERR.puts "[RstFilter] #{line}"
      }
    end

    def puts_result prefix, r, line = nil
      if @opt.use_pp
        result_lines = PP.pp(r, '').lines
      else
        result_lines = r.inspect.lines
      end

      if line
        puts line.sub(/#{@opt.comment_pattern}.*$/, "#{@opt.comment_pattern} #{result_lines.shift.chomp}")
      else
        puts "#{prefix} #=> #{result_lines.shift}"
      end

      cont_comment = '#' + ' ' * @opt.comment_pattern.size
      result_lines.each{|result_line|
        puts ' ' * prefix.size + "#{cont_comment}#{result_line}"
      }
    end

    def process filename
      @filename = filename
      src = File.read(filename)

      begin
        prev_v, $VERBOSE = $VERBOSE, false
        ast = RubyVM::AbstractSyntaxTree.parse(src)
        $VERBOSE = prev_v
        last_lineno = ast.last_lineno
      rescue SyntaxError => e
        err e.inspect
        exit 1
      end

      # rewrite
      src           = src.lines[0..last_lineno].join # remove __END__ and later
      ast, comments = Parser::CurrentRuby.parse_with_comments(src)
      buffer        = Parser::Source::Buffer.new('(example)')
      buffer.source = src
      rewriter      = RecordAll.new @opt
      mod_src       = rewriter.rewrite(buffer, ast)

      pp ast if @opt.verbose
      puts mod_src.lines.map.with_index{|line, i| '%4d: %s' % [i+1, line] } if @opt.verbose

      # execute modified src
      begin
        capture_out do
          record_rescue do
            ::TOPLEVEL_BINDING.eval(mod_src, filename)
          end
        end
      rescue Exception => e
        if @opt.verbose
          err e.inspect
          err e.backtrace.join("\n")
        else
          err "exit with #{e.inspect}"
        end
      end

      replace_comments = comments.filter_map{|c|
        next unless c.text.start_with? @opt.comment_pattern
        e = c.loc.expression
        [e.begin.line, true]
      }.to_h

      pp $__rst_record if @opt.verbose

      src.each_line.with_index{|line, i|
        lineno = i+1
        line_result = $__rst_record[lineno]&.last

        if line_result && replace_comments[lineno]
          line.match(/(.+)#{@opt.comment_pattern}.*$/) || raise("unreachable")
          puts_result $1, line_result.first, line
        elsif @opt.show_all_results && line_result
          indent = ' ' * [@opt.comment_indent - line.chomp.length, 0].max
          prefix = line.chomp.concat "#{indent}"
          puts_result prefix, line_result.first
        else
          puts line
        end

        if @opt.show_output && line_result
          out, err = *line_result[1..2]
          if m = line.match(/^\s+/)
            indent = ' ' * m[0].size
          else
            indent = ''
          end

          {out: out, err: err}.each{|k, o|
            o.strip!
            o.each_line{|ol|
              puts "#{indent}##{k}: #{ol}"
            } unless o.empty?
          }
        end
      }
    end
  end
end

if __FILE__ == $0
  filter = RstFilter::Exec.new
  filter.optparse! ['-o', '-v']
  file = ARGV.shift || '../sample.rb'
  filter.process File.expand_path(file)
end
