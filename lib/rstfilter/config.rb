# frozen_string_literal: true

require 'optparse'
require 'shellwords'

module RstFilter
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
    exec_command: nil,
    command_format: '%e %f',
    cursor_line: nil,

    # dump
    dump: nil, # :json

    # general
    verbose: false,
    ignore_pragma: false,
  }.freeze

  Command = Struct.new(:label, :command)

  class Config < Struct.new(*DEFAULT_SETTING.keys, keyword_init: true)
    def self.load_rc path
      require 'yaml'
      conf = begin
               conf = YAML.load_file(path)
             rescue => e
               STDERR.puts "Can not load #{path}."
               STDERR.puts "#{e}"
               exit false
             end
      #
      conf.each{|k, v|
        case k
        when 'default'
          set_default! Shellwords.split(v)
        when 'dir'
          v.each{|pat, c|
            Config[pat] = Shellwords.split(c)
          }
        else
          STDERR.puts "Unknown configuration key: #{k}"
          exit false
        end
      }
    end

    def self.[]=(pat, args)
      c = @configs[pat] = Config.new(nil, **DEFAULT_SETTING)
      c.update_args args
      c.freeze
    end

    def self.get filename
      @configs.each{|pat, config|
        if File.fnmatch(pat, filename)
          return config
        end
      }

      @default
    end

    def self.set_default! args
      @default = Config.new nil, DEFAULT_SETTING
      @default.update_args args
      @default.freeze
    end

    @default = nil

    def self.default
      @default
    end

    def initialize filename, opt = {}
      if base_config = filename ? Config.get(filename) : Config.default
        update base_config.to_h.merge(opt)
      else
        update opt
      end
    end

    def update_args args
      update optparse!(args)
    end

    private def update opt
      opt.each{|k, v| self[k] = v}
    end

    DEFAULT = Config.new(nil, DEFAULT_SETTING).freeze
    @default = DEFAULT.freeze
    @configs = {}

    private def optparse! args
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
      o.on('-e', '--executable=COMMAND', 'Execute Ruby script with given command'){|cmdstr|
        opt[:exec_command] ||= []

        if /\A(.+):(.+)\z/ =~ cmdstr
          cmd = Command.new($1, $2)
        else
          cmd = Command.new("e#{(opt[:exec_command]&.size || 0) + 1}", cmdstr)
        end

        opt[:exec_command] << cmd
      }
      o.on('--command-format=FORMAT', "Execute parameters",
                                           "Default: '%e %f'",
                                           "Specifiers:",
                                           "  %e: executable",
                                           "  %f: given file",
                                           "  %l: line"){|fmt|
        opt[:command_format] = fmt
      }
      o.on('-j', '--json', 'Print records in JSON format'){
        opt[:dump] = :json
      }
      o.on('--ignore-pragma', 'Ignore pragma specifiers'){
        opt[:ignore_pragma] = true
      }
      o.on('--rc RCFILE', 'Load RCFILE'){|file|
        Config.load_rc file
      }
      o.on('--cursor-line=LINE'){|line|
        opt[:cursor_line] = line
      }
      o.on('--verbose', 'Verbose mode'){
        opt[:verbose] = true
      }
      o.parse!(args)

      opt
    end
  end
end

