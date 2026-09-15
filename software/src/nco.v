module nco #(
    parameter              W    = 32,          // accumulator width
    parameter [W-1:0]      STEP = 32'd7015113   // phase increment per clk
) (
    input  wire clk,
    input  wire reset,
    output reg  tick  // pulses high for one clk cycle on each strobe
);

  reg [W-1:0] acc;
  wire [W:0] sum = {1'b0, acc} + STEP;

  always @(posedge clk) begin
    if (reset) begin
      acc <= 0;
      tick <= 0;
    end else begin
      acc <= sum[W-1:0];
      tick <= sum[W];
    end
  end

endmodule
