module spi #(
    parameter MAX_HALF_PERIOD_COUNT = 62  // placeholder
) (
    input wire       clk,
    input wire       reset,
    input wire       start_signal,
    input wire [7:0] byte_to_send,
    input wire       miso,

    output reg       sclk,
    output reg       mosi,
    output reg       done_signal,
    output reg [7:0] byte_received
);

  localparam logic [1:0] IDLE = 2'b00, SETUP = 2'b01, SAMPLE = 2'b10;

  reg [1:0] state;
  reg [2:0] bit_count;
  reg [$clog2(MAX_HALF_PERIOD_COUNT)-1:0] half_period_count;
  reg [7:0] tx_shift_reg;  // current value of byte to send

  always @(posedge clk) begin
    if (reset) begin
      state <= IDLE;
      bit_count <= 0;
      half_period_count <= 0;
      mosi <= 1;  // convention
      sclk <= 0;
      done_signal <= 0;
      byte_received <= 0;  // not required, consistency
    end else begin
      done_signal <= 0;
      case (state)

        IDLE: begin
          mosi <= 1;
          sclk <= 0;

          if (start_signal) begin
            tx_shift_reg <= byte_to_send;
            bit_count <= 0;
            half_period_count <= 0;
            state <= SETUP;
          end
        end

        SETUP: begin
          sclk <= 0;
          mosi <= tx_shift_reg[7];
          if (half_period_count != MAX_HALF_PERIOD_COUNT - 1) begin
            half_period_count <= half_period_count + 1;
          end else begin
            half_period_count <= 0;
            tx_shift_reg <= tx_shift_reg << 1;
            state <= SAMPLE;
          end
        end

        SAMPLE: begin
          sclk <= 1;
          if (half_period_count != MAX_HALF_PERIOD_COUNT - 1) begin
            half_period_count <= half_period_count + 1;
          end else begin
            half_period_count <= 0;
            byte_received[7-bit_count] <= miso;
            bit_count <= bit_count + 1;
            if (bit_count == 7) begin
              done_signal <= 1;
              state <= IDLE;
            end else begin
              state <= SETUP;
            end
          end
        end

        default: begin
          state <= IDLE;
        end
      endcase
    end
  end

endmodule
