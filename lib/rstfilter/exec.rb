require 'optparse'
require 'shellwords'

module RstFilter
  class Exec
    def update_opt opt = {}
      opt = @opt.to_h.merge(opt)
      @opt = ConfigOption.new(**opt)
    end

    def initialize opt = {}
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
      verbose: false,
      exec_command: false, # false: simply load file
                           # String value: launch given string as a command
      exec_with_filename: true,

      # dump
      dump: nil, # :json
    }

    ConfigOption = Struct.new(*DEFAULT_SETTING.keys, keyword_init: true)

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
      o.on('-e', '--command=COMMAND', 'Execute Ruby script with given command'){|cmd|
        if /\A(.+):(.+)\z/ =~ cmd
          opt[:comment_label] = $1
          opt[:exec_command] = $2
        else
          opt[:exec_command] = cmd
        end
      }
      o.on('--no-filename', 'Execute -e command without filename'){
        opt[:exec_with_filename] = false
      }
      o.on('-j', '--json', 'Print records in JSON format'){
        opt[:dump] = :json
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

    def puts_result prefix, r, line = nil
      if @opt.use_pp
        result_lines = PP.pp(r, '').lines
      else
        result_lines = r.inspect.lines
      end

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
          puts "#{prefix.chomp}#{indent} #=> #{comment_label}#{result_lines.shift}"
        end
      end

      cont_comment = '#' + ' ' * @opt.comment_pattern.size

      result_lines.each{|result_line|
        puts ' ' * prefix.size + "#{cont_comment}#{result_line}"
      }
    end

    def exec_mod_src mod_src
      # execute modified src
      ENV['RSTFILTER_SHOW_OUTPUT'] = @opt.show_output ? '1' : nil
      ENV['RSTFILTER_SHOW_EXCEPTIONS'] = @opt.show_exceptions ? '1' : nil
      ENV['RSTFILTER_FILENAME'] = @filename

      case @opt.exec_command
      when String
        require 'tempfile'
        recf = Tempfile.new('rstfilter-rec')
        ENV['RSTFILTER_RECORD_PATH'] = recf.path
        recf.close

        modf = Tempfile.new('rstfilter-modsrc')
        modf.write mod_src
        modf.close
        ENV['RSTFILTER_MOD_SRC_PATH'] = modf.path

        ENV['RUBYOPT'] = "-r#{File.join(__dir__, 'exec_setup')} #{ENV['RUBYOPT']}"

        cmd = @opt.exec_command
        cmd << ' ' + @filename if @opt.exec_with_filename
        p exec:cmd if @opt.verbose
        system(cmd)
        open(recf.path){|f| Marshal.load f}
      else
        begin
          begin
            require_relative 'exec_setup'
            ::TOPLEVEL_BINDING.eval(mod_src, @filename)
            $__rst_record
          ensure
            $stdout = $__rst_filter_prev_out if $__rst_filter_prev_out
            $stderr = $__rst_filter_prev_err if $__rst_filter_prev_err
            $__rst_filter_raise_captor&.disable

          end
        rescue Exception => e
          if @opt.verbose
            err e.inspect
            err e.backtrace.join("\n")
          else
            err "exit with #{e.inspect}"
          end
          raise
        end
      end
    end

    def modified_src src, filename = nil
      rewriter = Rewriter.new @opt
      rewriter.rewrite(src, filename)
    end

    def process filename
      @filename = filename
      src = File.read(filename)
      src, mod_src, comments = modified_src(src, filename)

      comments.each{|c|
        case c.text
        when /\A\#rstfilter\s(.+)/
          optparse! Shellwords.split($1)
        end
      }
      

      records = exec_mod_src mod_src
      pp records: records if @opt.verbose

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
          line_result = records[lineno]&.last

          if line_result && replace_comments[lineno]
            line.match(/(.+)#{@opt.comment_pattern}.*$/) || raise("unreachable")
            puts_result $1, line_result.first, line
          elsif @opt.show_all_results && line_result
            puts_result line, line_result.first
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
end

if $0 == __FILE__
  require_relative 'rewriter'
  filter = RstFilter::Exec.new
  filter.optparse! ['-v', '-j']
  file = ARGV.shift || File.expand_path(__dir__ + '/../../sample.rb')
  filter.process File.expand_path(file)
end
