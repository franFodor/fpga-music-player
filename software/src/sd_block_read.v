// Single-block reader (CMD17). Given a block address (already block-addressed,
// per the SDHC/SDXC-only scope established in sdcard.v), issues CMD17,
// waits for the data start token (0xFE), then reads the 512-byte block plus
// its trailing 2 CRC16 bytes. Only the block's first byte is kept
// (first_byte); the rest is read and discarded since nothing needs it yet.
// CRC16 is not validated -- known gap, fine for now since SPI-mode CRC is
// optional unless CMD59 enables it.
//
// Exposes the same byte-level spi interface as sd_cmd/sdcard (spi_start/
// spi_byte_to_send/spi_done/spi_byte_received), for a caller (top.v) to wire
// to the shared spi instance; owns cs itself, asserting it low for the
// whole CMD17 + data-phase transfer and releasing it in DONE/ERROR.
module sd_block_read #(
    // Timeout budget waiting for the 0xFE data start token. Spec allows up
    // to ~100ms for a single-block read; not derived from real timing, just
    // a generous margin, same caveat as sdcard's ACMD41_MAX_RETRIES.
    parameter [15:0] TOKEN_MAX_BYTES = 16'd2000
) (
    input wire clk,
    input wire reset,
    input wire start_signal,  // sampled only in IDLE
    input wire [31:0] sector,  // block address

    output reg done_signal,  // pulses once first_byte is valid (success) or on error
    output reg error,
    output reg [7:0] first_byte,

    output reg cs,

    // Internal state number, exposed so a caller can drive LEDs/probes off a
    // held level instead of the pulsed done_signal/error outputs above.
    output wire [3:0] debug_state,

    output wire       spi_start,
    output wire [7:0] spi_byte_to_send,
    input  wire       spi_done,
    input  wire [7:0] spi_byte_received
);

  localparam [3:0]
    S_IDLE       = 4'd0,
    S_CMD_WAIT   = 4'd1,
    S_TOKEN_WAIT = 4'd2,
    S_DATA       = 4'd3,
    S_CRC        = 4'd4,
    S_DONE       = 4'd5,
    S_ERROR      = 4'd6;

  reg [3:0] state;
  reg [15:0] token_count;
  reg [8:0] data_count;  // 0-511
  reg crc_byte1_done;

  reg own_spi_start;

  reg sdcmd_start;
  wire sdcmd_done;
  wire sdcmd_timeout;
  wire [39:0] sdcmd_response;
  wire sdcmd_spi_start;
  wire [7:0] sdcmd_spi_byte_to_send;

  assign debug_state = state;

  wire using_sd_cmd = (state == S_CMD_WAIT);
  assign spi_start = using_sd_cmd ? sdcmd_spi_start : own_spi_start;
  assign spi_byte_to_send = using_sd_cmd ? sdcmd_spi_byte_to_send : 8'hFF;

  sd_cmd sd_cmd_inst (
      .clk(clk),
      .reset(reset),
      .start_signal(sdcmd_start),
      .cmd_index(6'd17),
      .arg(sector),
      .done_signal(sdcmd_done),
      .timeout(sdcmd_timeout),
      .response(sdcmd_response),
      .spi_start(sdcmd_spi_start),
      .spi_byte_to_send(sdcmd_spi_byte_to_send),
      .spi_done(spi_done),
      .spi_byte_received(spi_byte_received)
  );

  always @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      done_signal <= 0;
      error <= 0;
      cs <= 1;
      own_spi_start <= 0;
      sdcmd_start <= 0;
      token_count <= 0;
      data_count <= 0;
    end else begin
      done_signal <= 0;
      own_spi_start <= 0;
      sdcmd_start <= 0;

      case (state)

        S_IDLE: begin
          cs <= 1;
          if (start_signal) begin
            cs <= 0;
            sdcmd_start <= 1;
            state <= S_CMD_WAIT;
          end
        end

        // Expect R1 == 0x00 (command accepted, no errors).
        S_CMD_WAIT: begin
          if (sdcmd_done) begin
            if (sdcmd_timeout || sdcmd_response[39:32] != 8'h00) begin
              error <= 1;
              done_signal <= 1;
              state <= S_ERROR;
            end else begin
              token_count <= 0;
              own_spi_start <= 1;
              state <= S_TOKEN_WAIT;
            end
          end
        end

        // Polls with 0xFF filler until the 0xFE data start token arrives.
        // A byte with bit7 clear but not equal to 0xFE is a data error token
        // (upper nibble 0000) -> abort instead of waiting out the timeout.
        S_TOKEN_WAIT: begin
          if (spi_done) begin
            if (spi_byte_received == 8'hFE) begin
              data_count <= 0;
              own_spi_start <= 1;
              state <= S_DATA;
            end else if (spi_byte_received[7:4] == 4'h0) begin
              error <= 1;
              done_signal <= 1;
              state <= S_ERROR;
            end else if (token_count == TOKEN_MAX_BYTES - 1) begin
              error <= 1;
              done_signal <= 1;
              state <= S_ERROR;
            end else begin
              token_count <= token_count + 1'b1;
              own_spi_start <= 1;
            end
          end
        end

        // Reads all 512 data bytes; only byte 0 is kept.
        S_DATA: begin
          if (spi_done) begin
            if (data_count == 0) first_byte <= spi_byte_received;
            if (data_count == 9'd511) begin
              crc_byte1_done <= 0;
              own_spi_start <= 1;
              state <= S_CRC;
            end else begin
              data_count <= data_count + 1'b1;
              own_spi_start <= 1;
            end
          end
        end

        // Reads and discards the 2 trailing CRC16 bytes.
        S_CRC: begin
          if (spi_done) begin
            if (crc_byte1_done) begin
              done_signal <= 1;
              cs <= 1;
              state <= S_DONE;
            end else begin
              crc_byte1_done <= 1;
              own_spi_start <= 1;
            end
          end
        end

        S_DONE: begin
          // terminal; stays here until reset
        end

        S_ERROR: begin
          cs <= 1;  // release the bus
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
