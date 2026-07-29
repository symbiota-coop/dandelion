# Patch for rack-utf8_sanitizer to handle nil inputs in Ruby 3.4+ / Rack 3.x
# The original gem doesn't guard against nil values in strip_byte_order_mark
# which causes NoMethodError: undefined method `start_with?' for nil:NilClass
module Rack
  class UTF8Sanitizer
    def strip_byte_order_mark(input)
      return '' if input.nil?
      return input unless input.start_with?(UTF8_BOM)

      input.byteslice(UTF8_BOM.bytesize..-1)
    end
  end
end
