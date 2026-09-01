// CRC7 (poly x^7 + x^3 + 1, i.e. 0x09) over a 40-bit SD command frame: the 2
// header bits (start=0, transmission=1), 6-bit command index, and 32-bit
// argument, MSB first. This is exactly the bit range the SD spec covers with
// CRC7 for CMD frames: the command's own start/stop bits and the trailing
// CRC field itself are not part of the input.
module crc7 (
    input  wire [39:0] data,
    output wire [ 6:0] crc
);

  function [6:0] crc7_calc(input [39:0] data);
    integer i;
    reg [6:0] c;
    reg din;
    begin
      c = 7'h00;
      for (i = 39; i >= 0; i = i - 1) begin
        din = data[i] ^ c[6];
        c   = {c[5:0], 1'b0};
        if (din) c = c ^ 7'h09;
      end
      crc7_calc = c;
    end
  endfunction

  assign crc = crc7_calc(data);

endmodule
