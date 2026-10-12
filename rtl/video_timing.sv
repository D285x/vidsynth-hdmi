// ============================================================================
// video_timing.sv - raster timing generator
// Two counters (h, v) and registered timing signals. hsync/vsync are
// output with the polarity required by the selected CTA-861 mode.
// All outputs are registered together and therefore mutually aligned.
// ============================================================================
`default_nettype none
module video_timing #(
    parameter int MODE = 0
)(
    input  wire logic        clk,
    input  wire logic        rst,
    output logic      [11:0] hc,      // horizontal position of this pixel
    output logic      [11:0] vc,      // vertical position (line) of this pixel
    output logic             de,      // active video
    output logic             hsync,   // with mode polarity
    output logic             vsync    // with mode polarity
);
    import vs_pkg::*;
    localparam int H_ACT = h_act(MODE), H_FP = h_fp(MODE), H_SY = h_sync(MODE), H_TOT = h_tot(MODE);
    localparam int V_ACT = v_act(MODE), V_FP = v_fp(MODE), V_SY = v_sync(MODE), V_TOT = v_tot(MODE);
    localparam bit POS   = sync_pos(MODE);

    logic [11:0] hcnt = '0, vcnt = '0;

    always_ff @(posedge clk) begin
        if (rst) begin
            hcnt <= '0;
            vcnt <= '0;
        end else if (hcnt == 12'(H_TOT - 1)) begin
            hcnt <= '0;
            vcnt <= (vcnt == 12'(V_TOT - 1)) ? '0 : vcnt + 12'd1;
        end else begin
            hcnt <= hcnt + 12'd1;
        end
    end

    wire hs_act = (hcnt >= 12'(H_ACT + H_FP)) && (hcnt < 12'(H_ACT + H_FP + H_SY));
    wire vs_act = (vcnt >= 12'(V_ACT + V_FP)) && (vcnt < 12'(V_ACT + V_FP + V_SY));

    always_ff @(posedge clk) begin
        hc <= hcnt;
        vc <= vcnt;
        if (rst) begin                      // blank, syncs inactive, while in reset
            de    <= 1'b0;
            hsync <= ~POS;
            vsync <= ~POS;
        end else begin
            de    <= (hcnt < 12'(H_ACT)) && (vcnt < 12'(V_ACT));
            hsync <= POS ? hs_act : ~hs_act;
            vsync <= POS ? vs_act : ~vs_act;
        end
    end

`ifndef SYNTHESIS
    // de is only ever asserted inside the active area
    a_de_area: assert property (@(posedge clk) disable iff (rst)
        de |-> (hc < 12'(H_ACT)) && (vc < 12'(V_ACT)));
`endif
endmodule
`default_nettype wire
