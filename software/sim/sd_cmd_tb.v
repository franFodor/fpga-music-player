// Testbench for the sd_cmd module (src/sd_cmd.v).
// Mocks the external spi module directly (drives spi_done/spi_byte_received,
// checks spi_start/spi_byte_to_send) rather than instantiating the real
// spi.v, matching the style used for the other testbenches in this repo:
// one module's neighbor is faked so its own behavior is checked in isolation.
module sd_cmd_tb;

  reg clk, reset, start_signal;
  reg [5:0] cmd_index;
  reg [31:0] arg;

  wire done_signal, timeout;
  wire [39:0] response;

  wire spi_start;
  wire [7:0] spi_byte_to_send;
  reg spi_done;
  reg [7:0] spi_byte_received;

  // NCR_MAX_BYTES=4 keeps the timeout section short; frame-send timing does
  // not depend on this parameter so every other section is unaffected.
  sd_cmd #(
      .NCR_MAX_BYTES(4)
  ) my_dut (
      .clk(clk),
      .reset(reset),
      .start_signal(start_signal),
      .cmd_index(cmd_index),
      .arg(arg),
      .done_signal(done_signal),
      .timeout(timeout),
      .response(response),
      .spi_start(spi_start),
      .spi_byte_to_send(spi_byte_to_send),
      .spi_done(spi_done),
      .spi_byte_received(spi_byte_received)
  );

  always #5 clk = ~clk;

`ifdef APIO_SIM
  initial $dumpvars(0, sd_cmd_tb);
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

  // Waits for the DUT's spi_start pulse, captures the byte it wanted to
  // send, then hands back rx_byte as if a real spi module had captured it
  // (the mock transfer takes zero extra clk cycles since sd_cmd only reacts
  // to the spi_done pulse, never counts cycles itself). spi_start is only
  // ever asserted for exactly one clk cycle. Reading it right after
  // @(posedge clk) would race the DUT's own nonblocking update for that
  // same edge and see the stale pre-edge value, so every read (in the loop
  // guard and after it) is pushed 1 time unit past the edge, into the
  // region where that edge's updates have already settled.
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

  // Pulses start_signal for exactly one clk edge. Deliberately does not wait
  // an extra idle edge before that (unlike spi_tb's equivalent task): the
  // DUT's own spi_start pulse it triggers is also only one clk cycle wide,
  // and the first mock_byte call runs immediately after this returns, so an
  // extra edge here would let that pulse decay before anything catches it.
  task automatic do_start;
    input [5:0] index;
    input [31:0] a;
    begin
      cmd_index = index;
      arg = a;
      start_signal = 1;
      @(posedge clk);
      #1;
      start_signal = 0;
    end
  endtask

  initial begin
    integer fail_count;
    integer i;
    reg [7:0] tx;
    reg [7:0] expected_frame[0:5];
    reg frame_ok;

    fail_count = 0;
    clk = 0;
    spi_done = 0;
    spi_byte_received = 8'h00;

    do_reset();

    // Section 1: CMD0 framing + immediate R1 (no NCR filler)
    // Known frame for CMD0 arg=0 (also checked independently in crc7_tb):
    // 0x40 00 00 00 00 0x95.
    expected_frame[0] = 8'h40;
    expected_frame[1] = 8'h00;
    expected_frame[2] = 8'h00;
    expected_frame[3] = 8'h00;
    expected_frame[4] = 8'h00;
    expected_frame[5] = 8'h95;

    do_start(6'd0, 32'h00000000);

    frame_ok = 1;
    for (i = 0; i <= 5; i = i + 1) begin
      mock_byte(8'hFF, tx);  // rx value irrelevant while sending the command frame
      if (tx !== expected_frame[i]) begin
        $display("FAIL section1 frame byte %0d: sent 0x%02h, expected 0x%02h", i, tx, expected_frame[i]);
        frame_ok = 0;
      end
    end
    if (frame_ok) $display("PASS section1 CMD0 frame: all 6 bytes matched 0x40 00 00 00 00 95");
    else fail_count = fail_count + 1;

    mock_byte(8'h01, tx);  // R1 = 0x01 (idle state), arrives with no filler
    mock_byte(8'hAA, tx);
    mock_byte(8'hBB, tx);
    mock_byte(8'hCC, tx);
    mock_byte(8'hDD, tx);
    @(posedge clk);
    #1;

    // done_signal/timeout/response are registered together; sampled the
    // cycle after the last mock_byte call, once they have settled.
    if (response == 40'h01_AA_BB_CC_DD && timeout == 1'b0)
      $display("PASS section1 response: response=0x%010h, timeout=%0b (expected 0x01aabbccdd, timeout=0)", response, timeout);
    else begin
      $display("FAIL section1 response: response=0x%010h, timeout=%0b (expected 0x01aabbccdd, timeout=0)", response, timeout);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 2: NCR filler skip
    // 3 filler bytes (bit7=1) before the real R1, well under NCR_MAX_BYTES=4,
    // so this must NOT time out and must still land on the correct R1 byte.
    do_start(6'd8, 32'h000001AA);  // CMD8-shaped call; frame bytes not re-checked here

    for (i = 0; i <= 5; i = i + 1) mock_byte(8'hFF, tx);  // send the frame, ignore tx here

    mock_byte(8'hFF, tx);  // filler 1
    mock_byte(8'hFF, tx);  // filler 2
    mock_byte(8'hFF, tx);  // filler 3
    mock_byte(8'h01, tx);  // real R1
    mock_byte(8'h00, tx);
    mock_byte(8'h00, tx);
    mock_byte(8'h01, tx);
    mock_byte(8'hAA, tx);
    @(posedge clk);
    #1;

    if (response == 40'h01_00_00_01_AA && timeout == 1'b0)
      $display("PASS section2 NCR filler skip: response=0x%010h, timeout=%0b (expected R1=0x01, trailing 00 00 01 aa, timeout=0)", response, timeout);
    else begin
      $display("FAIL section2 NCR filler skip: response=0x%010h, timeout=%0b (expected R1=0x01, trailing 00 00 01 aa, timeout=0)", response, timeout);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 3: NCR timeout
    // All NCR_MAX_BYTES=4 poll bytes come back as filler (bit7=1); DUT must
    // give up and flag timeout instead of reading 4 more trailing bytes.
    do_start(6'd55, 32'h00000000);

    for (i = 0; i <= 5; i = i + 1) mock_byte(8'hFF, tx);  // send the frame

    mock_byte(8'hFF, tx);
    mock_byte(8'hFF, tx);
    mock_byte(8'hFF, tx);
    mock_byte(8'hFF, tx);
    @(posedge clk);
    #1;

    if (timeout == 1'b1)
      $display("PASS section3 NCR timeout: timeout=%0b after 4 consecutive filler bytes (NCR_MAX_BYTES=4)", timeout);
    else begin
      $display("FAIL section3 NCR timeout: timeout=%0b, expected 1 after 4 consecutive filler bytes", timeout);
      fail_count = fail_count + 1;
    end

    if (fail_count > 0) $fatal(1, "%0d check(s) FAILED", fail_count);
    else $display("All checks PASSED");
    $finish;
  end

endmodule
