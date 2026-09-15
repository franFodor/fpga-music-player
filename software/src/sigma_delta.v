module sigma_delta #(
    parameter WIDTH = 4  // signed sample width; FS = 2**WIDTH internally
) (
    input  wire                    clk,
    input  wire                    reset,
    input  wire signed [WIDTH-1:0] sample_in,
    output reg                     pdm_out
);

  reg [WIDTH:0] acc;
  wire [WIDTH-1:0] offset_sample = sample_in + (1 << (WIDTH - 1));

  always @(posedge clk) begin
    if (reset) begin
      acc     <= 0;
      pdm_out <= 0;
    end else begin
    if (acc + offset_sample >= (1 << WIDTH)) begin
        acc <= acc + offset_sample - (1 << WIDTH);
        pdm_out <= 1; 
      end else begin
        acc <= acc + offset_sample;
        pdm_out <= 0;
      end
    end
  end

endmodule
