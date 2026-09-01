// Testbench for the sdcard module (src/sdcard.v). Mocks the byte-level spi
// interface directly (drives spi_done/spi_byte_received, checks
// spi_start/spi_byte_to_send), same isolation style as sim/sd_cmd_tb.v: the
// internal sd_cmd instance's frame-building was already proven generic there,
// so only the CMD0 frame is re-checked here as a sanity check that the right
// index/arg reached it; every other command's outgoing bytes are don't-care.
module sdcard_tb;

  reg clk, reset, start_signal;

  wire ready, error;
  wire [3:0] error_code;
  wire cs;
  wire [5:0] half_period;

  wire spi_start;
  wire [7:0] spi_byte_to_send;
  reg spi_done;
  reg [7:0] spi_byte_received;

  // ACMD41_MAX_RETRIES=5 keeps the timeout section short while still leaving
  // room for the happy-path section's 2 not-ready-yet loops before success.
  sdcard #(
      .ACMD41_MAX_RETRIES(5)
  ) my_dut (
      .clk(clk),
      .reset(reset),
      .start_signal(start_signal),
      .ready(ready),
      .error(error),
      .error_code(error_code),
      .cs(cs),
      .half_period(half_period),
      .spi_start(spi_start),
      .spi_byte_to_send(spi_byte_to_send),
      .spi_done(spi_done),
      .spi_byte_received(spi_byte_received)
  );

  always #5 clk = ~clk;

`ifdef APIO_SIM
  initial $dumpvars(0, sdcard_tb);
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

  // Same race-avoidance reasoning as sd_cmd_tb's mock_byte: every read is
  // pushed 1 time unit past the edge so it sees that edge's settled values.
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

  task automatic mock_dummy_bytes;
    input [3:0] count;
    integer i;
    reg [7:0] tx;
    begin
      for (i = 0; i < count; i = i + 1) mock_byte(8'hFF, tx);
    end
  endtask

  // Sends 6 don't-care frame bytes then the 5 response bytes sd_cmd always
  // captures (R1 + 4 trailing), regardless of whether the caller cares about
  // the trailing bytes.
  task automatic cmd_exchange;
    input [7:0] r1;
    input [7:0] tr1;
    input [7:0] tr2;
    input [7:0] tr3;
    input [7:0] tr4;
    integer i;
    reg [7:0] tx;
    begin
      for (i = 0; i < 6; i = i + 1) mock_byte(8'hFF, tx);
      mock_byte(r1, tx);
      mock_byte(tr1, tx);
      mock_byte(tr2, tx);
      mock_byte(tr3, tx);
      mock_byte(tr4, tx);
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

    // Section 1: happy path. Dummy clocks -> CMD0 -> CMD8 -> ACMD41 loops
    // twice (still idle) then succeeds -> CMD58 with CCS=1 -> ready.
    if (cs !== 1'b1) begin
      $display("FAIL section1 cs before start: cs=%0b, expected 1 (deasserted)", cs);
      fail_count = fail_count + 1;
    end

    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;

    mock_dummy_bytes(10);

    if (cs !== 1'b1) begin
      $display("FAIL section1 cs during dummy phase: cs=%0b, expected 1 (deasserted)", cs);
      fail_count = fail_count + 1;
    end else $display("PASS section1 cs held high through dummy phase");

    // CMD0 frame: known bytes for arg=0 (also checked independently in
    // crc7_tb and sd_cmd_tb): 0x40 00 00 00 00 0x95.
    expected_frame[0] = 8'h40;
    expected_frame[1] = 8'h00;
    expected_frame[2] = 8'h00;
    expected_frame[3] = 8'h00;
    expected_frame[4] = 8'h00;
    expected_frame[5] = 8'h95;

    frame_ok = 1;
    for (i = 0; i <= 5; i = i + 1) begin
      mock_byte(8'hFF, tx);
      if (tx !== expected_frame[i]) begin
        $display("FAIL section1 CMD0 frame byte %0d: sent 0x%02h, expected 0x%02h", i, tx, expected_frame[i]);
        frame_ok = 0;
      end
    end
    if (frame_ok) $display("PASS section1 CMD0 frame: all 6 bytes matched 0x40 00 00 00 00 95");
    else fail_count = fail_count + 1;

    mock_byte(8'h01, tx);  // R1 = 0x01 (idle)
    mock_byte(8'hFF, tx);
    mock_byte(8'hFF, tx);
    mock_byte(8'hFF, tx);
    mock_byte(8'hFF, tx);
    @(posedge clk);
    #1;

    if (cs !== 1'b0) begin
      $display("FAIL section1 cs after CMD0: cs=%0b, expected 0 (asserted)", cs);
      fail_count = fail_count + 1;
    end else $display("PASS section1 cs asserted low after CMD0");

    // CMD8: R1=0x01 idle, trailing echo 0x01/0xAA (voltage/check pattern).
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'h01, 8'hAA);

    // ACMD41 round 1: still idle (R1=0x01) -> must loop back through CMD55.
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD55
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD41, still idle

    // ACMD41 round 2: ready (R1=0x00) -> proceed to CMD58.
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD55
    cmd_exchange(8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD41, ready

    // CMD58: R1=0x00, OCR byte1=0xC0 (CCS=1, bit6 of the trailing byte).
    cmd_exchange(8'h00, 8'hC0, 8'h00, 8'h00, 8'h00);
    @(posedge clk);
    #1;

    if (ready === 1'b1 && error === 1'b0 && half_period === my_dut.FULL_HALF_PERIOD)
      $display("PASS section1 init succeeded: ready=%0b, error=%0b, half_period=%0d (expected ready=1, error=0, half_period=%0d)",
                ready, error, half_period, my_dut.FULL_HALF_PERIOD);
    else begin
      $display("FAIL section1 init succeeded: ready=%0b, error=%0b, half_period=%0d (expected ready=1, error=0, half_period=%0d)",
                ready, error, half_period, my_dut.FULL_HALF_PERIOD);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 2: CMD0 fails (unexpected R1) -> error, ERR_CMD0.
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    mock_dummy_bytes(10);
    cmd_exchange(8'h05, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // R1=0x05, not the expected 0x01
    @(posedge clk);
    #1;

    if (error === 1'b1 && ready === 1'b0 && error_code === my_dut.ERR_CMD0)
      $display("PASS section2 CMD0 failure: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_CMD0=%0d)",
                error, ready, error_code, my_dut.ERR_CMD0);
    else begin
      $display("FAIL section2 CMD0 failure: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_CMD0=%0d)",
                error, ready, error_code, my_dut.ERR_CMD0);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 3: CMD8 fails (illegal-command bit set, e.g. old v1/MMC card)
    // -> error, ERR_CMD8.
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    mock_dummy_bytes(10);
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD0 ok
    cmd_exchange(8'h05, 8'hFF, 8'hFF, 8'h01, 8'hAA);  // CMD8: R1=0x05 (illegal cmd bit set)
    @(posedge clk);
    #1;

    if (error === 1'b1 && ready === 1'b0 && error_code === my_dut.ERR_CMD8)
      $display("PASS section3 CMD8 failure: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_CMD8=%0d)",
                error, ready, error_code, my_dut.ERR_CMD8);
    else begin
      $display("FAIL section3 CMD8 failure: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_CMD8=%0d)",
                error, ready, error_code, my_dut.ERR_CMD8);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 4: ACMD41 never reports ready -> ERR_ACMD41_TIMEOUT after
    // ACMD41_MAX_RETRIES=5 rounds.
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    mock_dummy_bytes(10);
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD0 ok
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'h01, 8'hAA);  // CMD8 ok
    for (i = 0; i < 5; i = i + 1) begin
      cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD55
      cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD41, always idle
    end
    @(posedge clk);
    #1;

    if (error === 1'b1 && ready === 1'b0 && error_code === my_dut.ERR_ACMD41_TIMEOUT)
      $display("PASS section4 ACMD41 timeout: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_ACMD41_TIMEOUT=%0d)",
                error, ready, error_code, my_dut.ERR_ACMD41_TIMEOUT);
    else begin
      $display("FAIL section4 ACMD41 timeout: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_ACMD41_TIMEOUT=%0d)",
                error, ready, error_code, my_dut.ERR_ACMD41_TIMEOUT);
      fail_count = fail_count + 1;
    end

    do_reset();

    // Section 5: CMD58 reports CCS=0 (byte-addressed SDSC card) -> treated
    // as unsupported, ERR_NOT_HIGH_CAPACITY.
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    mock_dummy_bytes(10);
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD0 ok
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'h01, 8'hAA);  // CMD8 ok
    cmd_exchange(8'h01, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD55
    cmd_exchange(8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF);  // CMD41, ready immediately
    cmd_exchange(8'h00, 8'h00, 8'h00, 8'h00, 8'h00);  // CMD58: OCR byte1 bit6 (CCS) clear
    @(posedge clk);
    #1;

    if (error === 1'b1 && ready === 1'b0 && error_code === my_dut.ERR_NOT_HIGH_CAPACITY)
      $display("PASS section5 CCS=0 rejected: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_NOT_HIGH_CAPACITY=%0d)",
                error, ready, error_code, my_dut.ERR_NOT_HIGH_CAPACITY);
    else begin
      $display("FAIL section5 CCS=0 rejected: error=%0b, ready=%0b, error_code=%0d (expected error=1, ready=0, ERR_NOT_HIGH_CAPACITY=%0d)",
                error, ready, error_code, my_dut.ERR_NOT_HIGH_CAPACITY);
      fail_count = fail_count + 1;
    end

    if (fail_count > 0) $fatal(1, "%0d check(s) FAILED", fail_count);
    else $display("All checks PASSED");
    $finish;
  end

endmodule
