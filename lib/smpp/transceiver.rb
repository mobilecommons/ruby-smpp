# encoding: UTF-8

# The SMPP Transceiver maintains a bidirectional connection to an SMSC.
# Provide a config hash with connection options to get started.
# See the sample_gateway.rb for examples of config values.
# The transceiver accepts a delegate object that may implement
# the following (all optional) methods:
#
#   mo_received(transceiver, pdu)
#   delivery_report_received(transceiver, pdu)
#   message_accepted(transceiver, mt_message_id, pdu)
#   message_rejected(transceiver, mt_message_id, pdu)
#   bound(transceiver)
#   unbound(transceiver)

class Smpp::Transceiver < Smpp::Base

  # Send an MT SMS message. Delegate will receive message_accepted callback when SMSC
  # acknowledges, or the message_rejected callback upon error
  def send_mt(message_id, source_addr, destination_addr, short_message, options={})
    logger.debug "Sending MT: #{short_message}"
    if @state == :bound
      pdu = Pdu::SubmitSm.new(source_addr, destination_addr, short_message, options)
      write_pdu pdu

      # keep the message ID so we can associate the SMSC message ID with our message
      # when the response arrives.
      @ack_ids[pdu.sequence_number] = message_id
    else
      raise InvalidStateException, "Transceiver is unbound. Cannot send MT messages."
    end
  end

  # Send a concatenated message with a body of > 160 characters as multiple messages.
  def send_concat_mt(message_id, source_addr, destination_addr, message, options = {})

    if @state == :bound
      # Split the message into parts of 152 characters. (160 - 8 characters for UDH because we use 16 bit message_id) or
      # Split it to 66 parts in case of UCS2 encodeing (70 - 8 characters for UDH because we use 16 bit message_id). 
      parts = []
      # If message body is ucs2 encoded we will convert it back on the fly to utf8 then we will
      # split it to parts and then encode each part back to binary
      if options[:data_coding] == 8
        shadow_message = message
        shadow_message.force_encoding(Encoding::UCS_2BE)
#       Commenting this line is better for emoji due to emojis take 2 ucs2 chars 
        shadow_message = shadow_message.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace, :replace => '')
        shadow_message.chars.to_a.each_slice(Smpp::Transceiver.get_message_part_size(options) - 1) do |part|
          part = part.join
          part = part.encode(Encoding::UCS_2BE, :invalid => :replace, :undef => :replace, :replace => '')
          part.force_encoding(Encoding::BINARY)
          parts << part
        end
      else
        while message.size > 0 do  
            parts << message.slice!(0...(Smpp::Transceiver.get_message_part_size(options) - 1))
        end
      end  
            
       0.upto(parts.size-1) do |i|  
        # New encoding style taken from 
        # https://github.com/Eloi/ruby-smpp/commit/6c2c20297cde4d3473c4c8362abed6ded6d59c09?diff=unified
        udh = [ 6,         # UDH is 5 bytes.
                8, 4,       # This is a concatenated message
                message_id % 65535, # Ensure single byte message_id
                parts.size, # How many parts this message consists of
                i + 1         # This is part i+1
               ].pack('CCCS>CC')
        
        
        options[:esm_class] = 64 # This message contains a UDH header.
        options[:udh] = udh
        pdu = Pdu::SubmitSm.new(source_addr, destination_addr, parts[i], options)
        
        write_pdu pdu

        # This is definately a bit hacky - multiple PDUs are being associated with a single
        # message_id.
         @ack_ids[pdu.sequence_number] = {:message_id => message_id, :part_number => i + 1, :parts_size => parts.size }
       end
    else
      raise InvalidStateException, "Transceiver is unbound. Cannot send MT messages."
    end
  end

  # Send  MT SMS message for multiple dest_address
  # Author: Abhishek Parolkar (abhishek[at]parolkar.com)
  # USAGE: $tx.send_multi_mt(123, "9100000000", ["9199000000000","91990000000001","9199000000002"], "Message here")
  def send_multi_mt(message_id, source_addr, destination_addr_arr, short_message, options={})
    logger.debug "Sending Multiple MT: #{short_message}"
    if @state == :bound
      pdu = Pdu::SubmitMulti.new(source_addr, destination_addr_arr, short_message, options)
      write_pdu pdu
      
      # keep the message ID so we can associate the SMSC message ID with our message
      # when the response arrives.
      @ack_ids[pdu.sequence_number] = message_id
    else
      raise InvalidStateException, "Transceiver is unbound. Cannot send MT messages."
    end
  end

  # Send BindTransceiverResponse PDU.
  def send_bind
    raise IOError, 'Receiver already bound.' unless unbound?
    pdu = Pdu::BindTransceiver.new(
        @config[:system_id],
        @config[:password],
        @config[:system_type],
        @config[:source_ton],
        @config[:source_npi],
        @config[:source_address_range])
    write_pdu(pdu)
  end

  # Use data_coding to find out what message part size we can use
  # http://en.wikipedia.org/wiki/SMS#Message_size
  def self.get_message_part_size options
    return 153 if options[:data_coding].nil?
    return 153 if options[:data_coding] == 0
    return 134 if options[:data_coding] == 3
    return 134 if options[:data_coding] == 5
    return 134 if options[:data_coding] == 6
    return 134 if options[:data_coding] == 7
    return 67  if options[:data_coding] == 8
    return 153
  end
end
