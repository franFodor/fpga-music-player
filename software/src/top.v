// Top-level: wires the shared spi instance between sdcard's init sequencer
// and the physical microSD slot pins, and surfaces init status on the
// onboard LEDs. start_signal is tied high since sdcard only samples it once,
// in its own IDLE state entered right after reset.
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
  wire ready, error;
  wire [3:0] error_code;

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
      .error(error),
      .error_code(error_code),
      .cs(SD_CS),
      .half_period(half_period),
      .spi_start(spi_start),
      .spi_byte_to_send(spi_byte_to_send),
      .spi_done(spi_done),
      .spi_byte_received(spi_byte_received)
  );

  assign SD_SCK = spi_sclk;
  assign SD_CMD = spi_mosi;

  assign LED[0]   = ~ready;
  assign LED[1]   = ~error;
  assign LED[5:2] = ~error_code;

endmodule
