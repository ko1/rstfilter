
require 'parser/current'
require 'pp'

module RstFilter
  class RecordAll < Parser::TreeRewriter
    def initialize opt
      @decl = opt.show_decl || (opt.show_all_results == false)

      super()
    end

    def add_record node
      if le = node&.location&.expression
        pos = [le.begin.line, le.begin.column, le.end.line, le.end.column].join(',')
        insert_before(le.begin, "::RSTFILTER__.record(#{pos}){")
        insert_after(le.end, "}")
      end
    end

    def add_paren node
      if le = node&.location&.expression
        insert_before(le.begin, '(')
        insert_after(le.end, ")")
      end
    end

    def process node
      return unless node

      super

      case node.type
      when :begin,
           :resbody, :rescue,
           :ensure,
           :return,
           :next,
           :redo,
           :retry,
           :splat,
           :block_pass,
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

    def process_args args
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
    end

    def on_def node
      _name, args, body = node.children
      process_args args
      process body
    end

    def on_defs node
      recv, _name, args, body = node.children
      process recv
      add_paren recv
      process_args args
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

    def on_numblock node
      on_block node
    end
  end

  class Rewriter
    def initialize opt
      @opt = opt
    end

    def rewrite src, filename
      # only MRI defines RubyVM::AbstractSyntaxTree.parse
      if defined?(RubyVM::AbstractSyntaxTree.parse)
        # if RubyVM::AbstractSyntaxTree.parse is available we can use it to
        # pre-parse to check syntax and find the last line of actual code,
        # excluding __END__ and later

        # check syntax and find the last line
        prev_v, $VERBOSE = $VERBOSE, false
        ast = RubyVM::AbstractSyntaxTree.parse(src)
        $VERBOSE = prev_v
        last_lineno = ast.last_lineno
        
        # remove __END__ and later
        src = src.lines[0..last_lineno].join
      end

      # rewrite
      ast, comments = Parser::CurrentRuby.parse_with_comments(src)
      buffer        = Parser::Source::Buffer.new('(example)')
      buffer.source = src
      rewriter      = RecordAll.new @opt
      mod_src       = rewriter.rewrite(buffer, ast)

      if @opt.verbose
        pp ast
        puts "     #{(0...80).map{|i| i%10}.join}"
        puts mod_src.lines.map.with_index{|line, i| '%4d:%s' % [i+1, line] }
      end

      return src, mod_src, comments
    end
  end
end

