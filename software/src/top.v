// Top-level: wires one shared spi instance between sdcard's init sequencer
// and sd_block_read (a fixed test read of sector 1, checking for the byte
// 'a'), handing control from one to the other at the `ready` boundary --
// safe because sd_block_read stays idle (start_signal=ready=0, driving
// nothing) until sdcard reaches its terminal S_DONE state (where it no
// longer drives spi either), so the two never contend for the bus.
//
// LEDs: LED0=init ready, LED1=init error, LED2=read done, LED3=read error,
// LED4=first byte of sector 1 was 'a' (0x61), LED5=unused. LED2/3/4 key off
// read_debug_state (a held level) rather than sd_block_read's done_signal/
// error (single-cycle pulses too brief to see on an LED).
//
// Pin mapping (Tang Nano 9K onboard TF slot / LEDs / button), see
// src/tangnano9k.cst: SD_SCK=36, SD_CMD(mosi)=37, SD_CS=38, SD_DAT0(miso)=39,
// clk27M=52, BTN[0]=4, LED[0..5]=10,11,13,14,15,16.
module top (
    input wire clk27M,
    input wire BTN0,  // reset button, active-low (pressed = 0)

    output wire SD_CS,
    output wire SD_SCK,
    output wire SD_CMD,
    input  wire SD_DAT0,

    output wire [5:0] LED  // active-low; inverted below so a set bit reads as "lit"
);

  wire reset = ~BTN0;

  wire spi_sclk, spi_mosi;
  wire spi_start;
  wire [7:0] spi_byte_to_send;
  wire spi_done;
  wire [7:0] spi_byte_received;
  wire [5:0] half_period;

  wire ready, init_error;

  wire sdcard_spi_start;
  wire [7:0] sdcard_spi_byte_to_send;
  wire sdcard_cs;

  wire read_done, read_error;
  wire [7:0] read_first_byte;
  wire read_spi_start;
  wire [7:0] read_spi_byte_to_send;
  wire read_cs;
  wire [3:0] read_debug_state;

  spi spi_inst (
      .clk(clk27M),
      .reset(reset),
      .start_signal(spi_start),
      .byte_to_send(spi_byte_to_send),
      .miso(SD_DAT0),
      .half_period(half_period),
      .sclk(spi_sclk),
      .mosi(spi_mosi),
      .done_signal(spi_done),
      .byte_received(spi_byte_received)
  );

  sdcard sdcard_inst (
      .clk(clk27M),
      .reset(reset),
      .start_signal(1'b1),
      .ready(ready),
      .error(init_error),
      .error_code(),
      .cs(sdcard_cs),
      .half_period(half_period),
      .spi_start(sdcard_spi_start),
      .spi_byte_to_send(sdcard_spi_byte_to_send),
      .spi_done(spi_done),
      .spi_byte_received(spi_byte_received)
  );

  sd_block_read sd_block_read_inst (
      .clk(clk27M),
      .reset(reset),
      .start_signal(ready),
      .sector(32'd1),
      .done_signal(read_done),
      .error(read_error),
      .first_byte(read_first_byte),
      .cs(read_cs),
      .debug_state(read_debug_state),
      .spi_start(read_spi_start),
      .spi_byte_to_send(read_spi_byte_to_send),
      .spi_done(spi_done),
      .spi_byte_received(spi_byte_received)
  );

  assign spi_start = ready ? read_spi_start : sdcard_spi_start;
  assign spi_byte_to_send = ready ? read_spi_byte_to_send : sdcard_spi_byte_to_send;
  assign SD_CS = ready ? read_cs : sdcard_cs;

  assign SD_SCK = spi_sclk;
  assign SD_CMD = spi_mosi;

  // read_done/read_error from sd_block_read are single-cycle pulses (not
  // held levels), so LED2/3/4 key off read_debug_state instead -- it's
  // parked at S_DONE (4'd5) or S_ERROR (4'd6) once the read finishes,
  // giving a level that's actually visible on an LED. read_first_byte
  // itself is a plain reg (holds its value once set), so it's fine as-is.
  assign LED[0] = ~ready;
  assign LED[1] = ~init_error;
  assign LED[2] = ~(read_debug_state == 4'd5);
  assign LED[3] = ~(read_debug_state == 4'd6);
  assign LED[4] = ~(read_debug_state == 4'd5 && read_first_byte == 8'h61);
  assign LED[5] = 1'b1;

endmodule
