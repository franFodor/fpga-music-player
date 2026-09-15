// First-order sigma-delta (PDM) modulator. Every clk cycle, adds the
// current sample into an accumulator; whenever the running total reaches
// full scale, pdm_out pulses high and full scale is subtracted back off,
// same accumulate/compare/subtract shape a plain NCO uses (see nco.v),
// just with an explicit subtract instead of relying on fixed-width
// overflow, since full scale here isn't a power of two relative to acc's
// own width.
//
// sample_in is signed (silence = 0, not some special-cased "off" state) but
// the accumulate loop only works on non-negative values, so it's offset up
// into an unsigned range internally before accumulating -- offset_sample
// is what actually feeds the loop, sample_in itself is untouched.
//
// Averaged through an external RC low-pass filter, pdm_out's duty cycle
// reconstructs sample_in as an analog voltage: silence (sample_in=0) is a
// steady 50% duty cycle, not an all-zero bitstream, which is why the
// analog side needs an AC-coupling cap rather than expecting a DC-centered
// signal straight off this pin. See sim/sigma_delta_tb.v for the exact
// expected bitstreams this was verified against, including that case.
module sigma_delta #(
    parameter WIDTH = 4  // signed sample width; FS = 2**WIDTH internally
) (
    input  wire                    clk,
    input  wire                    reset,
    input  wire signed [WIDTH-1:0] sample_in,
    output reg                     pdm_out
);

  reg [WIDTH:0] acc;  // WIDTH+1 bits: guard bit for the transient sum (up to ~2*FS) before subtract-back
  wire [WIDTH-1:0] offset_sample = sample_in + (1 << (WIDTH - 1));

  always @(posedge clk) begin
    if (reset) begin
      acc     <= 0;
      pdm_out <= 0;
    end else begin
      if (acc + offset_sample >= (1 << WIDTH)) begin
        acc     <= acc + offset_sample - (1 << WIDTH);
        pdm_out <= 1;
      end else begin
        acc     <= acc + offset_sample;
        pdm_out <= 0;
      end
    end
  end

endmodule
