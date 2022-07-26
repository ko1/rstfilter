require 'stringio'

if defined?(RSTFILTER__)
  Object.remove_const :RSTFILTER__
end

class RSTFILTER__
  SHOW_EXCEPTION = ENV['RSTFILTER_SHOW_EXCEPTIONS']

  if ::ENV['RSTFILTER_PP']
    require 'pp'
    def self.__rst_inspect_body__ val
      ::PP.pp(val, '')
    end
  else
    def self.__rst_inspect_body__ val
      val.inspect
    end
  end

  def self.__rst_inspect__ val
    begin
      __rst_inspect_body__ val
    rescue Exception => e
      "!! __rst_inspect__ failed: #{e}"
    end
  end

  @@records = {}

  def self.records
    @@records
  end

  def self.clear
    @@records.clear
  end

  def self.write begin_line, begin_col, end_line, end_col, val, prefix
    # p [begin_line, begin_col, end_line, end_col]
    out, err = *[$__rst_filter_captured_out, $__rst_filter_captured_err].map{|o|
      str = o.string
      o.string = ''
      str
    } if $__rst_filter_captured_out

    @@records[[begin_line, begin_col, end_line, end_col]] = ["#{prefix}#{__rst_inspect__(val)}", out, err]
  end

  def self.record begin_line, begin_col, end_line, end_col
    r = yield
    write begin_line, begin_col, end_line, end_col, r, nil
    r
  rescue Exception => e
    write begin_line, begin_col, end_line, end_col, e, 'raised '
    raise
  end
end

if ENV['RSTFILTER_SHOW_OUTPUT']
  $__rst_filter_prev_out = $stdout
  $__rst_filter_prev_err = $stderr

  $__rst_filter_captured_out = $stdout = StringIO.new
  if false # debug
    $__rst_filter_captured_err = $captured_out
  else
    $__rst_filter_captured_err = $stderr = StringIO.new
  end
else
  $__rst_filter_prev_out = $__rst_filter_prev_err = nil
  $__rst_filter_captured_out = $__rst_filter_captured_err = nil
end

if path = ENV['RSTFILTER_RECORD_PATH']
  # inter-process communication

  END{
    open(path, 'wb'){|f|
      f.write Marshal.dump(::RSTFILTER__.records)
    }
  }

  if defined?(RubyVM::InstructionSequence)
    class RubyVM::InstructionSequence
      RST_FILENAME = ENV['RSTFILTER_FILENAME']
      RST_MOD_SRC = File.read(ENV['RSTFILTER_MOD_SRC_PATH'])
      @found = false

      def self.translate iseq
        if !@found && iseq.path == RST_FILENAME && (iseq.label == "<main>" || iseq.label == '<top (required)>')
          @found = true
          RubyVM::InstructionSequence.compile RST_MOD_SRC, RST_FILENAME
        end
      end
    end
  end
end
