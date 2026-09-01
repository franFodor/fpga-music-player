// SD command framer/sequencer. Builds the 6-byte SD command frame (start +
// transmission bits, 6-bit index, 32-bit arg, CRC7 + stop bit) and drives it
// out one byte at a time through an external spi module via
// spi_start/spi_byte_to_send, then reads back the response the same way.
//
// Does not touch cs: the caller (init/read FSM) asserts cs before
// start_signal and decides how long to hold it afterward, since a
// data-phase command (CMD17) must keep cs low past this module's
// done_signal, straight into the data token/block that follows.
//
// Always captures 5 response bytes into `response` (byte0 in response[39:32]
// down to byte4 in response[7:0]). Byte0 is R1 for every SD command; bytes
// 1-4 are only meaningful for R3/R7 callers (CMD58, CMD8) and can be ignored
// otherwise.
module sd_cmd #(
    parameter NCR_MAX_BYTES = 16  // generous upper bound; SD spec allows NCR = 0-8 byte times before R1 starts
) (
    input wire clk,
    input wire reset,
    input wire start_signal,  // sampled only in IDLE
    input wire [5:0] cmd_index,
    input wire [31:0] arg,

    output reg done_signal,  // pulses once the full response has been captured
    output reg timeout,  // 1 if no byte with bit7=0 appeared within NCR_MAX_BYTES bytes; held until next start_signal
    output reg [39:0] response,  // byte0 (R1) in [39:32] .. byte4 in [7:0]

    output reg       spi_start,
    output reg [7:0] spi_byte_to_send,
    input wire        spi_done,
    input wire [ 7:0] spi_byte_received
);

  localparam [2:0] IDLE = 3'd0, SEND = 3'd1, WAIT_R1 = 3'd2, READ_REST = 3'd3;

  reg [2:0] state;
  reg [7:0] frame_bytes[0:5];
  // During SEND: index of the next frame byte to load (byte 0 is already in
  // flight from the IDLE->SEND transition). During READ_REST: index of the
  // trailing response byte currently in flight (0-3).
  reg [2:0] byte_idx;
  reg [$clog2(NCR_MAX_BYTES)-1:0] ncr_count;

  wire [6:0] crc;
  crc7 crc_calc (
      .data({1'b0, 1'b1, cmd_index, arg}),
      .crc(crc)
  );

  always @(posedge clk) begin
    if (reset) begin
      state <= IDLE;
      done_signal <= 0;
      timeout <= 0;
      spi_start <= 0;
      byte_idx <= 0;
    end else begin
      done_signal <= 0;
      spi_start   <= 0;

      case (state)

        // Latches the 6 frame bytes (byte 0 computed directly from the
        // inputs since frame_bytes[0] would not settle until next cycle) and
        // kicks off its transfer through the external spi module.
        IDLE: begin
          if (start_signal) begin
            frame_bytes[0] <= {1'b0, 1'b1, cmd_index};
            frame_bytes[1] <= arg[31:24];
            frame_bytes[2] <= arg[23:16];
            frame_bytes[3] <= arg[15:8];
            frame_bytes[4] <= arg[7:0];
            frame_bytes[5] <= {crc, 1'b1};
            byte_idx <= 1;
            spi_byte_to_send <= {1'b0, 1'b1, cmd_index};
            spi_start <= 1;
            ncr_count <= 0;
            timeout <= 0;
            state <= SEND;
          end
        end

        // One frame byte is in flight; on spi_done either load the next one
        // or, once all 6 have gone out, move on to polling for R1.
        SEND: begin
          if (spi_done) begin
            if (byte_idx == 3'd6) begin
              spi_byte_to_send <= 8'hFF;
              spi_start <= 1;
              state <= WAIT_R1;
            end else begin
              spi_byte_to_send <= frame_bytes[byte_idx];
              spi_start <= 1;
              byte_idx <= byte_idx + 3'd1;
            end
          end
        end

        // Polls with 0xFF filler bytes until one comes back with bit7=0
        // (the R1 start bit), per the SD spec's NCR window, or gives up and
        // flags timeout after NCR_MAX_BYTES filler bytes.
        WAIT_R1: begin
          if (spi_done) begin
            if (!spi_byte_received[7]) begin
              response[39:32] <= spi_byte_received;
              byte_idx <= 0;
              spi_byte_to_send <= 8'hFF;
              spi_start <= 1;
              state <= READ_REST;
            end else if (ncr_count == NCR_MAX_BYTES - 1) begin
              timeout <= 1;
              done_signal <= 1;
              state <= IDLE;
            end else begin
              ncr_count <= ncr_count + 1'b1;
              spi_byte_to_send <= 8'hFF;
              spi_start <= 1;
            end
          end
        end

        // Unconditionally reads 4 trailing bytes so R3/R7 callers get the
        // full response; R1-only callers just leave these unread.
        READ_REST: begin
          if (spi_done) begin
            case (byte_idx)
              3'd0: response[31:24] <= spi_byte_received;
              3'd1: response[23:16] <= spi_byte_received;
              3'd2: response[15:8] <= spi_byte_received;
              default: response[7:0] <= spi_byte_received;
            endcase
            if (byte_idx == 3'd3) begin
              done_signal <= 1;
              state <= IDLE;
            end else begin
              byte_idx <= byte_idx + 3'd1;
              spi_byte_to_send <= 8'hFF;
              spi_start <= 1;
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
