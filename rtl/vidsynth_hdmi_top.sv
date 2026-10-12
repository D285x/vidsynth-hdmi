// ============================================================================
// vidsynth_hdmi_top.sv - HDMI video synthesizer, top level
//
//  board clk -> MMCM -> pixel clock (25 or 74.22 MHz) + 5x serial clock
//  pattern_axis --AXI4-Stream--> axis_to_video <-- video_timing
//       |                              |
//       |                         hdmi_tx (TMDS, TERC4, packets) <-- audio_gen
//       |                              |                         <-- edid_reader (DDC)
//       |                         4 x tmds_serializer -> HDMI connector
//
// Switches: sw[2:0] pattern, sw[5:3] speed, sw[8:6] palette, sw[9] invert,
//           sw[10] kaleidoscope, sw[11] posterize, sw[12] freeze,
//           sw[13] zoom, sw[14] palette cycling, sw[15] audio on.
// LEDs:     led[15] heartbeat, led[14] EDID read OK, led[13] HDMI mode,
//           led[12] sink QS (full range honoured), led[11] sink lists 720p,
//           led[10] video stream locked, led[9:0] = sw[9:0].
// ============================================================================
`default_nettype none
module vidsynth_hdmi_top #(
    parameter int CLKIN_MHZ    = 50,
    parameter int MODE         = 0,      // 0 = 640x480, 1 = 1280x720
    parameter bit EDID_ENABLE  = 1,      // 0: skip DDC, use the defaults below
    parameter bit DEFAULT_HDMI = 1       // mode used when no valid EDID is read
)(
    input  wire logic        clk,
    input  wire logic        btn_rst,
    input  wire logic [15:0] sw,
    output logic      [15:0] led,
    output wire logic        hdmi_clk_p,
    output wire logic        hdmi_clk_n,
    output wire logic [2:0]  hdmi_d_p,       // 0 = blue + sync, 1 = green, 2 = red
    output wire logic [2:0]  hdmi_d_n,
    inout  wire logic        ddc_scl,
    inout  wire logic        ddc_sda
);
    import vs_pkg::*;

    // ================================================================ clocks
    wire clk_pix, clk_x5, mmcm_locked;
    clkgen #(.CLKIN_MHZ(CLKIN_MHZ), .MODE(MODE)) u_clk (
        .clk_in(clk), .clk_pix(clk_pix), .clk_x5(clk_x5), .locked(mmcm_locked)
    );

    // ================================================================ resets
    // link reset: held 16 pixel clocks after lock, released synchronously
    logic [4:0] lk_cnt = '0;
    always_ff @(posedge clk_pix or negedge mmcm_locked)
        if (!mmcm_locked)     lk_cnt <= '0;
        else if (!lk_cnt[4])  lk_cnt <= lk_cnt + 5'd1;
    wire rst_link = ~lk_cnt[4];

    wire btn_s;
    wire [15:0] sw_s;
    sync_2ff #(.W(1))  u_sbtn (.clk(clk_pix), .d(btn_rst), .q(btn_s));
    sync_2ff #(.W(16)) u_ssw  (.clk(clk_pix), .d(sw),      .q(sw_s));
    logic rst_core = 1'b1;
    always_ff @(posedge clk_pix) rst_core <= rst_link | btn_s;

    // ========================================================= video path
    logic [11:0] t_hc, t_vc;
    logic        t_de, t_hs, t_vs;
    video_timing #(.MODE(MODE)) u_tim (
        .clk(clk_pix), .rst(rst_core),
        .hc(t_hc), .vc(t_vc), .de(t_de), .hsync(t_hs), .vsync(t_vs)
    );

    logic [23:0] ax_data;
    logic        ax_valid, ax_ready, ax_user, ax_last;
    pattern_axis #(.MODE(MODE)) u_pat (
        .clk(clk_pix), .rst(rst_core), .sw(sw_s),
        .m_tdata(ax_data), .m_tvalid(ax_valid), .m_tready(ax_ready),
        .m_tuser(ax_user), .m_tlast(ax_last)
    );

    logic [7:0]  v_r, v_g, v_b;
    logic        v_de, v_hs, v_vs, v_locked;
    logic [11:0] v_hc, v_vc;
    logic [15:0] v_err;
    axis_to_video #(.MODE(MODE)) u_bridge (
        .clk(clk_pix), .rst(rst_core),
        .t_hc(t_hc), .t_vc(t_vc), .t_de(t_de), .t_hs(t_hs), .t_vs(t_vs),
        .s_tdata(ax_data), .s_tvalid(ax_valid), .s_tready(ax_ready),
        .s_tuser(ax_user), .s_tlast(ax_last),
        .red(v_r), .green(v_g), .blue(v_b), .de(v_de), .hsync(v_hs), .vsync(v_vs),
        .hc(v_hc), .vc(v_vc), .locked(v_locked), .err_count(v_err)
    );

    // ================================================================ audio
    logic               a_valid;
    logic signed [15:0] a_l, a_r;
    logic [7:0]         a_frame;
    audio_gen #(.N(ACR_N), .CTS(acr_cts(MODE))) u_aud (
        .clk(clk_pix), .rst(rst_core), .note_sel(sw_s[2:0]),
        .s_valid(a_valid), .s_left(a_l), .s_right(a_r), .s_frame(a_frame)
    );

    // ================================================================= EDID
    logic scl_oe, sda_oe, e_ok, e_hdmi, e_qs, e_720, e_busy;
    generate if (EDID_ENABLE) begin : g_edid
        edid_reader #(.CLK_HZ(pix_hz(MODE)), .REFRESH_CYCLES(pix_hz(MODE))) u_edid (
            .clk(clk_pix), .rst(rst_link),
            .scl_i(ddc_scl), .sda_i(ddc_sda), .scl_oe(scl_oe), .sda_oe(sda_oe),
            .edid_ok(e_ok), .is_hdmi(e_hdmi), .qs(e_qs), .has_720p(e_720), .busy(e_busy)
        );
    end else begin : g_no_edid
        assign scl_oe = 1'b0; assign sda_oe = 1'b0;
        assign e_ok = 1'b0; assign e_hdmi = 1'b0; assign e_qs = 1'b0;
        assign e_720 = 1'b0; assign e_busy = 1'b0;
    end endgenerate
    assign ddc_scl = scl_oe ? 1'b0 : 1'bz;     // open drain
    assign ddc_sda = sda_oe ? 1'b0 : 1'bz;

    // sink configuration: DVI sinks get plain full-range RGB
    wire cfg_hdmi    = e_ok ? e_hdmi : DEFAULT_HDMI;
    wire cfg_qs      = e_ok && e_qs && cfg_hdmi;
    wire cfg_limited = cfg_hdmi && !cfg_qs && (MODE == 1);   // CE mode defaults to limited

    // ==================================================== HDMI transmitter
    logic [9:0] tm0, tm1, tm2;
    hdmi_tx #(.MODE(MODE)) u_tx (
        .clk(clk_pix), .rst(rst_core),
        .red(v_r), .green(v_g), .blue(v_b), .de(v_de), .hsync(v_hs), .vsync(v_vs),
        .hc(v_hc), .vc(v_vc),
        .cfg_hdmi(cfg_hdmi), .cfg_qs(cfg_qs), .cfg_limited(cfg_limited), .cfg_audio(sw_s[15]),
        .aud_valid(a_valid), .aud_left(a_l), .aud_right(a_r), .aud_frame(a_frame),
        .tmds0(tm0), .tmds1(tm1), .tmds2(tm2)
    );

    tmds_serializer u_ser0 (.clk_pix(clk_pix), .clk_x5(clk_x5), .rst(rst_link), .d(tm0),
                            .out_p(hdmi_d_p[0]), .out_n(hdmi_d_n[0]));
    tmds_serializer u_ser1 (.clk_pix(clk_pix), .clk_x5(clk_x5), .rst(rst_link), .d(tm1),
                            .out_p(hdmi_d_p[1]), .out_n(hdmi_d_n[1]));
    tmds_serializer u_ser2 (.clk_pix(clk_pix), .clk_x5(clk_x5), .rst(rst_link), .d(tm2),
                            .out_p(hdmi_d_p[2]), .out_n(hdmi_d_n[2]));
    tmds_serializer u_serc (.clk_pix(clk_pix), .clk_x5(clk_x5), .rst(rst_link), .d(10'b0000011111),
                            .out_p(hdmi_clk_p), .out_n(hdmi_clk_n));

    // ================================================================= LEDs
    logic [25:0] hb = '0;
    always_ff @(posedge clk_pix) hb <= hb + 26'd1;
    always_ff @(posedge clk_pix)
        led <= {hb[25], e_ok, cfg_hdmi, cfg_qs, e_720, v_locked, sw_s[9:0]};
endmodule
`default_nettype wire
