// NCO (numerically controlled oscillator): turns clk into a steady tick
// pulse at STEP/2**W of clk's frequency, for driving downstream logic (e.g.
// sigma_delta.v) at a sample rate that doesn't divide evenly into clk --
// 27MHz sysclk / 44.1kHz doesn't land on a whole number, so a plain
// divide-by-N counter can't express it exactly.
//
// Same accumulate-until-overflow idea as sigma_delta.v, but full scale here
// is exactly 2**W, so the wrap is free: acc is sized to exactly W bits, so
// {1'b0, acc} + STEP naturally overflows into bit W of the W+1-bit sum on
// exactly the cycles where the accumulator would cross full scale. sum[W]
// (the carry-out) IS the tick -- no explicit compare-and-subtract needed,
// unlike sigma_delta.v where full scale isn't a power of two relative to
// its own accumulator width.
//
// Individual tick spacing isn't perfectly uniform (off by one clk cycle
// here and there) since STEP/2**W isn't exactly 44100/27000000 -- only
// close to within one part in 2**W. Averaged over many ticks the rate
// converges on the target exactly. See sim/nco_tb.v for the verified
// jitter bounds.
module nco #(
    parameter              W    = 32,          // accumulator width
    parameter [W-1:0]      STEP = 32'd7015113   // phase increment per clk
) (
    input  wire clk,
    input  wire reset,
    output reg  tick  // pulses high for one clk cycle on each strobe
);

  reg [W-1:0] acc;
  wire [W:0] sum = {1'b0, acc} + STEP;  // extra bit catches the overflow that acc's own width can't hold

  always @(posedge clk) begin
    if (reset) begin
      acc  <= 0;
      tick <= 0;
    end else begin
      acc  <= sum[W-1:0];
      tick <= sum[W];
    end
  end

endmodule
