// ============================================================================
// clkgen.sv - pixel clock and 5x serial clock from the board clock (MMCME2)
//
//   MODE 0 (640x480):  VCO = CLKIN * M / D = 1000 MHz
//                      pixel = VCO / 40 = 25.0 MHz, serial = VCO / 8 = 125 MHz
//   MODE 1 (720p):     VCO = 50 * 59.375 / 4 = 742.1875 MHz
//                      pixel = VCO / 10 = 74.21875 MHz, serial = VCO / 2
//   (100 MHz input: D doubled.) Limits for -1 parts: VCO 600..1200 MHz,
//   PFD (CLKIN / D) >= 10 MHz.
// With `define SIM: ideal phase-aligned clocks for simulation.
// ============================================================================
`default_nettype none
module clkgen #(
    parameter int CLKIN_MHZ = 50,     // 50 or 100
    parameter int MODE      = 0
)(
    input  wire logic clk_in,
    output wire logic clk_pix,
    output wire logic clk_x5,
    output wire logic locked
);
`ifdef SIM
    // half periods in ps; x5 edges coincide with every pixel edge
    localparam int HX5 = (MODE == 1) ? 1347 : 4000;
    logic cp = 1'b0, cx = 1'b0, lk = 1'b0;
    initial forever #(HX5 * 1ps) cx = ~cx;
    initial begin
        #(HX5 * 1ps);
        forever begin
            cp = ~cp;
            #(HX5 * 5 * 1ps);
        end
    end
    initial #(2us) lk = 1'b1;
    assign clk_pix = cp;
    assign clk_x5  = cx;
    assign locked  = lk;
`else
    localparam real MULT = (MODE == 1) ? 59.375 : ((CLKIN_MHZ == 100) ? 10.0 : 20.0);
    localparam int  DIV  = (MODE == 1) ? ((CLKIN_MHZ == 100) ? 8 : 4) : 1;
    localparam real OX5  = (MODE == 1) ? 2.0 : 8.0;
    localparam int  OPIX = (MODE == 1) ? 10 : 40;
    localparam real PER  = 1000.0 / CLKIN_MHZ;

    wire fb, x5_u, pix_u;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(PER),
        .DIVCLK_DIVIDE(DIV),
        .CLKFBOUT_MULT_F(MULT),
        .CLKFBOUT_PHASE(0.0),
        .CLKOUT0_DIVIDE_F(OX5),
        .CLKOUT1_DIVIDE(OPIX),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk_in), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKFBOUTB(),
        .CLKOUT0(x5_u), .CLKOUT0B(), .CLKOUT1(pix_u), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
    );

    BUFG u_bufg_x5  (.I(x5_u),  .O(clk_x5));
    BUFG u_bufg_pix (.I(pix_u), .O(clk_pix));
`endif
endmodule
`default_nettype wire
