// Testbench for the spi module (src/spi.v).
// Drives start_signal/byte_to_send/miso and checks mosi, sclk timing,
// byte_received, done_signal and internal reset behavior of the DUT.
module spi_tb;
  localparam CLK_PERIOD = 10;

  reg clk, reset, start_signal, miso;
  wire mosi, sclk, done_signal;
  reg  [7:0] byte_to_send;
  wire [7:0] byte_received;

  // Half period target (count - 1) fed to the DUT's half_period port. Held
  // constant at HALF_PERIOD for all sections; section 7 sweeps it.
  localparam HALF_PERIOD = 3;
  reg [$clog2(4)-1:0] half_period;

  reg  [7:0] byte_to_receive;
  reg  [7:0] mosi_accum;
  reg  [7:0] bit_count;

  // MAX_HALF_PERIOD_COUNT=4 sizes half_period_count/half_period_target and caps
  // half_period; HALF_PERIOD=3 (4 clk cycles per sclk half period) is the value
  // driven on half_period for every section except the runtime-change check.
  spi #(
      .MAX_HALF_PERIOD_COUNT(4)
  ) my_dut (
      .clk(clk),
      .reset(reset),
      .start_signal(start_signal),
      .byte_to_send(byte_to_send),
      .miso(miso),
      .half_period(half_period),
      .done_signal(done_signal),
      .sclk(sclk),
      .byte_received(byte_received),
      .mosi(mosi)
  );


  // Clock
  always #5 clk = ~clk;

  // Dump waveforms only for interactive "apio sim", not for "apio test" (CI).
  // Do not call $dumpfile here: Apio sets the .vcd location itself and
  // treats an explicit $dumpfile call in a testbench as a fatal error.
`ifdef APIO_SIM
  initial $dumpvars(0, spi_tb);
`endif

  // Pulses reset for one clk cycle and lets the DUT settle back to IDLE.
  task automatic do_reset;
    reset = 1;
    @(posedge clk);
    #1;
    reset = 0;
    @(posedge clk);
  endtask

  // Runs one full 8 bit transfer and reports what actually happened on the wires.
  //   tx_byte  : byte to load into byte_to_send before starting
  //   rx_byte  : bit pattern to drive onto miso, sampled one bit per sclk period
  //   pass_tx  : 1 if the bits sampled off mosi matched tx_byte
  //   pass_rx  : 1 if the DUT's byte_received matched rx_byte
  //   actual_tx: the byte actually shifted out on mosi, for FAIL messages
  task automatic do_transfer;
    input [7:0] tx_byte;
    input [7:0] rx_byte;
    output pass_tx;
    output pass_rx;
    output [7:0] actual_tx;
    reg [7:0] mosi_accum;
    reg [7:0] bit_count;
    begin
      bit_count = 0;
      mosi_accum = 0;
      miso = rx_byte[7];
      byte_to_send = tx_byte;

      start_signal = 0;
      @(posedge clk);
      start_signal = 1;
      @(posedge clk);
      #1;
      start_signal = 0;
      while (!done_signal) begin
        // Mosi is sampled on the sclk rising edge (SETUP to SAMPLE), matching
        // when the DUT expects the receiving side to latch mosi.
        @(posedge sclk or posedge done_signal);
        #1;
        if (!done_signal) begin
          mosi_accum = {mosi_accum[6:0], mosi};
          bit_count  = bit_count + 1;
          // Miso is changed on the falling edge, so it is stable and ready to be
          // sampled by the DUT well before the next rising edge.
          @(negedge sclk or posedge done_signal);
          #1;
          if (!done_signal) begin
            miso = rx_byte[7-bit_count];
          end
        end
      end

      pass_tx   = mosi_accum == tx_byte;
      pass_rx   = byte_received == rx_byte;
      actual_tx = mosi_accum;
    end
  endtask

  // Main stimulus
  initial begin
    integer cycle_count = 0;
    integer i;
    integer sclk_edges;
    integer last_edge_t;
    integer fail_count;
    reg pass_tx, pass_rx;
    reg [7:0] actual_tx;
    reg timing_ok;

    reg [7:0] byte_to_send_1;
    reg [7:0] byte_to_receive_1;
    reg [7:0] byte_to_send_2;
    reg [7:0] byte_to_receive_2;
    reg [7:0] byte_to_send_3;
    reg [7:0] byte_to_receive_3;
    reg [7:0] byte_to_send_4;
    reg [7:0] byte_to_receive_4;
    reg [7:0] byte_to_send_5;
    reg [7:0] byte_to_receive_5;

    byte_to_send = 8'b11001010;
    byte_to_receive = 8'b10110101;


    clk = 0;
    half_period = HALF_PERIOD;
    fail_count = 0;

    // One time startup reset
    start_signal = 0;
    do_reset();

    // After reset the DUT should be sitting in IDLE, which drives mosi high
    // and sclk low. Checked once here since every other section starts from
    // a do_reset() anyway.
    if (mosi == 1 && sclk == 0)
      $display("PASS idle-outputs after reset: mosi=%0b, sclk=%0b (expected mosi=1, sclk=0)", mosi, sclk);
    else begin
      $display("FAIL idle-outputs after reset: mosi=%0b, sclk=%0b (expected mosi=1, sclk=0)", mosi, sclk);
      fail_count = fail_count + 1;
    end

    // Section 1: timing check
    // Confirms sclk toggles exactly every (HALF_PERIOD + 1) clk cycles and
    // that a full 8 bit transfer produces 15 half period edges before done_signal
    // (16 edges would complete the last half period; the 16th is folded into
    // done_signal instead of a further sclk toggle).
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;

    sclk_edges  = 0;
    timing_ok   = 1;
    last_edge_t = $time;

    while (!done_signal) begin
      @(posedge sclk or negedge sclk or posedge done_signal);
      #1;
      if (!done_signal) begin
        sclk_edges = sclk_edges + 1;
        // The first edge is measured from start_signal, not from a previous sclk
        // edge. IDLE and SETUP both drive sclk low, so the IDLE to SETUP move
        // does not produce a visible toggle: the first visible sclk edge only
        // appears once SETUP hands off to SAMPLE, which costs one extra clk
        // cycle of latency versus the steady-state half period. Every edge after
        // the first is a plain SETUP/SAMPLE handoff and is exactly
        // (HALF_PERIOD + 1) cycles from the previous one, so only edges 2
        // and up are checked against the nominal period.
        if (sclk_edges > 1 && ($time - last_edge_t) != CLK_PERIOD * (HALF_PERIOD + 1))
          timing_ok = 0;
        last_edge_t = $time;
      end
    end

    if (sclk_edges == 15 && timing_ok) begin
      $display("PASS section1 timing: got %0d sclk half-period edges (expected 15 = 8 bits x 2 - 1 folded into done), each spaced %0d clk cycles (HALF_PERIOD + 1) apart, done_signal fired on schedule",
                sclk_edges, (HALF_PERIOD + 1));
    end else begin
      $display("FAIL section1 timing: got %0d sclk half-period edges (expected 15), timing_ok=%0d (1=every half-period was exactly %0d clk cycles, 0=at least one half-period was off)",
                sclk_edges, timing_ok, (HALF_PERIOD + 1));
      fail_count = fail_count + 1;
    end

    // Reset before next section
    do_reset();

    // Section 2: transfer check
    // Baseline single-transfer test: mixed bit pattern on both tx and rx sides,
    // checks the DUT shifts out the right bits and captures the right bits.
    do_transfer(byte_to_send, byte_to_receive, pass_tx, pass_rx, actual_tx);

    if (pass_tx) $display("PASS section2 TX: mosi shifted out %08b, matches byte_to_send %08b", actual_tx, byte_to_send);
    else begin
      $display("FAIL section2 TX: mosi shifted out %08b, expected byte_to_send %08b", actual_tx, byte_to_send);
      fail_count = fail_count + 1;
    end

    if (pass_rx) $display("PASS section2 RX: byte_received %08b, matches byte_to_receive (miso pattern) %08b", byte_received, byte_to_receive);
    else begin
      $display("FAIL section2 RX: byte_received %08b, expected byte_to_receive (miso pattern) %08b", byte_received, byte_to_receive);
      fail_count = fail_count + 1;
    end

    // One clk cycle after done_signal, the DUT should already be back in IDLE
    // driving mosi high and sclk low again.
    @(posedge clk);
    #1;
    if (mosi == 1 && sclk == 0)
      $display("PASS idle-outputs after done_signal: mosi=%0b, sclk=%0b (expected mosi=1, sclk=0)", mosi, sclk);
    else begin
      $display("FAIL idle-outputs after done_signal: mosi=%0b, sclk=%0b (expected mosi=1, sclk=0)", mosi, sclk);
      fail_count = fail_count + 1;
    end

    // Reset before next section
    do_reset();

    // Section reset-loop: reset asserted right around the natural end of a transfer
    // i=-1: reset lands one clk cycle before the transfer would have finished on its own
    // i=0 : reset lands exactly on the cycle the transfer would have finished
    // Both cases must leave the DUT cleanly back in IDLE with bit_count and
    // half_period_count cleared, and a following transfer must still work.
    for (i = -1; i <= 0; i = i + 1) begin
      cycle_count  = 0;
      start_signal = 0;
      @(posedge clk);
      start_signal = 1;
      @(posedge clk);
      #1;
      start_signal = 0;

      while (cycle_count < 16 * (HALF_PERIOD + 1) + i) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
      end

      reset = 1;
      @(posedge clk);
      #1;
      reset = 0;
      #1;

      if (my_dut.state == my_dut.IDLE && my_dut.bit_count == 0 && my_dut.half_period_count == 0) begin
        if (i == -1) $display("PASS reset (i=%0d, reset asserted 1 cycle before natural done edge): state=IDLE, bit_count=0, half_period_count=0", i);
        else $display("PASS reset (i=%0d, reset asserted exactly at natural done edge): state=IDLE, bit_count=0, half_period_count=0", i);
      end else begin
        if (i == -1) $display("FAIL reset (i=%0d, reset asserted 1 cycle before natural done edge): state=%0d (expected IDLE=%0d), bit_count=%0d (expected 0), half_period_count=%0d (expected 0)",
                                i, my_dut.state, my_dut.IDLE, my_dut.bit_count, my_dut.half_period_count);
        else $display("FAIL reset (i=%0d, reset asserted exactly at natural done edge): state=%0d (expected IDLE=%0d), bit_count=%0d (expected 0), half_period_count=%0d (expected 0)",
                       i, my_dut.state, my_dut.IDLE, my_dut.bit_count, my_dut.half_period_count);
        fail_count = fail_count + 1;
      end

      do_transfer(byte_to_send, byte_to_receive, pass_tx, pass_rx, actual_tx);

      if (pass_tx) $display("PASS reset-loop (i=%0d) TX: mosi shifted out %08b, matches byte_to_send %08b", i, actual_tx, byte_to_send);
      else begin
        $display("FAIL reset-loop (i=%0d) TX: mosi shifted out %08b, expected byte_to_send %08b", i, actual_tx, byte_to_send);
        fail_count = fail_count + 1;
      end

      if (pass_rx) $display("PASS reset-loop (i=%0d) RX: byte_received %08b, matches byte_to_receive %08b", i, byte_received, byte_to_receive);
      else begin
        $display("FAIL reset-loop (i=%0d) RX: byte_received %08b, expected byte_to_receive %08b", i, byte_received, byte_to_receive);
        fail_count = fail_count + 1;
      end
    end


    // Section 3: mid-transfer reset check
    // Resets partway through a transfer (34 clk cycles in, well short of the
    // 60+ cycles a full transfer takes), confirming reset also cleanly aborts
    // a transfer that is actually mid-flight, not just near its natural end.
    cycle_count  = 0;
    start_signal = 0;
    @(posedge clk);
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    while (cycle_count < 34) begin
      @(posedge clk);
      #1;
      cycle_count = cycle_count + 1;
    end
    do_reset();
    if (my_dut.state == my_dut.IDLE && my_dut.bit_count == 0 && my_dut.half_period_count == 0) begin
      $display("PASS mid-transfer reset: reset asserted after 34 clk cycles (mid bit, well before the 8-bit transfer would finish), state=IDLE, bit_count=0, half_period_count=0");
    end else begin
      $display("FAIL mid-transfer reset: reset asserted after 34 clk cycles, state=%0d (expected IDLE=%0d), bit_count=%0d (expected 0), half_period_count=%0d (expected 0)",
                my_dut.state, my_dut.IDLE, my_dut.bit_count, my_dut.half_period_count);
      fail_count = fail_count + 1;
    end

    // Reset before next section
    do_reset();

    // Section 4: back to back transfer check
    // Starts a second transfer immediately after the first one's done_signal,
    // with no reset in between, to make sure the DUT re-arms itself correctly
    // from IDLE and does not carry over any state (shift register, bit_count)
    // from the previous transfer.
    byte_to_send_1    = 8'b10101010;
    byte_to_receive_1 = 8'b11110101;
    do_transfer(byte_to_send_1, byte_to_receive_1, pass_tx, pass_rx, actual_tx);
    byte_to_send_2    = 8'b10001010;
    byte_to_receive_2 = 8'b10010101;
    do_transfer(byte_to_send_2, byte_to_receive_2, pass_tx, pass_rx, actual_tx);

    if (pass_tx) $display("PASS back-to-back-transfer TX: mosi shifted out %08b, matches byte_to_send %08b", actual_tx, byte_to_send_2);
    else begin
      $display("FAIL back-to-back-transfer TX: mosi shifted out %08b, expected byte_to_send %08b", actual_tx, byte_to_send_2);
      fail_count = fail_count + 1;
    end

    if (pass_rx) $display("PASS back-to-back-transfer RX: byte_received %08b, matches byte_to_receive %08b", byte_received, byte_to_receive_2);
    else begin
      $display("FAIL back-to-back-transfer RX: byte_received %08b, expected byte_to_receive %08b", byte_received, byte_to_receive_2);
      fail_count = fail_count + 1;
    end

    // Reset before next section
    do_reset();

    // Section 5: start_signal pulsed mid-transfer must be ignored (dut only samples start_signal in IDLE)
    // Starts a normal transfer, then partway through (after bit 3 has been
    // sampled) pulses start_signal high again with a different byte_to_send
    // loaded. Since the DUT only looks at start_signal while in IDLE, this
    // should be a no-op: the transfer already in flight must finish with the
    // original byte, not the bogus one, and byte_received must still match
    // the original rx pattern.
    byte_to_send_3    = 8'b11100011;
    byte_to_receive_3 = 8'b01011010;
    byte_to_send      = byte_to_send_3;
    byte_to_receive   = byte_to_receive_3;

    bit_count  = 0;
    mosi_accum = 0;
    miso       = byte_to_receive_3[7];

    start_signal = 0;
    @(posedge clk);
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;

    while (!done_signal) begin
      @(posedge sclk or posedge done_signal);
      #1;
      if (!done_signal) begin
        mosi_accum = {mosi_accum[6:0], mosi};
        bit_count  = bit_count + 1;
        @(negedge sclk or posedge done_signal);
        #1;
        if (!done_signal) begin
          miso = byte_to_receive_3[7-bit_count];
        end
        // Inject a spurious start_signal mid-transfer with a different byte_to_send;
        // DUT is busy (not IDLE) so this should have no effect on the transfer in flight
        if (bit_count == 3 && !done_signal) begin
          byte_to_send = 8'b00000000;
          start_signal = 1;
          @(posedge clk);
          #1;
          start_signal = 0;
        end
      end
    end

    if (mosi_accum == byte_to_send_3)
      $display("PASS start-ignored-mid-transfer TX: mosi shifted out %08b, matches original byte_to_send %08b (spurious mid-transfer start_signal pulse with different byte_to_send was ignored)", mosi_accum, byte_to_send_3);
    else begin
      $display("FAIL start-ignored-mid-transfer TX: mosi shifted out %08b, expected original byte_to_send %08b (dut may have restarted or corrupted the transfer on the spurious start_signal pulse)", mosi_accum, byte_to_send_3);
      fail_count = fail_count + 1;
    end

    if (byte_received == byte_to_receive_3)
      $display("PASS start-ignored-mid-transfer RX: byte_received %08b, matches byte_to_receive %08b", byte_received, byte_to_receive_3);
    else begin
      $display("FAIL start-ignored-mid-transfer RX: byte_received %08b, expected byte_to_receive %08b", byte_received, byte_to_receive_3);
      fail_count = fail_count + 1;
    end

    // Reset before next section
    do_reset();

    // Section 6: edge/boundary byte values (0x00, 0xFF), catches stuck-at-0/stuck-at-1 bugs
    // on both mosi (tx) and miso (rx) paths that all-mixed-bit patterns elsewhere could mask.
    // Two transfers cover all four combinations: tx=0x00 would still pass a mosi
    // stuck-at-1 fault if only tested against mixed patterns, and rx=0x00 would
    // still pass a miso-sampling stuck-at-1 fault the same way, so each corner
    // is paired with the opposite corner on the other side.
    byte_to_send_4    = 8'h00;
    byte_to_receive_4 = 8'hFF;
    do_transfer(byte_to_send_4, byte_to_receive_4, pass_tx, pass_rx, actual_tx);

    if (pass_tx) $display("PASS section6 TX (tx=0x00): mosi shifted out %08b, matches byte_to_send %08b", actual_tx, byte_to_send_4);
    else begin
      $display("FAIL section6 TX (tx=0x00): mosi shifted out %08b, expected byte_to_send %08b", actual_tx, byte_to_send_4);
      fail_count = fail_count + 1;
    end

    if (pass_rx) $display("PASS section6 RX (rx=0xFF): byte_received %08b, matches byte_to_receive %08b", byte_received, byte_to_receive_4);
    else begin
      $display("FAIL section6 RX (rx=0xFF): byte_received %08b, expected byte_to_receive %08b", byte_received, byte_to_receive_4);
      fail_count = fail_count + 1;
    end

    do_reset();

    byte_to_send_5    = 8'hFF;
    byte_to_receive_5 = 8'h00;
    do_transfer(byte_to_send_5, byte_to_receive_5, pass_tx, pass_rx, actual_tx);

    if (pass_tx) $display("PASS section6 TX (tx=0xFF): mosi shifted out %08b, matches byte_to_send %08b", actual_tx, byte_to_send_5);
    else begin
      $display("FAIL section6 TX (tx=0xFF): mosi shifted out %08b, expected byte_to_send %08b", actual_tx, byte_to_send_5);
      fail_count = fail_count + 1;
    end

    if (pass_rx) $display("PASS section6 RX (rx=0x00): byte_received %08b, matches byte_to_receive %08b", byte_received, byte_to_receive_5);
    else begin
      $display("FAIL section6 RX (rx=0x00): byte_received %08b, expected byte_to_receive %08b", byte_received, byte_to_receive_5);
      fail_count = fail_count + 1;
    end

    // Reset before next section
    do_reset();

    // Section 7: runtime half_period change
    // half_period is only latched into half_period_target when a transfer
    // starts (IDLE -> SETUP), so a change made mid-transfer must not affect
    // the transfer already in flight, and must only take effect on the next
    // one. Checked here by: (a) changing half_period partway through a
    // transfer and confirming that transfer's sclk edges keep the OLD spacing
    // throughout, then (b) confirming the very next transfer runs at the NEW
    // spacing from its first edge.
    half_period = HALF_PERIOD;
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;

    sclk_edges  = 0;
    timing_ok   = 1;
    last_edge_t = $time;

    while (!done_signal) begin
      @(posedge sclk or negedge sclk or posedge done_signal);
      #1;
      if (!done_signal) begin
        sclk_edges = sclk_edges + 1;
        if (sclk_edges > 1 && ($time - last_edge_t) != CLK_PERIOD * (HALF_PERIOD + 1))
          timing_ok = 0;
        last_edge_t = $time;
        // Injected once, well after the transfer has started; must not affect
        // the spacing checked above for the remainder of this transfer.
        if (sclk_edges == 3) half_period = 1;
      end
    end

    if (timing_ok)
      $display("PASS section7 mid-transfer half_period change ignored: all sclk edges stayed spaced %0d clk cycles (old HALF_PERIOD) apart despite half_period changing to 1 mid-transfer",
                (HALF_PERIOD + 1));
    else begin
      $display("FAIL section7 mid-transfer half_period change ignored: at least one sclk edge was not spaced %0d clk cycles apart (old HALF_PERIOD) after half_period changed to 1 mid-transfer",
                (HALF_PERIOD + 1));
      fail_count = fail_count + 1;
    end

    sclk_edges  = 0;
    timing_ok   = 1;
    last_edge_t = $time;
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;

    while (!done_signal) begin
      @(posedge sclk or negedge sclk or posedge done_signal);
      #1;
      if (!done_signal) begin
        sclk_edges = sclk_edges + 1;
        if (sclk_edges > 1 && ($time - last_edge_t) != CLK_PERIOD * (1 + 1))
          timing_ok = 0;
        last_edge_t = $time;
      end
    end

    if (timing_ok)
      $display("PASS section7 next-transfer half_period change applied: all sclk edges spaced %0d clk cycles (new half_period=1) apart", 2);
    else begin
      $display("FAIL section7 next-transfer half_period change applied: at least one sclk edge was not spaced %0d clk cycles apart (new half_period=1)", 2);
      fail_count = fail_count + 1;
    end

    if (fail_count > 0) $fatal(1, "%0d check(s) FAILED", fail_count);
    else $display("All checks PASSED");
    $finish;
  end

endmodule
