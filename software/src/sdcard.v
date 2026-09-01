// SD card power-up/init sequencer (SPI mode). Drives cs and a shared
// byte-level spi interface directly for the >=74 dummy clocks required
// before CMD0, then hands that same interface to an internal sd_cmd
// instance for the command sequence: CMD0 -> CMD8 -> (CMD55+CMD41)* -> CMD58.
// The external spi module itself is not instantiated here (matches the rest
// of this repo: a module exposes its neighbor's interface as ports so the
// neighbor can be faked in that module's own testbench); a caller (top.v)
// wires spi_start/spi_byte_to_send/spi_done/spi_byte_received/half_period to
// a real spi instance shared with whatever drives the data phase afterward.
//
// Scope: SDHC/SDXC (block-addressed) cards only. CMD8 failing (illegal
// command) or CMD58 reporting CCS=0 are both treated as unsupported-card
// errors rather than falling back to SDSC byte-addressing/CMD16.
//
// cs is asserted low once at CMD0 and held low for the whole sequence,
// released back high only on error; this matches how most working SPI-mode
// init implementations behave, rather than toggling cs between commands.
//
// Read/write of actual data blocks is out of scope here; this module only
// gets the card to a state where CMD17/CMD18/... can be driven at full
// speed by a caller that reuses this half_period wiring.
module sdcard #(
    parameter [5:0] INIT_HALF_PERIOD = 6'd33,  // ~397 kHz @ 27 MHz sysclk (Tang Nano 9K onboard osc); spec caps init speed at 400 kHz
    parameter [5:0] FULL_HALF_PERIOD = 6'd0,  // 13.5 MHz @ 27 MHz sysclk; sysclk is the limiting factor, well under the 25 MHz SPI-mode cap
    parameter [3:0] DUMMY_BYTES = 4'd10,  // >=74 clocks required by spec before CMD0; 10 bytes = 80 clocks
    // ACMD41 polling budget. Spec allows up to ~1s for the card to leave idle.
    // Estimated from init-speed byte time: CMD55+CMD41 round trip is roughly
    // 24 bytes total (two 6-byte frames + NCR poll + trailing bytes), each
    // byte ~16 half-periods of INIT_HALF_PERIOD -> ~20us/byte -> ~480us/round
    // -> ~2000 rounds/s. 4000 gives ~2x margin; not verified against real hardware.
    parameter [15:0] ACMD41_MAX_RETRIES = 16'd4000
) (
    input wire clk,
    input wire reset,
    input wire start_signal,  // sampled only in IDLE

    output reg ready,  // level: stays 1 once init succeeds, until reset
    output reg error,  // level: stays 1 once init fails, until reset
    output reg [3:0] error_code,

    output reg cs,
    output reg [5:0] half_period,  // caller feeds this straight into the shared spi instance

    output wire       spi_start,
    output wire [7:0] spi_byte_to_send,
    input  wire       spi_done,
    input  wire [7:0] spi_byte_received
);

  localparam [3:0]
    S_IDLE       = 4'd0,
    S_DUMMY      = 4'd1,
    S_CMD0_START = 4'd2,
    S_CMD0_WAIT  = 4'd3,
    S_CMD8_START = 4'd4,
    S_CMD8_WAIT  = 4'd5,
    S_CMD55_START= 4'd6,
    S_CMD55_WAIT = 4'd7,
    S_CMD41_START= 4'd8,
    S_CMD41_WAIT = 4'd9,
    S_CMD58_START= 4'd10,
    S_CMD58_WAIT = 4'd11,
    S_DONE       = 4'd12,
    S_ERROR      = 4'd13;

  localparam [3:0]
    ERR_NONE              = 4'd0,
    ERR_CMD0               = 4'd1,
    ERR_CMD8                = 4'd2,
    ERR_CMD55                = 4'd3,
    ERR_ACMD41                = 4'd4,
    ERR_ACMD41_TIMEOUT         = 4'd5,
    ERR_CMD58                   = 4'd6,
    ERR_NOT_HIGH_CAPACITY        = 4'd7;

  reg [3:0] state;
  reg [3:0] dummy_count;
  reg [15:0] acmd41_count;

  // Muxed between this module's direct dummy-clock drive and the internal
  // sd_cmd instance's drive, depending on phase.
  reg dummy_spi_start;

  reg sdcmd_start;
  reg [5:0] sdcmd_index;
  reg [31:0] sdcmd_arg;
  wire sdcmd_done;
  wire sdcmd_timeout;
  wire [39:0] sdcmd_response;
  wire sdcmd_spi_start;
  wire [7:0] sdcmd_spi_byte_to_send;

  wire using_sd_cmd = !(state == S_IDLE || state == S_DUMMY || state == S_DONE || state == S_ERROR);
  assign spi_start = using_sd_cmd ? sdcmd_spi_start : dummy_spi_start;
  assign spi_byte_to_send = using_sd_cmd ? sdcmd_spi_byte_to_send : 8'hFF;

  sd_cmd sd_cmd_inst (
      .clk(clk),
      .reset(reset),
      .start_signal(sdcmd_start),
      .cmd_index(sdcmd_index),
      .arg(sdcmd_arg),
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
      ready <= 0;
      error <= 0;
      error_code <= ERR_NONE;
      cs <= 1;
      half_period <= INIT_HALF_PERIOD;
      dummy_spi_start <= 0;
      sdcmd_start <= 0;
      dummy_count <= 0;
      acmd41_count <= 0;
    end else begin
      dummy_spi_start <= 0;
      sdcmd_start <= 0;

      case (state)

        S_IDLE: begin
          cs <= 1;
          if (start_signal) begin
            dummy_count <= 0;
            dummy_spi_start <= 1;
            state <= S_DUMMY;
          end
        end

        // Sends DUMMY_BYTES bytes of 0xFF with cs held high, satisfying the
        // spec's >=74-clock power-up requirement before the first command.
        S_DUMMY: begin
          cs <= 1;
          if (spi_done) begin
            if (dummy_count == DUMMY_BYTES - 1) begin
              state <= S_CMD0_START;
            end else begin
              dummy_count <= dummy_count + 1'b1;
              dummy_spi_start <= 1;
            end
          end
        end

        S_CMD0_START: begin
          cs <= 0;
          sdcmd_index <= 6'd0;
          sdcmd_arg <= 32'h0;
          sdcmd_start <= 1;
          state <= S_CMD0_WAIT;
        end

        // Expect R1 == 0x01 (idle, no error bits) confirming SPI mode entry.
        S_CMD0_WAIT: begin
          if (sdcmd_done) begin
            if (sdcmd_timeout || sdcmd_response[39:32] != 8'h01) begin
              error <= 1;
              error_code <= ERR_CMD0;
              state <= S_ERROR;
            end else begin
              state <= S_CMD8_START;
            end
          end
        end

        S_CMD8_START: begin
          sdcmd_index <= 6'd8;
          sdcmd_arg <= 32'h0000_01AA;  // voltage window 2.7-3.6V, check pattern 0xAA
          sdcmd_start <= 1;
          state <= S_CMD8_WAIT;
        end

        // CMD8 failing (R1 != 0x01, e.g. illegal-command bit set) means the
        // card doesn't support the v2 flow this module relies on for
        // SDHC/SDXC detection; treated as unsupported rather than falling
        // back to the v1/SDSC path.
        S_CMD8_WAIT: begin
          if (sdcmd_done) begin
            if (sdcmd_timeout || sdcmd_response[39:32] != 8'h01 ||
                sdcmd_response[15:8] != 8'h01 || sdcmd_response[7:0] != 8'hAA) begin
              error <= 1;
              error_code <= ERR_CMD8;
              state <= S_ERROR;
            end else begin
              acmd41_count <= 0;
              state <= S_CMD55_START;
            end
          end
        end

        S_CMD55_START: begin
          sdcmd_index <= 6'd55;
          sdcmd_arg <= 32'h0;
          sdcmd_start <= 1;
          state <= S_CMD55_WAIT;
        end

        S_CMD55_WAIT: begin
          if (sdcmd_done) begin
            if (sdcmd_timeout) begin
              error <= 1;
              error_code <= ERR_CMD55;
              state <= S_ERROR;
            end else begin
              state <= S_CMD41_START;
            end
          end
        end

        S_CMD41_START: begin
          sdcmd_index <= 6'd41;
          sdcmd_arg <= 32'h4000_0000;  // HCS=1: host supports high-capacity cards
          sdcmd_start <= 1;
          state <= S_CMD41_WAIT;
        end

        // R1 bits 6:1 set (anything but idle) means a real error, not just
        // "still powering up" -> abort instead of retrying. Bit0 (idle)
        // clearing means the card is ready; otherwise loop back through
        // CMD55 until ACMD41_MAX_RETRIES is exhausted.
        S_CMD41_WAIT: begin
          if (sdcmd_done) begin
            if (sdcmd_timeout || sdcmd_response[38:33] != 6'b0) begin
              error <= 1;
              error_code <= ERR_ACMD41;
              state <= S_ERROR;
            end else if (!sdcmd_response[32]) begin
              state <= S_CMD58_START;
            end else if (acmd41_count == ACMD41_MAX_RETRIES - 1) begin
              error <= 1;
              error_code <= ERR_ACMD41_TIMEOUT;
              state <= S_ERROR;
            end else begin
              acmd41_count <= acmd41_count + 1'b1;
              state <= S_CMD55_START;
            end
          end
        end

        S_CMD58_START: begin
          sdcmd_index <= 6'd58;
          sdcmd_arg <= 32'h0;
          sdcmd_start <= 1;
          state <= S_CMD58_WAIT;
        end

        // R1 must be exactly 0 (ready, no errors). response[30] is OCR bit30
        // (CCS): 1 means block-addressed SDHC/SDXC, which is all this module
        // supports; CCS=0 (byte-addressed SDSC) is reported as an error.
        S_CMD58_WAIT: begin
          if (sdcmd_done) begin
            if (sdcmd_timeout || sdcmd_response[39:32] != 8'h00) begin
              error <= 1;
              error_code <= ERR_CMD58;
              state <= S_ERROR;
            end else if (!sdcmd_response[30]) begin
              error <= 1;
              error_code <= ERR_NOT_HIGH_CAPACITY;
              state <= S_ERROR;
            end else begin
              half_period <= FULL_HALF_PERIOD;
              ready <= 1;
              state <= S_DONE;
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
