require 'json'
require_relative '../version'
require_relative '../rewriter'
require_relative '../exec'

module RstFilter
  class CancelRequest < StandardError
  end

  class LSP
    def initialize input: $stdin, output: $stdout, err: $stderr, indent: 50
      @input   = input
      @output  = output
      @err     = err
      @indent  = indent
      @records = {} # {filename => [record, line_record, src]}
      @server_request_id = 0
      @exit_status = 1
      @running = {} # {filename => Thread}
    end

    def self.reload
      ::RstFilter.send(:remove_const, :LSP)
      $".delete_if{|e| /lsp\/handler\.rb$/ =~ e}
      require __FILE__
    end

    def start
      # for reload
      trap(:USR1){
        Thread.main.raise "reload"
      }

      lsp = self
      begin
        lsp.event_loop
      rescue Exception => e
        log e
        log e.backtrace

        # reload
        lsp.class.reload
        lsp = RstFilter::LSP.new
        retry
      end
    end

    def event_loop
      while req = recv_message
        if req[:id]
          handle_request req
        else
          handle_notification req
        end
      end
    end

    def log msg
      @err.puts msg
    end

    def recv_message
      log "wait from #{@input.inspect}"
      line = @input.gets 
      line.match(/Content-Length: (\d+)/) || raise("irregular json-rpc: #{line}")
      @input.gets
      msg = JSON.parse(@input.read($1.to_i), symbolize_names: true)
      log "[recv] #{msg.inspect}"
      msg
    end

    def send_message type, msg_text
      log "[#{type}] #{msg_text}"

      text = "Content-Length: #{msg_text.size}\r\n" \
          "\r\n" \
          "#{msg_text}"
      @output.write text
      @output.flush
      if true
        log '----'
        log text
        log '----'
      end
    end

    def send_response req, kw
      res_text = JSON.dump({
        jsonrpc: "2.0",
        id: req[:id],
        result: kw,
      })

      send_message 'response', res_text
    end

    def send_request method, kw = {}
      msg_text = JSON.dump({
        jsonrpc: "2.0",
        method: method,
        id: (@server_request_id+=1),
        params: {
          **kw
        }
      })

      send_message 'request', msg_text
    end

    def send_notice method, kw = {}
      msg_text = JSON.dump({
        jsonrpc: "2.0",
        method: method,
        params: {
          **kw
        }
      })
      send_message "notice", msg_text
    end

    def handle_request req
      if req[:error]
        log "error: #{req.inspect}"
        return
      end

      case req[:method]
      when 'initialize'
        send_response req, {
          capabilities: {
            textDocumentSync: {
              openClose: true,
              change: 2, # Incremental
              # save: true,
            },

            inlineValueProvider: true,

            hoverProvider: true,

            inlayHintProvider: {
              resolveProvider: true,
            },

          },
          serverInfo: {
            name: "rstfilter-lsp-server",
            version: '0.0.1',
          }
        }
      when 'textDocument/hover'
        filename = uri2filename req.dig(:params, :textDocument, :uri)
        line = req.dig(:params, :position, :line)
        char = req.dig(:params, :position, :character)
        if (record, _line_record, src = @records[filename])
          line += 1
          rs = record.find_all{|(bl, bc, el, ec), _v| cover?(line, char, bl, bc, el, ec)}
          if rs.empty?
            send_response req, nil
            else
              r = rs.min_by{|(_bl, _bc, _el, ec), _v| ec}
              v = r[1][0].strip
              pos = r[0]
              send_response req, contents: {
                kind: 'markdown',
                value: "```\n#{v}```",
              }, range: {
                start: {line: pos[0]-1, character: pos[1],},
                end:   {line: pos[2]-1, character: pos[3],},
              }
            end
        else
          send_response req, nil
        end
      when 'textDocument/codeLens'
        filename = uri2filename req.dig(:params, :textDocument, :uri)
        send_response req, codelens(filename)
      when 'textDocument/inlayHint'
        filename = uri2filename req.dig(:params, :textDocument, :uri)
        send_response req, inlayhints(filename)
      when 'inlayHint/resolve'
        hint = req.dig(:params)
        send_response req, {
          position: hint[:position],

          label: [{
            tooltip: {
              kind: 'markdown',
              value: hint[:label] + "\n 1. *foo* `bar` _baz_",
              tooltip: hint[:label] + "\n 1. *foo* `bar` _baz_",
            }
          },
          {
            kind: 'markdown',
            value: hint[:label] + "\n# 2. FOO\n*foo* `bar` _baz_",
          }],
        }
      when 'shutdown'
        @exit_status = 0
        send_response req, nil
      when nil
        # reply
      else
        raise "unknown request: #{req.inspect}"
      end
    end

    def cover? line, char, bl, bc, el, ec
      return false if bl > line
      return false if bl == line && char < bc
      return false if el < line
      return false if el == line && char >= ec
      true
    end

    def inlayhints filename
      if (_record, line_record, src = @records[filename])
        src_lines = src.lines.to_a

        line_record.sort_by{|k, v| k}.map do |lineno, r|
          line = src_lines[lineno - 1]
          next unless line

          {
            position: {
              line: lineno - 1, # 0 origin
              character: line.length,
            },
            label: ' ' * [@indent - line.size, 3].max + "#=> #{r.first.strip}",
            # tooltip: "tooltip of #{lineno}",
            paddingLeft: true,
            kind: 1,
          }
        end.compact
      else
        nil
      end
    end

    def take_record filename
      send_notice 'rstfilter/started', {
        uri: filename,
      }
      @running[filename] = Thread.new do
        filter = RstFilter::Exec.new(filename)
        filter.update_option ['--pp', '-eruby']
        records, src, _comments = filter.record_records
        records = records.first # only 1 process results
        @records[filename] = [records, filter.make_line_records(records), src]
        send_notice 'rstfilter/done'
        unless filter.output.empty?
          send_notice 'rstfilter/output', output: "# Output for #{filename}\n\n#{filter.output}"
        end
        send_request 'workspace/inlayHint/refresh'
      rescue CancelRequest
        # canceled
      rescue SyntaxError => e
        send_notice 'rstfilter/output', output: "SyntaxError on #{filename}:\n#{e.inspect}"
        send_notice 'rstfilter/done'
      rescue Exception => e
        send_notice 'rstfilter/output', output: "Error on #{filename}:\n#{e.inspect}\n#{e.backtrace.join("\n")}#{filter.output}"
        send_notice 'rstfilter/done'
      ensure
        @running[filename] = nil
      end
    end

    def clear_record filename
      @records[filename] = nil
      if th = @running[filename]
        @running[filename] = nil
        th.raise CancelRequest
      end
    end

    def uri2filename uri
      case uri
      when /^file:\/\/(.+)/
        $1
      else
        raise "unknown uri: #{uri}"
      end
    end

    def handle_notification req
      case req[:method]
      when 'initialized'
        send_notice 'rstfilter/version', {
          version: "#{::RstFilter::VERSION} on #{RUBY_DESCRIPTION}",
        }
      when 'textDocument/didOpen',
           'textDocument/didSave'
        #filename = uri2filename req.dig(:params, :textDocument, :uri)
        #take_record filename
        # do nothing
      when 'textDocument/didClose',
           'textDocument/didChange'
        filename = uri2filename req.dig(:params, :textDocument, :uri)
        clear_record filename
      when 'rstfilter/start'
        filename = req.dig(:params, :path)
        take_record filename
      when '$/cancelRequest'
        # ignore
      when 'exit'
        exit(@exit_code)
      else
        raise
      end
    end
  end
end
