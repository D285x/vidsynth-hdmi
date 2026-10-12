// ============================================================================
// tmds_serializer.sv - 10:1 DDR serializer and TMDS_33 output buffer
// Hardware: OSERDESE2 MASTER (bits 0..7 on D1..D8) cascaded with a SLAVE
// (bits 8..9 on D3..D4); D1 leaves first, so bit 0 is transmitted first.
// clk_x5 = 5 x clk_pix from the same MMCM; rst synchronous to clk_pix.
// With `define SIM a behavioural model is used (for Icarus/Verilator);
// Vivado's simulator runs the real primitives (do not define SIM there).
// ============================================================================
`default_nettype none
module tmds_serializer (
    input  wire logic       clk_pix,
    input  wire logic       clk_x5,
    input  wire logic       rst,
    input  wire logic [9:0] d,
    output wire logic       out_p,
    output wire logic       out_n
);
`ifdef SIM
    logic [9:0] word = '0, shreg = '0;
    logic [3:0] n    = '0;
    logic       ser  = 1'b0;
    always_ff @(posedge clk_pix) word <= d;
    always @(posedge clk_x5 or negedge clk_x5) begin   // DDR: both edges, LSB first
        if (rst) begin
            n   <= '0;
            ser <= 1'b0;
        end else begin
            if (n == 4'd0) begin
                ser   <= word[0];
                shreg <= {1'b0, word[9:1]};
            end else begin
                ser   <= shreg[0];
                shreg <= {1'b0, shreg[9:1]};
            end
            n <= (n == 4'd9) ? 4'd0 : n + 4'd1;
        end
    end
    assign out_p =  ser;
    assign out_n = ~ser;
`else
    wire ser, shift1, shift2;

    OSERDESE2 #(
        .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
        .SERDES_MODE("MASTER"), .TRISTATE_WIDTH(1),
        .TBYTE_CTL("FALSE"), .TBYTE_SRC("FALSE")
    ) u_master (
        .OQ(ser), .OFB(), .TQ(), .TFB(), .SHIFTOUT1(), .SHIFTOUT2(), .TBYTEOUT(),
        .CLK(clk_x5), .CLKDIV(clk_pix),
        .D1(d[0]), .D2(d[1]), .D3(d[2]), .D4(d[3]),
        .D5(d[4]), .D6(d[5]), .D7(d[6]), .D8(d[7]),
        .OCE(1'b1), .RST(rst), .SHIFTIN1(shift1), .SHIFTIN2(shift2),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0), .TCE(1'b0)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10),
        .SERDES_MODE("SLAVE"), .TRISTATE_WIDTH(1),
        .TBYTE_CTL("FALSE"), .TBYTE_SRC("FALSE")
    ) u_slave (
        .OQ(), .OFB(), .TQ(), .TFB(), .SHIFTOUT1(shift1), .SHIFTOUT2(shift2), .TBYTEOUT(),
        .CLK(clk_x5), .CLKDIV(clk_pix),
        .D1(1'b0), .D2(1'b0), .D3(d[8]), .D4(d[9]),
        .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
        .OCE(1'b1), .RST(rst), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0), .TCE(1'b0)
    );

    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf (.I(ser), .O(out_p), .OB(out_n));
`endif
endmodule
`default_nettype wire
