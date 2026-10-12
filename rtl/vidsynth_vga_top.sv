// ============================================================================
// vidsynth_vga_top.sv - VGA top level (12-bit resistor-DAC VGA ports)
// Same pattern generator, AXI4-Stream bridge and timing as the HDMI top;
// the upper 4 bits of each 8-bit colour drive the board's VGA DAC.
// ============================================================================
`default_nettype none
module vidsynth_vga_top #(
    parameter int CLKIN_MHZ = 100,
    parameter int MODE      = 0
)(
    input  wire logic        clk,
    input  wire logic        btn_rst,
    input  wire logic [15:0] sw,
    output logic      [15:0] led,
    output logic      [3:0]  vga_r,
    output logic      [3:0]  vga_g,
    output logic      [3:0]  vga_b,
    output logic             vga_hs,
    output logic             vga_vs
);
    wire clk_pix, clk_x5_unused, locked;
    clkgen #(.CLKIN_MHZ(CLKIN_MHZ), .MODE(MODE)) u_clk (
        .clk_in(clk), .clk_pix(clk_pix), .clk_x5(clk_x5_unused), .locked(locked)
    );

    wire btn_s, lk_s;
    wire [15:0] sw_s;
    sync_2ff #(.W(1))  u_sl   (.clk(clk_pix), .d(locked),  .q(lk_s));
    sync_2ff #(.W(1))  u_sbtn (.clk(clk_pix), .d(btn_rst), .q(btn_s));
    sync_2ff #(.W(16)) u_ssw  (.clk(clk_pix), .d(sw),      .q(sw_s));
    logic rst = 1'b1;
    always_ff @(posedge clk_pix) rst <= !lk_s || btn_s;

    logic [11:0] t_hc, t_vc;
    logic        t_de, t_hs, t_vs;
    video_timing #(.MODE(MODE)) u_tim (
        .clk(clk_pix), .rst(rst), .hc(t_hc), .vc(t_vc), .de(t_de), .hsync(t_hs), .vsync(t_vs)
    );

    logic [23:0] ax_data;
    logic        ax_valid, ax_ready, ax_user, ax_last;
    pattern_axis #(.MODE(MODE)) u_pat (
        .clk(clk_pix), .rst(rst), .sw(sw_s),
        .m_tdata(ax_data), .m_tvalid(ax_valid), .m_tready(ax_ready),
        .m_tuser(ax_user), .m_tlast(ax_last)
    );

    logic [7:0]  r, g, b;
    logic        de, hs, vs, v_locked;
    logic [11:0] hc, vc;
    logic [15:0] err;
    axis_to_video #(.MODE(MODE)) u_bridge (
        .clk(clk_pix), .rst(rst),
        .t_hc(t_hc), .t_vc(t_vc), .t_de(t_de), .t_hs(t_hs), .t_vs(t_vs),
        .s_tdata(ax_data), .s_tvalid(ax_valid), .s_tready(ax_ready),
        .s_tuser(ax_user), .s_tlast(ax_last),
        .red(r), .green(g), .blue(b), .de(de), .hsync(hs), .vsync(vs),
        .hc(hc), .vc(vc), .locked(v_locked), .err_count(err)
    );

    logic [25:0] hb = '0;
    always_ff @(posedge clk_pix) begin
        vga_r  <= r[7:4];
        vga_g  <= g[7:4];
        vga_b  <= b[7:4];
        vga_hs <= hs;
        vga_vs <= vs;
        hb     <= hb + 26'd1;
        led    <= {hb[25], 4'b0000, v_locked, sw_s[9:0]};
    end
endmodule
`default_nettype wire
