require 'stringio'

class ::BasicObject
  if ::ENV['RSTFILTER_PP']
    require 'pp'
    def __rst_inspect_body__
      ::PP.pp(self, '')
    end
  else
    def __rst_inspect_body__
      self.inspect
    end
  end

  def __rst_inspect__
    begin
      __rst_inspect_body__
    rescue Exception => e
      "!! __rst_inspect__ failed: #{e}"
    end
  end

  def __rst_record__ begin_line, begin_col, end_line, end_col
    # p [begin_line, begin_col, end_line, end_col]
    out, err = *[$__rst_filter_captured_out, $__rst_filter_captured_err].map{|o|
      str = o.string
      o.string = ''
      str
    } if $__rst_filter_captured_out
    $__rst_record[end_line][end_col] = [self.__rst_inspect__, out, err]
    self
  end
end

$__rst_record = Hash.new{|h, k| h[k] = []}

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

if ENV['RSTFILTER_SHOW_EXCEPTIONS']
  filename = ENV['RSTFILTER_FILENAME']
  $__rst_filter_raise_captor = TracePoint.new(:raise) do |tp|
    caller_locations.each{|loc|
      if loc.path == filename
        $__rst_record[loc.lineno][0] = [tp.raised_exception, '', '']
        break
      end
    }
  end
  $__rst_filter_raise_captor.enable
else
  $__rst_filter_raise_captor = nil
end

if path = ENV['RSTFILTER_RECORD_PATH']
  # inter-process communication

  END{
    open(path, 'wb'){|f|
      Marshal.dump($__rst_record.to_a.to_h, f)
    }
  }

  class RubyVM::InstructionSequence
    RST_FILENAME = ENV['RSTFILTER_FILENAME']
    RST_MOD_SRC = File.read(ENV['RSTFILTER_MOD_SRC_PATH'])
    @found = false
    p [RST_FILENAME, ENV['RSTFILTER_MOD_SRC_PATH']]
    def self.translate iseq
      if !@found && iseq.path == RST_FILENAME && iseq.label == "<main>"
        @found = true
        RubyVM::InstructionSequence.compile RST_MOD_SRC, RST_FILENAME
      end
    end
  end
end
