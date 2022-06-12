require 'optparse'
require 'shellwords'

module RstFilter
  class Exec
    def update_opt opt = {}
      opt = @opt.to_h.merge(opt)
      @opt = ConfigOption.new(**opt)
    end

    attr_reader :output

    def initialize opt = {}
      @output = ''
      @opt = ConfigOption.new(**DEFAULT_SETTING)
      update_opt opt
    end

    DEFAULT_SETTING = {
      # rewrite options
      show_all_results: true,
      show_exceptions: true,
      show_output: false,
      show_decl: false,
      show_specific_line: nil,

      use_pp: false,
      comment_nextline: false,
      comment_indent: 50,
      comment_pattern: '#=>',
      comment_label: nil,

      # execute options
      exec_command: false, # false: simply load file
                           # String value: launch given string as a command
      exec_with_filename: true,

      # dump
      dump: nil, # :json

      # general
      verbose: false,
      ignore_pragma: false,
    }

    ConfigOption = Struct.new(*DEFAULT_SETTING.keys, keyword_init: true)
    Command = Struct.new(:label, :command)

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
      o.on('--pp', 'Use pp to represent objects'){
        opt[:use_pp] = true
      }
      o.on('-n', '--nextline', 'Put comments on next line'){
        opt[:comment_nextline] = true
      }
      o.on('--comment-indent=NUM', "Specify comment indent size (default: #{DEFAULT_SETTING[:comment_indent]})"){|n|
        opt[:comment_indent] = n.to_i
      }
      o.on('--comment-pattern=PAT', "Specify comment pattern of -c (default: '#=>')"){|pat|
        opt[:comment_pattern] = pat
      }
      o.on('--coment-label=LABEL', 'Specify comment label (default: "")'){|label|
        opt[:comment_label] = label
      }
      o.on('--verbose', 'Verbose mode'){
        opt[:verbose] = true
      }
      o.on('-e', '--command=COMMAND', 'Execute Ruby script with given command'){|cmdstr|
        opt[:exec_command] ||= []

        if /\A(.+):(.+)\z/ =~ cmdstr
          cmd = Command.new($1, $2)
        else
          cmd = Command.new("e#{(opt[:exec_command]&.size || 0) + 1}", cmdstr)
        end

        opt[:exec_command] << cmd
      }
      o.on('--no-filename', 'Execute -e command without filename'){
        opt[:exec_with_filename] = false
      }
      o.on('-j', '--json', 'Print records in JSON format'){
        opt[:dump] = :json
      }
      o.on('--ignore-pragma', 'Ignore pragma specifiers'){
        opt[:ignore_pragma] = true
      }
      o.on('--verbose', 'Verbose mode'){
        opt[:verbose] = true
      }
      o.parse!(argv)
      update_opt opt
    end

    def err msg
      msg.each_line{|line|
        STDERR.puts "[RstFilter] #{line}"
      }
    end

    def comment_label
      if l = @opt.comment_label
        "#{l}: "
      end
    end

    def puts_result prefix, results, line = nil
      prefix = prefix.chomp

      if results.size == 1
        r = results.first
        result_lines = r.lines
        indent = ''

        if @opt.comment_nextline
          puts prefix
          if prefix.match(/\A(\s+)/)
            prefix = ' ' * $1.size
          else
            prefix = ''
          end
          puts "#{prefix}" + "#{@opt.comment_pattern}#{comment_label}#{result_lines.shift}"
        else
          if line
            puts line.sub(/#{@opt.comment_pattern}.*$/, "#{@opt.comment_pattern} #{comment_label}#{result_lines.shift.chomp}")
          else
            indent = ' ' * [0, @opt.comment_indent - prefix.size].max
            puts "#{prefix}#{indent} #=> #{comment_label}#{result_lines.shift}"
          end
        end

        cont_comment = ' #' + ' ' * @opt.comment_pattern.size + ' '

        result_lines.each{|result_line|
          puts ' ' * prefix.size + indent + "#{cont_comment}#{result_line}"
        }
      else
        puts prefix

        if prefix.match(/\A(\s+)/)
          prefix = ' ' * $1.size
        else
          prefix = ''
        end

        results.each.with_index{|r, i|
          result_lines = r.lines
          puts "#{prefix}#{@opt.comment_pattern} #{@opt.exec_command[i].label}: #{result_lines.first}"
        }
      end
    end

    def exec_mod_src mod_src
      # execute modified src
      ENV['RSTFILTER_SHOW_OUTPUT'] = @opt.show_output ? '1' : nil
      ENV['RSTFILTER_SHOW_EXCEPTIONS'] = @opt.show_exceptions ? '1' : nil
      ENV['RSTFILTER_FILENAME'] = @filename
      ENV['RSTFILTER_PP'] = @opt.use_pp ? '1' : nil

      case cs = @opt.exec_command
      when Array
        @output = String.new

        cs.map do |c|
          require 'tempfile'
          recf = Tempfile.new('rstfilter-rec')
          ENV['RSTFILTER_RECORD_PATH'] = recf.path
          recf.close

          modf = Tempfile.new('rstfilter-modsrc')
          modf.write mod_src
          modf.close
          ENV['RSTFILTER_MOD_SRC_PATH'] = modf.path

          ENV['RUBYOPT'] = "-r#{File.join(__dir__, 'exec_setup')} #{ENV['RUBYOPT']}"

          cmd = c.command
          cmd << ' ' + @filename if @opt.exec_with_filename
          p exec:cmd if @opt.verbose

          io = IO.popen(cmd, err: [:child, :out])
          begin
            Process.waitpid(io.pid)
          ensure
            begin
              Process.kill(:KILL, io.pid)
            rescue Errno::ESRCH, Errno::ECHILD
            else
              Process.waitpid(io.pid)
            end
          end

          @output << io.read
          open(recf.path){|f| Marshal.load f}
        end
      else
        begin
          begin
            require_relative 'exec_setup'
            ::RSTFILTER__.clear
            ::TOPLEVEL_BINDING.eval(mod_src, @filename)
            [::RSTFILTER__.records]
          ensure
            $stdout = $__rst_filter_prev_out if $__rst_filter_prev_out
            $stderr = $__rst_filter_prev_err if $__rst_filter_prev_err
          end
        rescue Exception => e
          if @opt.verbose
            err e.inspect
            err e.backtrace.join("\n")
          else
            err "exit with #{e.inspect}"
          end
          [::RSTFILTER__.records]
        end
      end
    end

    def modified_src src, filename = nil
      rewriter = Rewriter.new @opt
      rewriter.rewrite(src, filename)
    end

    def record_records filename
      @filename = filename
      src = File.read(filename)
      src, mod_src, comments = modified_src(src, filename)

      comments.each{|c|
        case c.text
        when /\A\#rstfilter\s(.+)/
          optparse! Shellwords.split($1)
        end
      } unless @opt.ignore_pragma

      return exec_mod_src(mod_src), src, comments
    end

    def make_line_records rs
      lrs = {}
      rs.each{|(_bl, _bc, el, _ec), result|
        lrs[el] = result
      }
      lrs
    end

    def process filename
      records, src, comments = record_records filename
      pp records: records if @opt.verbose
      line_records = records.map{|r|
        make_line_records r
      }

      case @opt.dump
      when :json
        require 'json'
        puts JSON.dump(records)
      else
        replace_comments = comments.filter_map{|c|
          next unless c.text.start_with? @opt.comment_pattern
          e = c.loc.expression
          [e.begin.line, true]
        }.to_h

        src.each_line.with_index{|line, i|
          lineno = i+1
          line_results = line_records.map{|r| r[lineno]&.first}.compact

          if line_results.empty?
            puts line
          else
            if replace_comments[lineno]
              line.match(/(.+)#{@opt.comment_pattern}.*$/) || raise("unreachable")
              puts_result $1, line_results, line
            elsif @opt.show_all_results
              puts_result line, line_results
            end
          end

          if @opt.show_output && !line_results.empty?
            if m = line.match(/^\s+/)
              indent = ' ' * m[0].size
            else
              indent = ''
            end

            line_outputs = line_records.map{|r| r[lineno]}.compact
            line_outputs.each.with_index{|r, i|
              out, err = *r[1..2]
              label = @opt.exec_command && @opt.exec_command[i].label
              label += ':' if label

              {out: out, err: err}.each{|k, o|
                o.strip!
                o.each_line{|ol|
                  puts "#{indent}\##{label ? label : nil}#{k}: #{ol}"
                } unless o.empty?
              }
            }
          end
        }

        if !@opt.show_output && !@output.empty?
          puts "# output"
          puts output
        end
      end
    end
  end
end

if $0 == __FILE__
  require_relative 'rewriter'
  filter = RstFilter::Exec.new
  filter.optparse! ['-v']
  file = ARGV.shift || File.expand_path(__dir__ + '/../../sample.rb')
  filter.process File.expand_path(file)
end
