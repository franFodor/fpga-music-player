// SPI master. Shifts out byte_to_send on mosi MSB first while sampling miso
// into byte_received, MSB first, one transfer per start_signal pulse.
// Sclk idles low (mode 0 style): low during setup of each bit, high while
// sampling. See sim/spi_tb.v for timing details and reasoning.
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

  // IDLE : waiting for start_signal, sclk/mosi held at their idle levels
  // SETUP: sclk low, mosi driving the next bit, gives the far side setup time
  // SAMPLE: sclk high, miso is latched into byte_received at the end of this state
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

        // Idle: sclk and mosi sit at their resting levels. start_signal is
        // only sampled here, so a pulse arriving while a transfer is already
        // in flight (state != IDLE) is silently ignored.
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

        // Setup half of the bit period: sclk stays low, mosi is driven with
        // the current MSB of tx_shift_reg. half_period_count times out this
        // half period before handing off to SAMPLE, where the shift also
        // happens so the next bit is ready to be driven in the following SETUP.
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

        // Sample half of the bit period: sclk stays high for
        // MAX_HALF_PERIOD_COUNT cycles. On the last cycle, miso is latched
        // into the current bit of byte_received. After the 8th bit
        // (bit_count == 7), done_signal pulses for one cycle and state
        // returns to IDLE instead of looping back to SETUP.
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
