module spi_tb;
  reg clk, reset, start_signal, miso;
  wire mosi, sclk, done_signal;
  reg  [ 7:0] byte_to_send;
  wire [ 7:0] byte_received;

  reg  [31:0] cycle_count;

  reg  [ 7:0] byte_to_receive;
  reg  [ 7:0] mosi_accum;
  reg  [ 7:0] bit_count;

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
    @(posedge clk);
    start_signal = 1;
    @(posedge clk);
    #1;
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
  end

  initial begin
    byte_to_send = 8'b11001010;
    byte_to_receive = 8'b10010101;
    bit_count = 0;
    mosi_accum = 0;
    miso = byte_to_receive[7];
    @(posedge start_signal);

    while (!done_signal) begin
      @(posedge sclk or posedge done_signal);
      #1;
      if (!done_signal) begin
        mosi_accum = {mosi_accum[6:0], mosi};
        bit_count  = bit_count + 1;
        @(negedge sclk or posedge done_signal);
        #1;
        if (!done_signal) begin
          miso = byte_to_receive[7-bit_count];
        end
      end
    end

    if (byte_to_send == mosi_accum) begin
      $display("PASS TX");
    end else begin
      $display("FAIL");
    end

    if (byte_received == byte_to_receive) begin
      $display("PASS RX");
    end else begin
      $display("FAIL");
    end
    $finish;
  end

endmodule
