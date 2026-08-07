module spi_tb;
  reg clk, reset, start_signal, miso;
  wire mosi, sclk, done_signal;
  reg  [ 7:0] byte_to_send;
  wire [ 7:0] byte_received;

  reg  [31:0] cycle_count;

  spi #(
      .MAX_HALF_PERIOD_COUNT(4)
  ) my_dut (
      .clk(clk),
      .reset(reset),
      .start_signal(start_signal),
      .byte_to_send(byte_to_send),
      .miso(miso),
      .done_signal(done_signal),
      .sclk(sclk),
      .byte_received(byte_received),
      .mosi(mosi)
  );


  // clock
  always #5 clk = ~clk;

  // main stimulus
  initial begin
    clk = 0;
    reset = 1;
    start_signal = 0;
    cycle_count = 0;
    @(posedge clk);
    reset = 0;
    start_signal = 1;
    @(posedge clk);
    start_signal = 0;
    while (!done_signal) begin
      @(posedge clk);
      #1;
      cycle_count = cycle_count + 1;
    end

    if (cycle_count == 16 * my_dut.MAX_HALF_PERIOD_COUNT) begin
      $display("PASS: done_singal fired at correct cycle");
    end else begin
      $display("FAIL");
    end
    $finish;
  end
endmodule
