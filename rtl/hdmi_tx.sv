// ============================================================================
// hdmi_tx.sv - HDMI 1.4 / DVI transmitter (encoding layer)
//
// Input : timed video (RGB888, de, hsync, vsync, hc, vc), registered.
// Output: three 10-bit TMDS characters per pixel clock, for serialization.
//
// HDMI mode (cfg_hdmi = 1), per line:
//   active video      : TMDS video characters
//   blanking          : control tokens, plus
//     [IS, IS+8)      data island preamble   (CTL0..3 = 1,0,1,0)
//     [IS+8, IS+10)   data island leading guard band
//     [IS+10, IS+74)  two 32-character packets (TERC4)
//     [IS+74, IS+76)  data island trailing guard band
//     [H_TOT-10, -2)  video preamble         (CTL0..3 = 1,0,0,0)  *
//     [H_TOT-2, H_TOT) video leading guard band                   *
//   with IS = H_ACT + 4, and * only if the next line has active video.
//   Packet A: Audio Sample (up to 4 stereo samples) or Null.
//   Packet B: by line number mod 4: ACR, AVI InfoFrame, Audio InfoFrame, Null.
// DVI mode (cfg_hdmi = 0): video characters and control tokens only.
//
// Range: when cfg_limited = 1, RGB is scaled to 16..235.
// Configuration is sampled at the first pixel of each frame.
// Latency: 2 pixel clocks from inputs to TMDS characters.
// ============================================================================
`default_nettype none
module hdmi_tx #(
    parameter int MODE = 0
)(
    input  wire logic              clk,
    input  wire logic              rst,
    // timed video
    input  wire logic [7:0]        red,
    input  wire logic [7:0]        green,
    input  wire logic [7:0]        blue,
    input  wire logic              de,
    input  wire logic              hsync,
    input  wire logic              vsync,
    input  wire logic [11:0]       hc,
    input  wire logic [11:0]       vc,
    // configuration
    input  wire logic              cfg_hdmi,     // 1 = HDMI, 0 = DVI
    input  wire logic              cfg_qs,       // sink honours Q: declare full range
    input  wire logic              cfg_limited,  // scale RGB to 16..235
    input  wire logic              cfg_audio,    // send audio samples
    // audio samples (from audio_gen)
    input  wire logic              aud_valid,
    input  wire logic signed [15:0] aud_left,
    input  wire logic signed [15:0] aud_right,
    input  wire logic [7:0]        aud_frame,
    // TMDS characters
    output logic      [9:0]        tmds0,        // blue + sync
    output logic      [9:0]        tmds1,        // green
    output logic      [9:0]        tmds2         // red
);
    import vs_pkg::*;
    localparam int H_ACT = h_act(MODE), H_TOT = h_tot(MODE);
    localparam int V_ACT = v_act(MODE), V_TOT = v_tot(MODE);
    localparam int IS    = H_ACT + 4;            // island preamble start
    localparam int CTS   = acr_cts(MODE);
    localparam logic [7:0] VIC = 8'(vic(MODE));

    // ===================================================== configuration
    logic c_hdmi = 1'b0, c_qs = 1'b0, c_lim = 1'b0, c_aud = 1'b0;
    always_ff @(posedge clk)
        if (rst || (hc == 12'd0 && vc == 12'd0)) begin
            c_hdmi <= cfg_hdmi; c_qs <= cfg_qs; c_lim <= cfg_limited; c_aud <= cfg_audio;
        end

    // ==================================================== stage A inputs
    function automatic logic [7:0] to_limited(input logic [7:0] v);
        logic [15:0] p;
        p = 16'(v) * 16'd220;
        return 8'd16 + p[15:8];
    endfunction

    logic [7:0]  rA, gA, bA;
    logic        deA = 1'b0, hsA = 1'b0, vsA = 1'b0;
    logic [11:0] hcA = '0, vcA = '0;
    always_ff @(posedge clk) begin
        rA  <= c_lim ? to_limited(red)   : red;
        gA  <= c_lim ? to_limited(green) : green;
        bA  <= c_lim ? to_limited(blue)  : blue;
        deA <= de; hsA <= hsync; vsA <= vsync; hcA <= hc; vcA <= vc;
    end

    // ======================================================= audio FIFO
    localparam int FD = 16;
    logic [39:0] fifo [FD];                  // {frame, left, right}
    logic [3:0]  wr_ptr = '0, rd_ptr = '0;
    logic [4:0]  f_cnt  = '0;

    wire        latch  = c_hdmi && (hcA == 12'(IS)) && !deA;
    wire [2:0]  n_pop  = (f_cnt > 5'd4) ? 3'd4 : 3'(f_cnt);
    wire [2:0]  popped = latch ? n_pop : 3'd0;

    always_ff @(posedge clk) begin
        if (rst || !c_hdmi) begin                 // DVI: no islands, keep the FIFO empty
            wr_ptr <= '0; rd_ptr <= '0; f_cnt <= '0;
        end else begin
            if (aud_valid) begin
                fifo[wr_ptr] <= {aud_frame, aud_left, aud_right};
                wr_ptr <= wr_ptr + 4'd1;
            end
            rd_ptr <= rd_ptr + 4'(popped);
            f_cnt  <= f_cnt + 5'(aud_valid) - 5'(popped);
        end
    end

    // ================================================== packet building
    function automatic logic [7:0] ecc24(input logic [23:0] m);
        logic [7:0] e; logic fb;
        e = '0;
        for (int i = 0; i < 24; i++) begin
            fb = e[0] ^ m[i];
            e  = {1'b0, e[7:1]} ^ (fb ? 8'h83 : 8'h00);
        end
        return e;
    endfunction
    function automatic logic [7:0] ecc56(input logic [55:0] m);
        logic [7:0] e; logic fb;
        e = '0;
        for (int i = 0; i < 56; i++) begin
            fb = e[0] ^ m[i];
            e  = {1'b0, e[7:1]} ^ (fb ? 8'h83 : 8'h00);
        end
        return e;
    endfunction

    // ---- packet A: Audio Sample or Null
    logic [23:0] hdrA;
    logic [55:0] subA [4];
    always_comb begin
        logic [3:0]  sp, bflag;
        logic [39:0] smp;
        logic [15:0] l, r;
        logic        cs, pl, pr;
        sp = '0; bflag = '0;
        for (int k = 0; k < 4; k++) begin
            smp = fifo[rd_ptr + 4'(k)];
            l   = smp[31:16];
            r   = smp[15:0];
            cs  = (smp[39:32] == 8'd25);          // channel status bit 25: 48 kHz
            pl  = ^{l, cs};                       // even parity over sample, V, U, C
            pr  = ^{r, cs};
            if ((3'(k) < n_pop) && c_aud) begin
                sp[k]    = 1'b1;
                bflag[k] = (smp[39:32] == 8'd0);
                subA[k]  = {pr, cs, 2'b00, pl, cs, 2'b00,   // SB6: P C U V (R), P C U V (L)
                            r[15:8], r[7:0], 8'h00,         // SB5..SB3: right, 24-bit
                            l[15:8], l[7:0], 8'h00};        // SB2..SB0: left, 24-bit
            end else
                subA[k]  = '0;
        end
        hdrA = (sp != 4'd0) ? {4'b0000, bflag, 4'b0000, sp, 8'h02} : 24'h000000;
    end

    // ---- packet B: ACR, AVI InfoFrame, Audio InfoFrame, Null
    localparam logic [19:0] N20 = 20'(ACR_N), CTS20 = 20'(CTS);
    localparam logic [55:0] ACR_SUB = {N20[7:0], N20[15:8], {4'h0, N20[19:16]},
                                       CTS20[7:0], CTS20[15:8], {4'h0, CTS20[19:16]}, 8'h00};
    wire [7:0] avi_pb1 = 8'h10;                                  // RGB, A0 = 1
    wire [7:0] avi_pb2 = wide(MODE) ? 8'h28 : 8'h18;             // M = 16:9 or 4:3, R = same
    wire [7:0] avi_pb3 = c_qs ? 8'h08 : 8'h00;                   // Q = full if allowed
    wire [7:0] avi_pb4 = VIC;
    wire [7:0] avi_sum = 8'h82 + 8'h02 + 8'h0D + avi_pb1 + avi_pb2 + avi_pb3 + avi_pb4;
    wire [7:0] avi_pb0 = 8'h00 - avi_sum;
    localparam logic [7:0] AIF_PB0 = 8'h70;                      // 0x100 - (0x84+0x01+0x0A+0x01)

    logic [23:0] hdrB;
    logic [55:0] subB [4];
    always_comb begin
        subB[0] = '0; subB[1] = '0; subB[2] = '0; subB[3] = '0;
        unique case (vcA[1:0])
            2'd0: begin                                          // Audio Clock Regeneration
                hdrB = 24'h000001;
                subB[0] = ACR_SUB; subB[1] = ACR_SUB; subB[2] = ACR_SUB; subB[3] = ACR_SUB;
            end
            2'd1: begin                                          // AVI InfoFrame v2
                hdrB = {8'h0D, 8'h02, 8'h82};
                subB[0] = {8'h00, 8'h00, avi_pb4, avi_pb3, avi_pb2, avi_pb1, avi_pb0};
            end
            2'd2: begin                                          // Audio InfoFrame v1
                hdrB = {8'h0A, 8'h01, 8'h84};
                subB[0] = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, AIF_PB0};
            end
            default: hdrB = 24'h000000;                          // Null
        endcase
    end

    // ---- latch both packets with their ECC
    logic [31:0] pk_hdr [2];
    logic [63:0] pk_sub [2][4];
    always_ff @(posedge clk)
        if (latch) begin
            pk_hdr[0] <= {ecc24(hdrA), hdrA};
            pk_hdr[1] <= {ecc24(hdrB), hdrB};
            for (int k = 0; k < 4; k++) begin
                pk_sub[0][k] <= {ecc56(subA[k]), subA[k]};
                pk_sub[1][k] <= {ecc56(subB[k]), subB[k]};
            end
        end

    // ================================================ character scheduling
    wire next_active = (vcA == 12'(V_TOT - 1)) || (vcA < 12'(V_ACT - 1));
    wire in_dpre  = (hcA >= 12'(IS))      && (hcA < 12'(IS + 8));
    wire in_dgb   = ((hcA >= 12'(IS + 8)) && (hcA < 12'(IS + 10))) ||
                    ((hcA >= 12'(IS + 74)) && (hcA < 12'(IS + 76)));
    wire in_pkt   = (hcA >= 12'(IS + 10)) && (hcA < 12'(IS + 74));
    wire in_vpre  = next_active && (hcA >= 12'(H_TOT - 10)) && (hcA < 12'(H_TOT - 2));
    wire in_vgb   = next_active && (hcA >= 12'(H_TOT - 2));

    wire [5:0]  pos  = 6'(hcA - 12'(IS + 10));
    wire        pidx = pos[5];
    wire [4:0]  ci   = pos[4:0];
    wire [5:0]  e2   = {ci, 1'b0};               // even subpacket bit index
    wire [5:0]  o2   = {ci, 1'b1};               // odd subpacket bit index

    tmds_mode_t m0, m12;
    logic [1:0] c1, c2;
    logic [3:0] t40, t41, t42;
    always_comb begin
        m0 = TM_CTRL; m12 = TM_CTRL; c1 = 2'b00; c2 = 2'b00;
        t40 = '0; t41 = '0; t42 = '0;
        if (deA) begin
            m0 = TM_VIDEO; m12 = TM_VIDEO;
        end else if (c_hdmi) begin
            if (in_dpre) begin
                c1 = 2'b01; c2 = 2'b01;                          // CTL0 = 1, CTL2 = 1
            end else if (in_dgb) begin
                m0 = TM_TERC4; t40 = {2'b11, vsA, hsA};
                m12 = TM_DGUARD;
            end else if (in_pkt) begin
                m0  = TM_TERC4;  m12 = TM_TERC4;
                t40 = {(pos != 6'd0), pk_hdr[pidx][ci], vsA, hsA};
                t41 = {pk_sub[pidx][3][e2], pk_sub[pidx][2][e2], pk_sub[pidx][1][e2], pk_sub[pidx][0][e2]};
                t42 = {pk_sub[pidx][3][o2], pk_sub[pidx][2][o2], pk_sub[pidx][1][o2], pk_sub[pidx][0][o2]};
            end else if (in_vpre) begin
                c1 = 2'b01;                                      // CTL0 = 1
            end else if (in_vgb) begin
                m0 = TM_VGUARD; m12 = TM_VGUARD;
            end
        end
    end

    tmds_channel #(.CH(0)) u_ch0 (.clk(clk), .rst(rst), .mode(m0),  .d(bA), .c({vsA, hsA}), .t4(t40), .q(tmds0));
    tmds_channel #(.CH(1)) u_ch1 (.clk(clk), .rst(rst), .mode(m12), .d(gA), .c(c1),         .t4(t41), .q(tmds1));
    tmds_channel #(.CH(2)) u_ch2 (.clk(clk), .rst(rst), .mode(m12), .d(rA), .c(c2),         .t4(t42), .q(tmds2));

`ifndef SYNTHESIS
    // data islands and preambles never overlap active video
    a_no_overlap: assert property (@(posedge clk) disable iff (rst)
        deA |-> !(in_dpre || in_dgb || in_pkt));
    // the audio FIFO never overflows
    a_fifo: assert property (@(posedge clk) disable iff (rst)
        f_cnt <= 5'(FD));
    // the island fits inside horizontal blanking, before the video preamble
    initial assert (IS + 76 + 12 <= H_TOT - 10) else $fatal(1, "data island does not fit");
`endif
endmodule
`default_nettype wire
