// Testbench for sd_block_read (src/sd_block_read.v). Mocks the byte-level
// spi interface, same isolation style as sim/sdcard_tb.v: the internal
// sd_cmd instance's frame-building is already covered by sim/sd_cmd_tb.v,
// so the outgoing CMD17 frame bytes are don't-care here.
module sd_block_read_tb;

  reg clk, reset, start_signal;
  reg [31:0] sector;

  wire done_signal, error;
  wire [7:0] first_byte;
  wire cs;

  wire spi_start;
  wire [7:0] spi_byte_to_send;
  reg spi_done;
  reg [7:0] spi_byte_received;

  // TOKEN_MAX_BYTES=4 keeps the timeout section short.
  sd_block_read #(
      .TOKEN_MAX_BYTES(4)
  ) my_dut (
      .clk(clk),
      .reset(reset),
      .start_signal(start_signal),
      .sector(sector),
      .done_signal(done_signal),
      .error(error),
      .first_byte(first_byte),
      .cs(cs),
      .spi_start(spi_start),
      .spi_byte_to_send(spi_byte_to_send),
      .spi_done(spi_done),
      .spi_byte_received(spi_byte_received)
  );

  always #5 clk = ~clk;

`ifdef APIO_SIM
  initial $dumpvars(0, sd_block_read_tb);
`endif

  task automatic do_reset;
    begin
      reset = 1;
      @(posedge clk);
      #1;
      reset = 0;
      @(posedge clk);
    end
  endtask

  task automatic mock_byte;
    input [7:0] rx_byte;
    output [7:0] captured_tx;
    begin
      while (!spi_start) begin
        @(posedge clk);
        #1;
      end
      captured_tx = spi_byte_to_send;
      spi_byte_received = rx_byte;
      spi_done = 1;
      @(posedge clk);
      #1;
      spi_done = 0;
    end
  endtask

  task automatic mock_fill;
    input [7:0] value;
    input integer count;
    integer i;
    reg [7:0] tx;
    begin
      for (i = 0; i < count; i = i + 1) mock_byte(value, tx);
    end
  endtask

  // Sends 6 don't-care CMD17 frame bytes then the 5 response bytes sd_cmd
  // always captures (R1 + 4 trailing, ignored for CMD17).
  task automatic cmd17_response;
    input [7:0] r1;
    reg [7:0] tx;
    begin
      mock_fill(8'hFF, 6);
      mock_byte(r1, tx);
      mock_fill(8'hFF, 4);
    end
  endtask

  initial begin
    integer fail_count;
    integer i;
    reg [7:0] tx;

    fail_count = 0;
    clk = 0;
    spi_done = 0;
    spi_byte_received = 8'h00;

    do_reset();

    // Section 1: happy path. R1=0x00, 2 filler bytes before the 0xFE token,
    // then 512 data bytes (first = 'a' = 0x61, rest arbitrary) + 2 CRC bytes.
    if (cs !== 1'b1) begin
      $display("FAIL section1 cs before start: cs=%0b, expected 1 (deasserted)", cs);
      fail_count = fail_count + 1;
    end

    sector = 32'd1;
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;

    if (cs !== 1'b0) begin
      $display("FAIL section1 cs after start: cs=%0b, expected 0 (asserted)", cs);
      fail_count = fail_count + 1;
    end else $display("PASS section1 cs asserted low after start");

    cmd17_response(8'h00);

    mock_fill(8'hFF, 2);  // NCR-style filler before the data token
    mock_byte(8'hFE, tx);  // data start token

    mock_byte(8'h61, tx);  // first data byte: 'a'
    for (i = 1; i < 512; i = i + 1) mock_byte(8'h00, tx);
    mock_byte(8'hAA, tx);  // CRC16 byte 1 (unchecked)
    mock_byte(8'hBB, tx);  // CRC16 byte 2 (unchecked)

    // No extra edge here: the S_CRC->S_DONE transition reacts to spi_done
    // directly (no sd_cmd hierarchy lag), and done_signal/cs are both set in
    // that same branch, so mock_byte's own settling point already has both
    // visible. Waiting an extra edge would let the one-cycle done_signal
    // pulse decay before this check saw it.
    if (done_signal !== 1'b1) begin
      $display("FAIL section1 done_signal did not pulse on the expected cycle");
      fail_count = fail_count + 1;
    end

    if (error === 1'b0 && first_byte === 8'h61 && cs === 1'b1)
      $display("PASS section1 happy path: error=%0b, first_byte=0x%02h, cs=%0b (expected error=0, first_byte=0x61, cs=1)",
                error, first_byte, cs);
    else begin
      $display("FAIL section1 happy path: error=%0b, first_byte=0x%02h, cs=%0b (expected error=0, first_byte=0x61, cs=1)",
                error, first_byte, cs);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 2: CMD17 rejected (R1 != 0x00) -> error.
    sector = 32'd1;
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    cmd17_response(8'h05);
    // Two extra edges: one for sd_block_read to see sd_cmd's done_signal
    // (a different always block, one cycle of hierarchy lag), one more for
    // the S_ERROR state's own body to run and release cs.
    @(posedge clk);
    #1;
    @(posedge clk);
    #1;

    if (error === 1'b1 && cs === 1'b1)
      $display("PASS section2 CMD17 rejected: error=%0b, cs=%0b (expected error=1, cs=1)", error, cs);
    else begin
      $display("FAIL section2 CMD17 rejected: error=%0b, cs=%0b (expected error=1, cs=1)", error, cs);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 3: data error token (upper nibble 0000, not 0xFE) -> error.
    sector = 32'd1;
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    cmd17_response(8'h00);
    mock_byte(8'h09, tx);  // data error token
    @(posedge clk);
    #1;

    if (error === 1'b1 && cs === 1'b1)
      $display("PASS section3 data error token: error=%0b, cs=%0b (expected error=1, cs=1)", error, cs);
    else begin
      $display("FAIL section3 data error token: error=%0b, cs=%0b (expected error=1, cs=1)", error, cs);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 4: token never arrives -> timeout after TOKEN_MAX_BYTES=4 filler bytes.
    sector = 32'd1;
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    cmd17_response(8'h00);
    mock_fill(8'hFF, 4);
    @(posedge clk);
    #1;

    if (error === 1'b1 && cs === 1'b1)
      $display("PASS section4 token timeout: error=%0b, cs=%0b (expected error=1, cs=1)", error, cs);
    else begin
      $display("FAIL section4 token timeout: error=%0b, cs=%0b (expected error=1, cs=1)", error, cs);
      fail_count = fail_count + 1;
    end

    if (fail_count > 0) $fatal(1, "%0d check(s) FAILED", fail_count);
    else $display("All checks PASSED");
    $finish;
  end

endmodule
