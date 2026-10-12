// ============================================================================
// pattern_axis.sv - procedural pattern generator, AXI4-Stream video master
//
// Output follows AMD UG934 (AXI4-Stream video):
//   tdata[23:16] = R, tdata[15:8] = B, tdata[7:0] = G
//   tuser        = start of frame (first pixel), tlast = end of line
// The generator streams only active pixels (H_ACT x V_ACT per frame).
// A six-stage pipeline computes each pixel; every stage advances together
// when the output is accepted or empty (adv = !valid_out || tready), so
// backpressure stalls the whole pipeline without losing data.
//
// Controls (sw) are captured once per frame, when the first pixel of a
// frame enters the pipeline, and travel with every pixel of that frame.
//   sw[2:0] pattern   sw[5:3] speed   sw[8:6] palette   sw[9] invert
//   sw[10] kaleidoscope  sw[11] posterize  sw[12] freeze   sw[13] zoom
//   sw[14] palette cycling           sw[15] (audio enable, not used here)
// ============================================================================
`default_nettype none
module pattern_axis #(
    parameter int MODE = 0
)(
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic [15:0] sw,          // already synchronized
    output logic      [23:0] m_tdata,
    output logic             m_tvalid,
    input  wire logic        m_tready,
    output logic             m_tuser,
    output logic             m_tlast
);
    import vs_pkg::*;
    localparam int H_ACT = h_act(MODE), V_ACT = v_act(MODE);
    localparam int SH = coord_shift(MODE);
    localparam int VW = H_ACT >> SH, VH = V_ACT >> SH;   // virtual size
    localparam int CX = VW / 2, CY = VH / 2;

    // ---------------------------------------------------------- handshake
    logic vld1 = 1'b0, vld2 = 1'b0, vld3 = 1'b0, vld4 = 1'b0, vld5 = 1'b0, vld6 = 1'b0;
    wire  adv = !vld6 || m_tready;

    // ------------------------------------------------- stage 0: positions
    logic [10:0] x0 = '0, y0c = '0;
    wire  sof0 = (x0 == 0) && (y0c == 0);
    wire  eol0 = (x0 == 11'(H_ACT - 1));
    always_ff @(posedge clk) begin
        if (rst) begin
            x0 <= '0; y0c <= '0;
        end else if (adv) begin
            if (eol0) begin
                x0  <= '0;
                y0c <= (y0c == 11'(V_ACT - 1)) ? '0 : y0c + 11'd1;
            end else
                x0 <= x0 + 11'd1;
        end
    end

    // ---------------------------------------- per-frame state (time, LFOs)
    logic [15:0] t_f   = '0;
    logic [15:0] ctl_f = '0;
    logic signed [11:0] cx1_f = 12'(CX), cy1_f = 12'(CY), cx2_f = 12'(CX), cy2_f = 12'(CY);

    wire  [15:0] t_next = sw[12] ? t_f : t_f + {13'd0, sw[5:3]} + 16'd1;
    wire  [7:0]  tf8  = t_f[7:0];
    wire  [7:0]  tf15 = t_f[7:0] + t_f[8:1];
    logic [7:0]  lfo1, lfo2, lfo3, lfo4;
    sin_lut u_lfo1 (.a(tf8),           .y(lfo1));
    sin_lut u_lfo2 (.a(tf8 + 8'd64),   .y(lfo2));
    sin_lut u_lfo3 (.a(tf15),          .y(lfo3));
    sin_lut u_lfo4 (.a(tf15 + 8'd100), .y(lfo4));
    wire signed [11:0] cx1_n = 12'(CX - 128) + $signed({4'd0, lfo1});
    wire signed [11:0] cy1_n = 12'(CY - 64)  + $signed({5'd0, lfo2[7:1]});
    wire signed [11:0] cx2_n = 12'(CX + 128) - $signed({4'd0, lfo3});
    wire signed [11:0] cy2_n = 12'(CY + 64)  - $signed({5'd0, lfo4[7:1]});

    always_ff @(posedge clk) begin
        if (rst) begin
            t_f <= '0; ctl_f <= '0;
        end else if (adv && sof0) begin
            t_f   <= t_next;
            ctl_f <= sw;
            cx1_f <= cx1_n; cy1_f <= cy1_n; cx2_f <= cx2_n; cy2_f <= cy2_n;
        end
    end

    // values that belong to the pixel entering stage 1
    wire [15:0] ctl0 = sof0 ? sw     : ctl_f;
    wire [15:0] t0   = sof0 ? t_next : t_f;
    wire signed [11:0] c1x0 = sof0 ? cx1_n : cx1_f, c1y0 = sof0 ? cy1_n : cy1_f;
    wire signed [11:0] c2x0 = sof0 ? cx2_n : cx2_f, c2y0 = sof0 ? cy2_n : cy2_f;

    // --------------------------------------- stage 1: coordinate transform
    wire [10:0] xv = x0  >> SH;
    wire [10:0] yv = y0c >> SH;
    wire [10:0] xm = (ctl0[10] && xv >= 11'(CX)) ? 11'(VW - 1) - xv : xv;
    wire [10:0] ym = (ctl0[10] && yv >= 11'(CY)) ? 11'(VH - 1) - yv : yv;

    logic [9:0]  xs1, ys1;
    logic [15:0] ctl1, t1;
    logic        sof1, eol1;
    logic signed [11:0] c1x1, c1y1, c2x1, c2y1;
    always_ff @(posedge clk) begin
        if (rst) vld1 <= 1'b0;
        else if (adv) begin
            vld1 <= 1'b1;
            xs1  <= ctl0[13] ? 10'((xm >> 1) + 11'(CX / 2)) : xm[9:0];
            ys1  <= ctl0[13] ? 10'((ym >> 1) + 11'(CY / 2)) : ym[9:0];
            ctl1 <= ctl0; t1 <= t0; sof1 <= sof0; eol1 <= eol0;
            c1x1 <= c1x0; c1y1 <= c1y0; c2x1 <= c2x0; c2y1 <= c2y0;
        end
    end

    // ---------------------------------- stage 2: sine lookups, squares
    wire [7:0] t1_8  = t1[7:0];
    wire [7:0] t1_15 = t1[7:0] + t1[8:1];
    wire [9:0] xy1   = xs1 + ys1;
    logic [7:0] s0w, s1w, s2w, s3w;
    sin_lut u_s0 (.a(xs1[8:1] + t1_8),               .y(s0w));
    sin_lut u_s1 (.a(ys1[8:1] - t1_15),              .y(s1w));
    sin_lut u_s2 (.a(xy1[9:2] + {1'b0, t1_8[7:1]}),  .y(s2w));
    sin_lut u_s3 (.a(ys1[7:0] + {t1_8[6:0], 1'b0}),  .y(s3w));

    wire signed [11:0] dx  = $signed({2'b0, xs1}) - 12'(CX);
    wire signed [11:0] dy  = $signed({2'b0, ys1}) - 12'(CY);
    wire signed [11:0] ex1 = $signed({2'b0, xs1}) - c1x1;
    wire signed [11:0] ey1 = $signed({2'b0, ys1}) - c1y1;
    wire signed [11:0] ex2 = $signed({2'b0, xs1}) - c2x1;
    wire signed [11:0] ey2 = $signed({2'b0, ys1}) - c2y1;

    logic [7:0]  s0, s1, s2, s3;
    logic [9:0]  xs2, ys2;
    logic [21:0] dx2, dy2, ex1q, ey1q, ex2q, ey2q;
    logic [15:0] ctl2, t2;
    logic        sof2, eol2;
    always_ff @(posedge clk) begin
        if (rst) vld2 <= 1'b0;
        else if (adv) begin
            vld2 <= vld1;
            s0 <= s0w; s1 <= s1w; s2 <= s2w; s3 <= s3w;
            xs2 <= xs1; ys2 <= ys1;
            dx2  <= 22'(dx  * dx);   dy2  <= 22'(dy  * dy);
            ex1q <= 22'(ex1 * ex1);  ey1q <= 22'(ey1 * ey1);
            ex2q <= 22'(ex2 * ex2);  ey2q <= 22'(ey2 * ey2);
            ctl2 <= ctl1; t2 <= t1; sof2 <= sof1; eol2 <= eol1;
        end
    end

    // ---------------------------------------- stage 3: pattern evaluation
    logic [15:0] lfsr = 16'hACE1;
    always_ff @(posedge clk)
        if (rst)      lfsr <= 16'hACE1;
        else if (adv) lfsr <= {1'b0, lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);

    wire [7:0]  t2_8 = t2[7:0];
    wire [9:0]  psum = 10'(s0) + 10'(s1) + 10'(s2) + 10'(s3);
    wire [21:0] d    = dx2  + dy2;
    wire [21:0] m1   = ex1q + ey1q;
    wire [21:0] m2   = ex2q + ey2q;
    wire [9:0]  wx   = xs2 + 10'(s3[7:3]);
    wire [9:0]  wy   = ys2 + 10'(s0[7:3]);

    logic [7:0] v3w;
    always_comb begin
        unique case (ctl2[2:0])
            3'd0: v3w = xs2[8:1] + ys2[8:1] + t2_8;                         // diagonal flow
            3'd1: v3w = (xs2[8:1] ^ ys2[8:1]) + t2_8;                       // XOR fabric
            3'd2: v3w = psum[9:2];                                          // plasma
            3'd3: v3w = d[12:5] - {t2_8[6:0], 1'b0};                        // zone plate
            3'd4: v3w = (m1[11] ^ m2[11]) ? 8'hD0 + {1'b0, t2_8[7:1]}
                                          : 8'h30 + {1'b0, t2_8[7:1]};      // moire
            3'd5: v3w = lfsr[7:0];                                          // static
            3'd6: v3w = (wx[5] ^ wy[5]) ? 8'hC0 + t2_8 : 8'h40 + t2_8;      // warp checker
            default: v3w = 8'd0;                                            // 7: stage 4
        endcase
    end

    logic [7:0]  val3, idx7;
    logic [15:0] ctl3, t3;
    logic        sof3, eol3;
    always_ff @(posedge clk) begin
        if (rst) vld3 <= 1'b0;
        else if (adv) begin
            vld3 <= vld2;
            val3 <= v3w;
            idx7 <= xs2[8:1] + s3;           // domain warp: sin(x + sin(y + 2t))
            ctl3 <= ctl2; t3 <= t2; sof3 <= sof2; eol3 <= eol2;
        end
    end

    // ------------------------ stage 4: second-level lookup, palette cycling
    logic [7:0] w7;
    sin_lut u_w7 (.a(idx7), .y(w7));
    logic [7:0]  val4;
    logic [15:0] ctl4;
    logic        sof4, eol4;
    always_ff @(posedge clk) begin
        if (rst) vld4 <= 1'b0;
        else if (adv) begin
            vld4 <= vld3;
            val4 <= ((ctl3[2:0] == 3'd7) ? w7 : val3) + (ctl3[14] ? t3[7:0] : 8'd0);
            ctl4 <= ctl3; sof4 <= sof3; eol4 <= eol3;
        end
    end

    // ------------------------------------------ stage 5: palette lookups
    wire [2:0] pal4 = ctl4[8:6];
    wire [7:0] v2x  = {val4[6:0], 1'b0};
    wire [7:0] v3x  = val4 + {val4[6:0], 1'b0};
    logic [7:0] ir, ig, ib;
    always_comb begin
        unique case (pal4)
            3'd1:    begin ir = val4;          ig = val4 + 8'd85;  ib = val4 + 8'd171; end // rainbow
            3'd2:    begin ir = val4 + 8'd128; ig = val4 + 8'd200; ib = val4 + 8'd20;  end // ocean
            3'd3:    begin ir = val4;          ig = val4 + 8'd36;  ib = val4 + 8'd96;  end // sunset
            3'd4:    begin ir = v2x;           ig = v2x + 8'd85;   ib = v2x + 8'd171;  end // neon
            3'd6:    begin ir = v3x;           ig = v3x + 8'd128;  ib = v3x + 8'd64;   end // acid
            default: begin ir = val4;          ig = val4;          ib = val4;          end
        endcase
    end
    logic [7:0] lr, lg, lb;
    sin_lut u_pr (.a(ir), .y(lr));
    sin_lut u_pg (.a(ig), .y(lg));
    sin_lut u_pb (.a(ib), .y(lb));

    logic [7:0]  lr5, lg5, lb5, val5;
    logic [15:0] ctl5;
    logic        sof5, eol5;
    always_ff @(posedge clk) begin
        if (rst) vld5 <= 1'b0;
        else if (adv) begin
            vld5 <= vld4;
            lr5 <= lr; lg5 <= lg; lb5 <= lb; val5 <= val4;
            ctl5 <= ctl4; sof5 <= sof4; eol5 <= eol4;
        end
    end

    // ------------------------- stage 6: palette shaping, posterize, invert
    logic [7:0] r6w, g6w, b6w;
    always_comb begin
        unique case (ctl5[8:6])
            3'd0: begin r6w = val5; g6w = val5; b6w = val5; end                         // gray
            3'd2: begin r6w = {2'b0, lr5[7:2]}; g6w = lg5; b6w = lb5 | 8'h40; end        // ocean
            3'd3: begin r6w = lr5 | 8'h30; g6w = {1'b0, lg5[7:1]}; b6w = {1'b0, lb5[7:1]}; end
            3'd5: begin                                                                  // fire
                r6w = val5[7] ? 8'hFF : {val5[6:0], 1'b0};
                g6w = val5[7] ? {val5[6:0], 1'b0} : 8'h00;
                b6w = (val5 >= 8'd224) ? {val5[4:0], 3'b0} : 8'h00;
            end
            3'd7: begin r6w = {3'b0, val5[7:3]}; g6w = val5; b6w = {2'b0, val5[7:2]}; end // CRT
            default: begin r6w = lr5; g6w = lg5; b6w = lb5; end
        endcase
        if (ctl5[11]) begin
            r6w = {4{r6w[7:6]}};
            g6w = {4{g6w[7:6]}};
            b6w = {4{b6w[7:6]}};
        end
        if (ctl5[9]) begin
            r6w = ~r6w; g6w = ~g6w; b6w = ~b6w;
        end
    end

    logic [7:0] r6, g6, b6;
    logic       sof6, eol6;
    always_ff @(posedge clk) begin
        if (rst) vld6 <= 1'b0;
        else if (adv) begin
            vld6 <= vld5;
            r6 <= r6w; g6 <= g6w; b6 <= b6w;
            sof6 <= sof5; eol6 <= eol5;
        end
    end

    // ------------------------------------------------- AXI4-Stream output
    assign m_tvalid = vld6;
    assign m_tdata  = {r6, b6, g6};      // UG934 RGB order: R, B, G
    assign m_tuser  = sof6;
    assign m_tlast  = eol6;

`ifndef SYNTHESIS
    // AXI4-Stream rule: once valid, data and sideband hold until accepted
    a_axis_hold: assert property (@(posedge clk) disable iff (rst)
        (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata) && $stable(m_tuser) && $stable(m_tlast)));
`endif
endmodule
`default_nettype wire
