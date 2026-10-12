// ============================================================================
// axis_to_video.sv - AXI4-Stream video slave to timed video (like AMD's
// "AXI4-Stream to Video Out" bridge, without a FIFO)
//
// The video timing generator runs freely. The bridge locks the stream to it:
//   UNLOCKED: discard stream pixels until the stream's head is a start of
//             frame (tuser); then wait for the timing's first active pixel
//             and lock on it.
//   LOCKED:   pull one pixel (tready) for every active timing pixel. If the
//             stream is not valid when needed (underflow), or its tuser /
//             tlast disagree with the timing (misalignment), drop lock and
//             re-synchronise at the next frame.
// While unlocked, active pixels are output black.
// Outputs are registered one cycle after the timing inputs, all aligned.
// ============================================================================
`default_nettype none
module axis_to_video #(
    parameter int MODE = 0
)(
    input  wire logic        clk,
    input  wire logic        rst,
    // timing in
    input  wire logic [11:0] t_hc,
    input  wire logic [11:0] t_vc,
    input  wire logic        t_de,
    input  wire logic        t_hs,
    input  wire logic        t_vs,
    // AXI4-Stream video in (UG934 RGB: [23:16] R, [15:8] B, [7:0] G)
    input  wire logic [23:0] s_tdata,
    input  wire logic        s_tvalid,
    output logic             s_tready,
    input  wire logic        s_tuser,
    input  wire logic        s_tlast,
    // timed video out
    output logic      [7:0]  red,
    output logic      [7:0]  green,
    output logic      [7:0]  blue,
    output logic             de,
    output logic             hsync,
    output logic             vsync,
    output logic      [11:0] hc,
    output logic      [11:0] vc,
    output logic             locked,
    output logic      [15:0] err_count      // lock losses since reset
);
    import vs_pkg::*;
    localparam int H_ACT = h_act(MODE);

    wire t_sof = t_de && (t_hc == 12'd0) && (t_vc == 12'd0);
    wire t_eol = t_de && (t_hc == 12'(H_ACT - 1));

    wire lock_now = !locked && t_sof && s_tvalid && s_tuser;
    wire mismatch = locked && t_de && (!s_tvalid || (s_tuser != t_sof) || (s_tlast != t_eol));
    wire take     = (locked && t_de && !mismatch) || lock_now;

    always_comb begin
        if (!locked) s_tready = (s_tvalid && !s_tuser) || lock_now;   // flush or lock
        else         s_tready = t_de;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            locked    <= 1'b0;
            err_count <= '0;
        end else if (lock_now) begin
            locked <= 1'b1;
        end else if (mismatch) begin
            locked    <= 1'b0;
            err_count <= err_count + 16'd1;
        end
    end

    always_ff @(posedge clk) begin
        red   <= take ? s_tdata[23:16] : 8'd0;
        blue  <= take ? s_tdata[15:8]  : 8'd0;
        green <= take ? s_tdata[7:0]   : 8'd0;
        de    <= t_de;
        hsync <= t_hs;
        vsync <= t_vs;
        hc    <= t_hc;
        vc    <= t_vc;
    end
endmodule
`default_nettype wire
