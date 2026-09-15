// Testbench for the NCO (sample-rate strobe generator) module (module under
// test not written yet -- this file is the contract for it).
//
// Expected DUT interface (to be implemented as src/nco.v):
//
//   module nco #(
//       parameter              W    = 32,          // accumulator width
//       parameter [W-1:0]      STEP = 32'd7015113   // phase increment per clk
//   ) (
//       input  wire clk,
//       input  wire reset,
//       output reg  tick  // pulses high for one clk cycle on each strobe
//   );
//
// Semantics: every rising clk edge, the DUT adds STEP into an internal W-bit
// accumulator; when that would overflow past 2**W, it wraps (subtracts
// 2**W back off, same accumulate/compare/wrap shape as sigma_delta.v) and
// drives tick high for that one cycle. reset synchronously clears the
// internal accumulator to 0 and forces tick to 0.
//
// STEP's default (7015113) is round(44100 * 2**32 / 27_000_000) -- the real
// 27MHz sysclk -> 44.1kHz sample rate divider this project actually needs.
// Golden values below were produced by running nco.py itself with these
// exact clk_freq/target_rate/w numbers over a 20000-cycle window -- this
// testbench checks the DUT against that known-good software model, not
// against a hand-derived value.
module nco_tb;

  localparam W = 32;
  localparam [W-1:0] STEP = 32'd7015113;
  localparam NUM_CYCLES = 20000;
  localparam EXPECTED_TICKS = 32;

  // Golden tick cycle numbers (1-indexed, first clk edge after reset
  // deasserts is cycle 1) from nco.py over a 20000-cycle window.
  integer golden_timings[0:31];

  reg clk, reset;
  wire tick;

  // Icarus doesn't support unpacked-array task ports, so the capture buffer
  // lives at module scope and run_and_capture writes into it directly.
  integer captured[0:31];
  integer capture_count;

  nco #(
      .W   (W),
      .STEP(STEP)
  ) my_dut (
      .clk  (clk),
      .reset(reset),
      .tick (tick)
  );

  // Clock
  always #5 clk = ~clk;

`ifdef APIO_SIM
  initial $dumpvars(0, nco_tb);
`endif

  task automatic do_reset;
    begin
      reset = 1;
      @(posedge clk);
      #1;
      reset = 0;
    end
  endtask

  // Runs num_cycles clk cycles from the current state, recording the
  // 1-indexed cycle number of every tick pulse into the module-scope
  // captured[]/capture_count.
  task automatic run_and_capture;
    input integer num_cycles;
    integer c;
    begin
      capture_count = 0;
      for (c = 1; c <= num_cycles; c = c + 1) begin
        @(posedge clk);
        #1;
        if (tick) begin
          if (capture_count < 32) captured[capture_count] = c;
          capture_count = capture_count + 1;
        end
      end
    end
  endtask

  initial begin
    integer fail_count;
    integer k;
    integer mismatch;

    golden_timings[0] = 613;
    golden_timings[1] = 1225;
    golden_timings[2] = 1837;
    golden_timings[3] = 2449;
    golden_timings[4] = 3062;
    golden_timings[5] = 3674;
    golden_timings[6] = 4286;
    golden_timings[7] = 4898;
    golden_timings[8] = 5511;
    golden_timings[9] = 6123;
    golden_timings[10] = 6735;
    golden_timings[11] = 7347;
    golden_timings[12] = 7960;
    golden_timings[13] = 8572;
    golden_timings[14] = 9184;
    golden_timings[15] = 9796;
    golden_timings[16] = 10409;
    golden_timings[17] = 11021;
    golden_timings[18] = 11633;
    golden_timings[19] = 12245;
    golden_timings[20] = 12858;
    golden_timings[21] = 13470;
    golden_timings[22] = 14082;
    golden_timings[23] = 14694;
    golden_timings[24] = 15307;
    golden_timings[25] = 15919;
    golden_timings[26] = 16531;
    golden_timings[27] = 17143;
    golden_timings[28] = 17756;
    golden_timings[29] = 18368;
    golden_timings[30] = 18980;
    golden_timings[31] = 19592;

    fail_count = 0;
    clk = 0;
    reset = 0;

    // One-time startup reset, then check tick is held at its defined idle
    // value (0) before any accumulation has happened.
    do_reset();
    if (tick == 1'b0)
      $display("PASS idle-output after reset: tick=%0b (expected 0)", tick);
    else begin
      $display("FAIL idle-output after reset: tick=%0b (expected 0)", tick);
      fail_count = fail_count + 1;
    end

    // Case 1: run NUM_CYCLES clk cycles, compare captured tick timeline
    // against the exact golden trace from nco.py.
    run_and_capture(NUM_CYCLES);

    if (capture_count == EXPECTED_TICKS)
      $display("PASS tick count over %0d cycles: got %0d ticks, matches nco.py reference", NUM_CYCLES, capture_count);
    else begin
      $display("FAIL tick count over %0d cycles: got %0d ticks, expected %0d (nco.py reference)", NUM_CYCLES, capture_count, EXPECTED_TICKS);
      fail_count = fail_count + 1;
    end

    mismatch = 0;
    for (k = 0; k < EXPECTED_TICKS; k = k + 1) begin
      if (captured[k] != golden_timings[k]) begin
        mismatch = 1;
        $display("  mismatch at tick #%0d: got cycle %0d, expected cycle %0d", k, captured[k], golden_timings[k]);
      end
    end
    if (!mismatch)
      $display("PASS tick timeline: all %0d tick cycle numbers match nco.py reference exactly", EXPECTED_TICKS);
    else begin
      $display("FAIL tick timeline: at least one tick cycle number did not match nco.py reference (see mismatches above)");
      fail_count = fail_count + 1;
    end

    // Case 2: reset mid-stream must clear the accumulator, not just gate
    // tick -- run a partial stream, reset, then confirm a fresh run
    // reproduces the exact same golden trace instead of continuing from
    // wherever the accumulator was left.
    do_reset();
    repeat (1000) @(posedge clk);
    do_reset();
    run_and_capture(NUM_CYCLES);

    mismatch = 0;
    if (capture_count != EXPECTED_TICKS) mismatch = 1;
    for (k = 0; k < EXPECTED_TICKS; k = k + 1) begin
      if (captured[k] != golden_timings[k]) mismatch = 1;
    end
    if (!mismatch)
      $display("PASS reset mid-stream clears accumulator: fresh run after partial run + reset reproduces the golden trace exactly");
    else begin
      $display("FAIL reset mid-stream clears accumulator: fresh run after partial run + reset did NOT reproduce the golden trace (accumulator may not be fully cleared by reset)");
      fail_count = fail_count + 1;
    end

    if (fail_count > 0) $fatal(1, "%0d check(s) FAILED", fail_count);
    else $display("All checks PASSED");
    $finish;
  end

endmodule
