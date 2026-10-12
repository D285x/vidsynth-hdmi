// ============================================================================
// tb_hdmi_top.sv - serial-level, self-checking testbench for vidsynth_hdmi_top
//
// Samples the four TMDS lanes at the bit rate, aligns 10-bit characters on
// the clock lane, and parses the streams like an HDMI sink:
//   * every video period is compared, pixel by pixel, with the video that
//     entered the transmitter (taken from the design's AXI4-Stream bridge),
//     including limited-range scaling where the configuration requires it
//   * every data island packet is checked with the BCH code (header and the
//     four subpackets), and packet types are counted
//   * the first complete decoded frame is written to hdmi_frame.ppm
// Runs in Vivado xsim with the real MMCME2/OSERDESE2 models, or in other
// simulators with +define+SIM (behavioural clock and serializer models).
// ============================================================================
`timescale 1ns/1ps
module tb_hdmi_top;
    parameter int MODE   = 0;
    parameter int FRAMES = 2;               // frames to check after alignment

    localparam int H_ACT = (MODE == 1) ? 1280 : 640;
    localparam int V_ACT = (MODE == 1) ? 720  : 480;
    localparam bit VPOS  = (MODE == 1);

    logic        clk = 1'b0;
    logic        btn = 1'b0;
    logic [15:0] sw  = 16'h805A;            // plasma, speed 3, rainbow, audio on
    wire  [15:0] led;
    wire         ck_p, ck_n;
    wire  [2:0]  d_p, d_n;
    wire         ddc_scl, ddc_sda;

    always #10 clk = ~clk;                  // 50 MHz board clock

    vidsynth_hdmi_top #(.CLKIN_MHZ(50), .MODE(MODE), .EDID_ENABLE(0)) dut (
        .clk(clk), .btn_rst(btn), .sw(sw), .led(led),
        .hdmi_clk_p(ck_p), .hdmi_clk_n(ck_n), .hdmi_d_p(d_p), .hdmi_d_n(d_n),
        .ddc_scl(ddc_scl), .ddc_sda(ddc_sda)
    );

    // ------------------------------------------------ reference video lines
    logic [23:0] ref_px [$];
    realtime     ref_t  [$];
    always @(negedge dut.clk_pix) begin
        if (!dut.rst_core && dut.v_de) begin
            logic [7:0] r, g, b;
            r = dut.v_r; g = dut.v_g; b = dut.v_b;
            if (dut.cfg_limited) begin
                r = 8'd16 + 8'((16'(r) * 16'd220) >> 8);
                g = 8'd16 + 8'((16'(g) * 16'd220) >> 8);
                b = 8'd16 + 8'((16'(b) * 16'd220) >> 8);
            end
            if (dut.v_hc == 12'd0) ref_t.push_back($realtime);
            ref_px.push_back({r, g, b});
        end
    end

    // ------------------------------------------------------ decode helpers
    function automatic bit is_ctrl(input logic [9:0] w);
        return w == 10'b1101010100 || w == 10'b0010101011 || w == 10'b0101010100 || w == 10'b1010101011;
    endfunction
    function automatic logic [1:0] ctrl_val(input logic [9:0] w);
        case (w)
            10'b1101010100: return 2'b00;
            10'b0010101011: return 2'b01;
            10'b0101010100: return 2'b10;
            default:        return 2'b11;
        endcase
    endfunction
    function automatic logic [7:0] tmds_dec(input logic [9:0] w);
        logic [7:0] x, d;
        x = w[9] ? ~w[7:0] : w[7:0];
        d[0] = x[0];
        for (int i = 1; i < 8; i++) d[i] = w[8] ? (x[i] ^ x[i-1]) : ~(x[i] ^ x[i-1]);
        return d;
    endfunction
    function automatic int terc4_dec(input logic [9:0] w);
        logic [9:0] t [16] = '{10'b1010011100, 10'b1001100011, 10'b1011100100, 10'b1011100010,
                               10'b0101110001, 10'b0100011110, 10'b0110001110, 10'b0100111100,
                               10'b1011001100, 10'b0100111001, 10'b0110011100, 10'b1011000110,
                               10'b1010001110, 10'b1001110001, 10'b0101100011, 10'b1011000011};
        for (int i = 0; i < 16; i++) if (t[i] == w) return i;
        return -1;
    endfunction
    // BCH remainder of a block sent bit 0 first, g(x) = x^8 + x^7 + x^6 + 1
    function automatic logic [7:0] bch_syn(input logic [63:0] bits, input int n);
        logic [8:0] r;
        r = '0;
        for (int i = 0; i < n; i++) begin
            r = {r[7:0], bits[i]};
            if (r[8]) r = r ^ 9'b1_1100_0001;
        end
        return r[7:0];
    endfunction

    localparam logic [9:0] VG0 = 10'b1011001100, VG1 = 10'b0100110011, DG = 10'b0100110011;

    // ----------------------------------------------------------- the sink
    typedef enum {P_CTRL, P_VGUARD, P_VIDEO, P_DGUARD_LEAD, P_PACKET, P_DGUARD_TRAIL} per_t;
    per_t   per = P_CTRL;
    int     gcount = 0, vcount = 0, pkchar = 0, lines = 0, frames = 0;
    int     n_pix = 0, n_bad = 0, n_islands = 0, n_packets = 0, n_ecc_err = 0, n_terc_err = 0;
    int     n_type [256];
    logic [63:0] hdr, sub0, sub1, sub2, sub3;
    bit     vs_level = 1'b0, vs_prev = 1'b0, frame_armed = 1'b0, writing = 1'b0, done = 1'b0;
    int     fd, wr_lines = 0;

    task automatic on_char(input logic [9:0] c0, input logic [9:0] c1, input logic [9:0] c2);
        bit ctrl3;
        ctrl3 = is_ctrl(c0) && is_ctrl(c1) && is_ctrl(c2);
        if (is_ctrl(c0)) begin
            logic [1:0] cv;
            cv = ctrl_val(c0);
            vs_level = cv[1];
        end
        // a vertical sync pulse arms the frame writer
        if ((VPOS ? vs_level : !vs_level) && !(VPOS ? vs_prev : !vs_prev) && frames >= 1 && !writing && !done)
            frame_armed = 1'b1;
        vs_prev = vs_level;

        case (per)
            P_CTRL: begin
                if (c0 == VG0 && c1 == VG1 && c2 == VG0) begin per = P_VGUARD; gcount = 1; end
                else if (c1 == DG && c2 == DG) begin per = P_DGUARD_LEAD; gcount = 1; end
            end
            P_VGUARD: begin
                per = P_VIDEO; vcount = 0;
                // align with the reference: drop lines that started long before this one
                while (ref_t.size() > 0 && ref_t[0] < $realtime - (MODE ? 400.0 : 1200.0)) begin
                    void'(ref_t.pop_front());
                    repeat (H_ACT) void'(ref_px.pop_front());
                end
                if (frame_armed) begin
                    frame_armed = 1'b0; writing = 1'b1; wr_lines = 0;
                    fd = $fopen("hdmi_frame.ppm", "w");
                    $fwrite(fd, "P3\n%0d %0d\n255\n", H_ACT, V_ACT);
                end
            end
            P_VIDEO: begin
                if (ctrl3) begin
                    per = P_CTRL; lines++;
                    if (vcount != H_ACT) begin
                        n_bad++;
                        if (n_bad <= 5) $display("  line %0d: video period of %0d characters", lines, vcount);
                    end
                    if (writing) begin
                        wr_lines++;
                        if (wr_lines == V_ACT) begin
                            writing = 1'b0; done = 1'b1; $fclose(fd);
                        end
                    end
                    if (vcount == H_ACT && (lines % V_ACT) == 0) frames++;
                    void'(ref_t.pop_front());
                end else begin
                    logic [23:0] px, rp;
                    px = {tmds_dec(c2), tmds_dec(c1), tmds_dec(c0)};
                    rp = (ref_px.size() > 0) ? ref_px.pop_front() : 24'hxxxxxx;
                    if (px !== rp) begin
                        n_bad++;
                        if (n_bad <= 5) $display("  line %0d pixel %0d: decoded %h, expected %h", lines, vcount, px, rp);
                    end
                    n_pix++; vcount++;
                    if (writing) $fwrite(fd, "%0d %0d %0d\n", px[23:16], px[15:8], px[7:0]);
                end
            end
            P_DGUARD_LEAD: begin
                if (!(c1 == DG && c2 == DG)) n_terc_err++;
                per = P_PACKET; pkchar = 0; n_islands++;
            end
            P_PACKET: begin
                if (c1 == DG && c2 == DG) begin
                    per = P_DGUARD_TRAIL;
                end else begin
                    int t0, t1, t2;
                    t0 = terc4_dec(c0); t1 = terc4_dec(c1); t2 = terc4_dec(c2);
                    if (t0 < 0 || t1 < 0 || t2 < 0) n_terc_err++;
                    hdr[pkchar] = t0[2];
                    sub0[2*pkchar] = t1[0]; sub0[2*pkchar+1] = t2[0];
                    sub1[2*pkchar] = t1[1]; sub1[2*pkchar+1] = t2[1];
                    sub2[2*pkchar] = t1[2]; sub2[2*pkchar+1] = t2[2];
                    sub3[2*pkchar] = t1[3]; sub3[2*pkchar+1] = t2[3];
                    pkchar++;
                    if (pkchar == 32) begin
                        pkchar = 0; n_packets++;
                        n_type[hdr[7:0]]++;
                        if (bch_syn(hdr, 32) != 0 || bch_syn(sub0, 64) != 0 || bch_syn(sub1, 64) != 0 ||
                            bch_syn(sub2, 64) != 0 || bch_syn(sub3, 64) != 0) n_ecc_err++;
                    end
                end
            end
            default: begin                      // P_DGUARD_TRAIL: second trailing guard character
                if (!(c1 == DG && c2 == DG)) n_terc_err++;
                per = P_CTRL;
            end
        endcase
    endtask

    // ------------------------------------------- bit sampling and alignment
    localparam realtime HALF_BIT = (MODE == 1) ? 0.6735 : 2.0;   // ns after each serial-clock edge
    logic [9:0] wc = '0, w0 = '0, w1 = '0, w2 = '0;
    int nbits = 0, phase = -1;
    always @(dut.clk_x5) begin
        #(HALF_BIT);
        wc = {ck_p,   wc[9:1]};
        w0 = {d_p[0], w0[9:1]};
        w1 = {d_p[1], w1[9:1]};
        w2 = {d_p[2], w2[9:1]};
        nbits++;
        if (phase < 0) begin
            if (!dut.rst_link && wc == 10'b0000011111 && ck_n == ~ck_p) phase = nbits % 10;
        end else if (nbits % 10 == phase)
            on_char(w0, w1, w2);
    end

    initial begin
        foreach (n_type[i]) n_type[i] = 0;
        wait (frames >= FRAMES && done);
        $display("TMDS lanes aligned at bit phase %0d", phase);
        $display("Video pixels compared  : %0d", n_pix);
        $display("Video mismatches       : %0d", n_bad);
        $display("Data islands           : %0d", n_islands);
        $display("Packets                : %0d (Null %0d, ACR %0d, Audio %0d, AVI %0d, Audio IF %0d)",
                 n_packets, n_type[0], n_type[1], n_type[2], n_type[8'h82], n_type[8'h84]);
        $display("BCH / TERC4 errors     : %0d / %0d", n_ecc_err, n_terc_err);
        if (n_pix > 0 && n_bad == 0 && n_ecc_err == 0 && n_terc_err == 0 && n_islands > 0 &&
            n_type[1] > 0 && n_type[2] > 0 && n_type[8'h82] > 0 && n_type[8'h84] > 0)
            $display("HDMI SERIAL CHECK: PASS");
        else
            $display("HDMI SERIAL CHECK: FAIL");
        $finish;
    end

    initial begin
        #((MODE == 1) ? 80ms : 120ms);
        $display("HDMI SERIAL CHECK: TIMEOUT (frames %0d, lines %0d, phase %0d)", frames, lines, phase);
        $finish;
    end
endmodule
