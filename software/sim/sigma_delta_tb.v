// Testbench for a first-order sigma-delta (PDM) modulator (module under
// test not written yet -- this file is the contract for it).
//
// Expected DUT interface (to be implemented as src/sigma_delta.v):
//
//   module sigma_delta #(
//       parameter WIDTH = 4  // signed sample width; FS = 2**WIDTH internally
//   ) (
//       input  wire                    clk,
//       input  wire                    reset,
//       input  wire signed [WIDTH-1:0] sample_in,
//       output reg                     pdm_out
//   );
//
// Semantics: every rising clk edge, the DUT runs one iteration of the
// accumulate/compare/subtract-back loop on the current sample_in (offset to
// unsigned internally, same as sigmadel.py's `input_ = int(input()) +
// fs // 2` step -- sample_in here is the RAW signed value, the DUT does the
// offset itself), and drives the resulting bit onto pdm_out synchronously
// (registered, valid to sample shortly after the edge that produced it).
// reset synchronously clears the internal accumulator to 0 and forces
// pdm_out to 0.
//
// Golden bitstreams below were produced by running sigmadel.py itself
// (fs=16, cycles=16, offset-corrected) for each sample_in value -- this
// testbench checks the DUT against that known-good software model, not
// against a hand-derived value.
module sigma_delta_tb;

  localparam WIDTH = 4;

  reg clk, reset;
  reg signed [WIDTH-1:0] sample_in;
  wire pdm_out;

  sigma_delta #(
      .WIDTH(WIDTH)
  ) my_dut (
      .clk(clk),
      .reset(reset),
      .sample_in(sample_in),
      .pdm_out(pdm_out)
  );

  // Clock
  always #5 clk = ~clk;

`ifdef APIO_SIM
  initial $dumpvars(0, sigma_delta_tb);
`endif

  // Runs 16 cycles with sample_in held at sample_val, capturing pdm_out
  // (MSB-first, cycle 1 first) into actual. Caller resets before calling.
  task automatic run_case;
    input signed [WIDTH-1:0] sample_val;
    output [15:0] actual;
    integer c;
    begin
      sample_in = sample_val;
      actual = 16'b0;
      for (c = 0; c < 16; c = c + 1) begin
        @(posedge clk);
        #1;
        actual = {actual[14:0], pdm_out};
      end
    end
  endtask

  task automatic do_reset;
    begin
      reset = 1;
      @(posedge clk);
      #1;
      reset = 0;
    end
  endtask

  initial begin
    integer fail_count;
    reg [15:0] actual;

    fail_count = 0;
    clk = 0;
    reset = 0;
    sample_in = 0;

    // One-time startup reset, then check pdm_out is held at its defined
    // idle value (0) before any sample has been applied.
    do_reset();
    if (pdm_out == 1'b0)
      $display("PASS idle-output after reset: pdm_out=%0b (expected 0)", pdm_out);
    else begin
      $display("FAIL idle-output after reset: pdm_out=%0b (expected 0)", pdm_out);
      fail_count = fail_count + 1;
    end

    // Case 1: sample_in=-3 -> offset unsigned 5 (fs=16) -> matches the
    // hand-verified fs=16/input=5 trace: 0001001001001001
    do_reset();
    run_case(-4'sd3, actual);
    if (actual == 16'b0001001001001001)
      $display("PASS sample_in=-3: pdm_out stream=%016b, matches sigmadel.py reference", actual);
    else begin
      $display("FAIL sample_in=-3: pdm_out stream=%016b, expected 0001001001001001", actual);
      fail_count = fail_count + 1;
    end

    // Case 2: sample_in=0 (silence) -> offset unsigned 8 -> steady 50%
    // duty cycle, NOT all-zero. This is the case that matters for the
    // AC-coupling cap on the analog side.
    do_reset();
    run_case(4'sd0, actual);
    if (actual == 16'b0101010101010101)
      $display("PASS sample_in=0 (silence): pdm_out stream=%016b, matches sigmadel.py reference", actual);
    else begin
      $display("FAIL sample_in=0 (silence): pdm_out stream=%016b, expected 0101010101010101", actual);
      fail_count = fail_count + 1;
    end

    // Case 3: sample_in=-8 (max negative) -> offset unsigned 0 -> all-zero
    // floor.
    do_reset();
    run_case(-4'sd8, actual);
    if (actual == 16'b0000000000000000)
      $display("PASS sample_in=-8 (max negative): pdm_out stream=%016b, matches sigmadel.py reference", actual);
    else begin
      $display("FAIL sample_in=-8 (max negative): pdm_out stream=%016b, expected 0000000000000000", actual);
      fail_count = fail_count + 1;
    end

    // Case 4: sample_in=7 (max positive) -> offset unsigned 15 -> near-ceiling
    // density.
    do_reset();
    run_case(4'sd7, actual);
    if (actual == 16'b0111111111111111)
      $display("PASS sample_in=7 (max positive): pdm_out stream=%016b, matches sigmadel.py reference", actual);
    else begin
      $display("FAIL sample_in=7 (max positive): pdm_out stream=%016b, expected 0111111111111111", actual);
      fail_count = fail_count + 1;
    end

    // Case 5: reset mid-stream must clear the accumulator, not just gate
    // pdm_out -- run sample_in=-3 for a few cycles, reset, then confirm a
    // fresh 16-cycle run reproduces the exact same trace as case 1 instead
    // of continuing from wherever the accumulator was left.
    do_reset();
    sample_in = -4'sd3;
    repeat (5) @(posedge clk);
    do_reset();
    run_case(-4'sd3, actual);
    if (actual == 16'b0001001001001001)
      $display("PASS reset mid-stream clears accumulator: pdm_out stream=%016b, matches fresh sample_in=-3 trace", actual);
    else begin
      $display("FAIL reset mid-stream clears accumulator: pdm_out stream=%016b, expected 0001001001001001 (accumulator may not be fully cleared by reset)", actual);
      fail_count = fail_count + 1;
    end

    if (fail_count > 0) $fatal(1, "%0d check(s) FAILED", fail_count);
    else $display("All checks PASSED");
    $finish;
  end

endmodule
