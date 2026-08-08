module spi_tb;
  localparam CLK_PERIOD = 10;

  reg clk, reset, start_signal, miso;
  wire mosi, sclk, done_signal;
  reg  [7:0] byte_to_send;
  wire [7:0] byte_received;

  reg  [7:0] byte_to_receive;
  reg  [7:0] mosi_accum;
  reg  [7:0] bit_count;

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

  task automatic do_transfer;
    input [7:0] tx_byte;
    input [7:0] rx_byte;
    output pass_tx;
    output pass_rx;
    output [7:0] actual_tx;
    reg [7:0] mosi_accum;
    reg [7:0] bit_count;
    begin
      bit_count = 0;
      mosi_accum = 0;
      miso = rx_byte[7];

      start_signal = 0;
      @(posedge clk);
      start_signal = 1;
      @(posedge clk);
      #1;
      start_signal = 0;
      while (!done_signal) begin
        @(posedge sclk or posedge done_signal);
        #1;
        if (!done_signal) begin
          mosi_accum = {mosi_accum[6:0], mosi};
          bit_count  = bit_count + 1;
          @(negedge sclk or posedge done_signal);
          #1;
          if (!done_signal) begin
            miso = rx_byte[7-bit_count];
          end
        end
      end

      pass_tx   = mosi_accum == tx_byte;
      pass_rx   = byte_received == rx_byte;
      actual_tx = mosi_accum;
    end
  endtask

  // main stimulus
  initial begin
    integer cycle_count = 0;
    integer i;
    integer sclk_edges;
    integer last_edge_t;
    reg pass_tx, pass_rx;
    reg [7:0] actual_tx;
    reg timing_ok;
    byte_to_send = 8'b11001010;
    byte_to_receive = 8'b10010101;

    clk = 0;

    // one time startup reset
    reset = 1;
    start_signal = 0;
    @(posedge clk);
    #1;
    reset = 0;
    @(posedge clk);

    // section 1: timing check
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;

    sclk_edges  = 0;
    timing_ok   = 1;
    last_edge_t = $time;

    while (!done_signal) begin
      @(posedge sclk or negedge sclk or posedge done_signal);
      #1;
      if (!done_signal) begin
        sclk_edges = sclk_edges + 1;
        if (($time - last_edge_t) != CLK_PERIOD * my_dut.MAX_HALF_PERIOD_COUNT)
          timing_ok = 0;
        last_edge_t = $time;
      end
    end

    if (sclk_edges == 15 && timing_ok) begin
      $display("PASS section1 timing: got %0d sclk half-period edges (expected 15 = 8 bits x 2 - 1 folded into done), each spaced %0d clk cycles (MAX_HALF_PERIOD_COUNT) apart, done_signal fired on schedule",
                sclk_edges, my_dut.MAX_HALF_PERIOD_COUNT);
    end else begin
      $display("FAIL section1 timing: got %0d sclk half-period edges (expected 15), timing_ok=%0d (1=every half-period was exactly %0d clk cycles, 0=at least one half-period was off)",
                sclk_edges, timing_ok, my_dut.MAX_HALF_PERIOD_COUNT);
    end

    // reset before next section
    reset = 1;
    @(posedge clk);
    #1;
    reset = 0;
    @(posedge clk);

    // section 2: transfer check
    do_transfer(byte_to_send, byte_to_receive, pass_tx, pass_rx, actual_tx);

    if (pass_tx) $display("PASS section2 TX: mosi shifted out %08b, matches byte_to_send %08b", actual_tx, byte_to_send);
    else $display("FAIL section2 TX: mosi shifted out %08b, expected byte_to_send %08b", actual_tx, byte_to_send);

    if (pass_rx) $display("PASS section2 RX: byte_received %08b, matches byte_to_receive (miso pattern) %08b", byte_received, byte_to_receive);
    else $display("FAIL section2 RX: byte_received %08b, expected byte_to_receive (miso pattern) %08b", byte_received, byte_to_receive);

    // reset before next section
    reset = 1;
    @(posedge clk);
    #1;
    reset = 0;
    @(posedge clk);

    for (i = -1; i <= 0; i = i + 1) begin
      cycle_count  = 0;
      start_signal = 0;
      @(posedge clk);
      start_signal = 1;
      @(posedge clk);
      #1;
      start_signal = 0;

      while (cycle_count < 16 * my_dut.MAX_HALF_PERIOD_COUNT + i) begin
        @(posedge clk);
        #1;
        cycle_count = cycle_count + 1;
      end

      reset = 1;
      @(posedge clk);
      #1;
      reset = 0;
      #1;

      if (my_dut.state == my_dut.IDLE && my_dut.bit_count == 0 && my_dut.half_period_count == 0) begin
        if (i == -1) $display("PASS reset (i=%0d, reset asserted 1 cycle before natural done edge): state=IDLE, bit_count=0, half_period_count=0", i);
        else $display("PASS reset (i=%0d, reset asserted exactly at natural done edge): state=IDLE, bit_count=0, half_period_count=0", i);
      end else begin
        if (i == -1) $display("FAIL reset (i=%0d, reset asserted 1 cycle before natural done edge): state=%0d (expected IDLE=%0d), bit_count=%0d (expected 0), half_period_count=%0d (expected 0)",
                                i, my_dut.state, my_dut.IDLE, my_dut.bit_count, my_dut.half_period_count);
        else $display("FAIL reset (i=%0d, reset asserted exactly at natural done edge): state=%0d (expected IDLE=%0d), bit_count=%0d (expected 0), half_period_count=%0d (expected 0)",
                       i, my_dut.state, my_dut.IDLE, my_dut.bit_count, my_dut.half_period_count);
      end

      do_transfer(byte_to_send, byte_to_receive, pass_tx, pass_rx, actual_tx);

      if (pass_tx) $display("PASS reset-loop (i=%0d) TX: mosi shifted out %08b, matches byte_to_send %08b", i, actual_tx, byte_to_send);
      else $display("FAIL reset-loop (i=%0d) TX: mosi shifted out %08b, expected byte_to_send %08b", i, actual_tx, byte_to_send);

      if (pass_rx) $display("PASS reset-loop (i=%0d) RX: byte_received %08b, matches byte_to_receive %08b", i, byte_received, byte_to_receive);
      else $display("FAIL reset-loop (i=%0d) RX: byte_received %08b, expected byte_to_receive %08b", i, byte_received, byte_to_receive);
    end


    // mid-transfer reset check
    cycle_count  = 0;
    start_signal = 0;
    @(posedge clk);
    start_signal = 1;
    @(posedge clk);
    #1;
    start_signal = 0;
    while (cycle_count < 34) begin
      @(posedge clk);
      #1;
      cycle_count = cycle_count + 1;
    end
    reset = 1;
    @(posedge clk);
    #1;
    reset = 0;
    #1;
    if (my_dut.state == my_dut.IDLE && my_dut.bit_count == 0 && my_dut.half_period_count == 0) begin
      $display("PASS mid-transfer reset: reset asserted after 34 clk cycles (mid bit, well before the 8-bit transfer would finish), state=IDLE, bit_count=0, half_period_count=0");
    end else begin
      $display("FAIL mid-transfer reset: reset asserted after 34 clk cycles, state=%0d (expected IDLE=%0d), bit_count=%0d (expected 0), half_period_count=%0d (expected 0)",
                my_dut.state, my_dut.IDLE, my_dut.bit_count, my_dut.half_period_count);
    end

    $finish;
  end

endmodule
