// Test wrapper: the complete pixel-clock-domain HDMI path without clock
// generation and serializers (those are covered by the serial-level testbench).
`default_nettype none
module hdmi_core #(
    parameter int MODE = 0
)(
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic [15:0] sw,
    input  wire logic        cfg_hdmi,
    input  wire logic        cfg_qs,
    input  wire logic        cfg_limited,
    output logic      [9:0]  tmds0,
    output logic      [9:0]  tmds1,
    output logic      [9:0]  tmds2,
    // taps for the testbench: the video entering the transmitter
    output logic      [7:0]  v_r, v_g, v_b,
    output logic             v_de, v_hs, v_vs, v_locked,
    output logic             a_valid
);
    import vs_pkg::*;
    logic [11:0] t_hc, t_vc, v_hc, v_vc;
    logic        t_de, t_hs, t_vs;
    video_timing #(.MODE(MODE)) u_tim (.clk(clk), .rst(rst), .hc(t_hc), .vc(t_vc), .de(t_de), .hsync(t_hs), .vsync(t_vs));
    logic [23:0] d; logic vld, rdy, usr, lst;
    pattern_axis #(.MODE(MODE)) u_pat (.clk(clk), .rst(rst), .sw(sw), .m_tdata(d), .m_tvalid(vld), .m_tready(rdy), .m_tuser(usr), .m_tlast(lst));
    logic [15:0] err;
    axis_to_video #(.MODE(MODE)) u_br (.clk(clk), .rst(rst), .t_hc(t_hc), .t_vc(t_vc), .t_de(t_de), .t_hs(t_hs), .t_vs(t_vs),
        .s_tdata(d), .s_tvalid(vld), .s_tready(rdy), .s_tuser(usr), .s_tlast(lst),
        .red(v_r), .green(v_g), .blue(v_b), .de(v_de), .hsync(v_hs), .vsync(v_vs), .hc(v_hc), .vc(v_vc), .locked(v_locked), .err_count(err));
    logic signed [15:0] al, ar; logic [7:0] af;
    audio_gen #(.N(ACR_N), .CTS(acr_cts(MODE))) u_aud (.clk(clk), .rst(rst), .note_sel(sw[2:0]),
        .s_valid(a_valid), .s_left(al), .s_right(ar), .s_frame(af));
    hdmi_tx #(.MODE(MODE)) u_tx (.clk(clk), .rst(rst), .red(v_r), .green(v_g), .blue(v_b), .de(v_de), .hsync(v_hs), .vsync(v_vs),
        .hc(v_hc), .vc(v_vc), .cfg_hdmi(cfg_hdmi), .cfg_qs(cfg_qs), .cfg_limited(cfg_limited), .cfg_audio(sw[15]),
        .aud_valid(a_valid), .aud_left(al), .aud_right(ar), .aud_frame(af), .tmds0(tmds0), .tmds1(tmds1), .tmds2(tmds2));
endmodule
`default_nettype wire
