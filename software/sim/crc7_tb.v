// Testbench for the crc7 module (src/crc7.v).
// Pure combinational module: checked against known SD command byte
// sequences (widely published in SD SPI-mode init tutorials), since a wrong
// polynomial or bit order would only surface on real hardware as a card
// that never leaves idle state.
module crc7_tb;

  reg  [39:0] data;
  wire [ 6:0] crc;

  crc7 my_dut (
      .data(data),
      .crc (crc)
  );

  initial begin
    integer fail_count;
    fail_count = 0;

    // CMD0 (GO_IDLE_STATE), arg=0x00000000. Known full byte sequence is
    // 0x40 00 00 00 00 0x95 -> crc7=0x95>>1=0x4A (stop bit is the byte's LSB).
    data = {8'h40, 32'h00000000};
    #1;
    if (crc == 7'h4A)
      $display("PASS CMD0 (arg=0x00000000): crc=0x%02h, matches expected 0x4A", crc);
    else begin
      $display("FAIL CMD0 (arg=0x00000000): crc=0x%02h, expected 0x4A", crc);
      fail_count = fail_count + 1;
    end

    // CMD8 (SEND_IF_COND), arg=0x000001AA (voltage 2.7-3.6V, check pattern
    // 0xAA). Known full byte sequence is 0x48 00 00 01 AA 0x87 -> crc7=0x43.
    data = {8'h48, 32'h000001AA};
    #1;
    if (crc == 7'h43)
      $display("PASS CMD8 (arg=0x000001AA): crc=0x%02h, matches expected 0x43", crc);
    else begin
      $display("FAIL CMD8 (arg=0x000001AA): crc=0x%02h, expected 0x43", crc);
      fail_count = fail_count + 1;
    end

    // CMD17 (READ_SINGLE_BLOCK), arg=0x00000000 (block 0). Exercises a
    // non-CMD0/CMD8 command index with the argument field all zero, the
    // combination sd_cmd.v will actually issue for reading the first block.
    // Expected value independently computed (not from a published tutorial
    // like the two vectors above) with the same MSB-first CRC7 algorithm,
    // cross-checked against those two known-good vectors first.
    data = {8'h51, 32'h00000000};
    #1;
    if (crc == 7'h2A)
      $display("PASS CMD17 (arg=0x00000000): crc=0x%02h, matches expected 0x2A", crc);
    else begin
      $display("FAIL CMD17 (arg=0x00000000): crc=0x%02h, expected 0x2A", crc);
      fail_count = fail_count + 1;
    end

    if (fail_count > 0) $fatal(1, "%0d check(s) FAILED", fail_count);
    else $display("All checks PASSED");
    $finish;
  end

endmodule
