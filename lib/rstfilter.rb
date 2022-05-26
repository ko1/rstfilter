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
        insert_after(le.end, ").__rst_record__(#{le.end.line}, #{le.end.column})")
      end
    end

    def process node
      return unless node
      case node.type
      when :resbody, :rescue, :begin
        # skip
      when :def, :class
        add_record node if @decl
      else
        add_record node
      end

      super
    end

    def on_class node
      _name, sup, body = node.children
      process sup
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

    def on_send node
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
      def __rst_record__ line, col
        out, err = *[$captured_out, $captured_err].map{|o|
          str = o.string
          o.string = ''
          str
        } if $captured_out

        # ::STDERR.puts [line, col, self, out, err].inspect
        $__rst_record[line][col] = [self, out, err]

        self
      end
    end

    $__rst_record = Hash.new{|h, k| h[k] = []}

    def process filename
      @filename = filename

      code = File.read(filename)

      begin
        ast, comments = Parser::CurrentRuby.parse_with_comments(code)
      rescue Parser::SyntaxError => e
        puts e
        exit 1
      end

      end_line = ast.loc.expression.end.line
      code = code.lines[0..end_line].join # remove __END__ and later

      buffer        = Parser::Source::Buffer.new('(example)')
      buffer.source = code
      rewriter      = RecordAll.new @opt

      mod_src = rewriter.rewrite(buffer, ast)
      puts mod_src.lines.map.with_index{|line, i| '%4d: %s' % [i+1, line] } if @opt.verbose

      begin
        capture_out do
          record_rescue do
            ::TOPLEVEL_BINDING.eval(mod_src, filename)
          end
        end
      rescue Exception => e
        if @opt.verbose
          STDERR.puts e
          STDERR.puts e.backtrace
        else
          STDERR.puts "RstFilter: exit with #{e.inspect}"
        end
      end

      replace_comments = {}

      comments.each{|c|
        next unless c.text.start_with? @opt.comment_pattern
        e = c.loc.expression
        line, _col = e.begin.line, e.begin.column
        if $__rst_record.has_key? line
          result = $__rst_record[line].last
          replace_comments[line] = result
        end
      }

      pp $__rst_record if @opt.verbose

      code.each_line.with_index{|line, i|
        line_result = $__rst_record[i+1]&.last

        if line_result && line.match(/(.+)#{@opt.comment_pattern}.*$/)
          prefix = $1
          r = line_result.first
          if @opt.use_pp
            result_lines = PP.pp(r, '').lines
          else
            result_lines = r.inspect.lines
          end
          puts line.sub(/#{@opt.comment_pattern}.*$/, "#{@opt.comment_pattern} #{result_lines.shift.chomp}")
          cont_comment = '#' + ' ' * @opt.comment_pattern.size
          result_lines.each{|result_line|
            puts ' ' * prefix.size + "#{cont_comment}#{result_line}"
          }
        elsif @opt.show_all_results && line_result
          r = line_result.first
          indent = ' ' * [@opt.comment_indent - line.chomp.length, 0].max
          if @opt.use_pp
            result_lines = PP.pp(r, '').lines
          else
            result_lines = r.inspect.lines
          end
          prefix = line.chomp.concat "#{indent}"
          puts "#{prefix} #=> #{result_lines.shift}"
          cont_comment = '#' + ' ' * @opt.comment_pattern.size
          result_lines.each{|result_line|
            puts ' ' * prefix.size + " #{cont_comment}#{result_line}"
          }
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
  filter.optparse ARGV
  file = ARGV.shift
  filter.process File.expand_path(file)
end
