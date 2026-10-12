// ============================================================================
// audio_gen.sv - 48 kHz stereo tone generator locked to the TMDS clock
//
// Sample tick: an exact rational divider. Every pixel clock acc += N; when
// acc reaches 128*CTS a sample is produced. Over 128*CTS clocks exactly N
// samples appear, so the average sample rate equals f_TMDS * N / (128 CTS),
// precisely what the Audio Clock Regeneration packets announce.
//
// Tones: two DDS oscillators (24-bit phase, 256-entry sine), left = a note
// chosen by note_sel, right = a perfect fifth above. Amplitude +/-8128.
// Each sample carries its IEC 60958 frame index (0..191) within the block.
// ============================================================================
`default_nettype none
module audio_gen #(
    parameter int N   = 6144,
    parameter int CTS = 25000
)(
    input  wire logic              clk,
    input  wire logic              rst,
    input  wire logic [2:0]        note_sel,
    output logic                   s_valid,     // one-cycle pulse per sample
    output logic signed [15:0]     s_left,
    output logic signed [15:0]     s_right,
    output logic       [7:0]       s_frame      // index in the 192-frame block
);
    localparam int MOD = 128 * CTS;

    // ------------------------------------------------ exact sample ticks
    logic [24:0] acc = '0;
    wire  [24:0] acc_n = acc + 25'(N);
    wire         tick  = (acc_n >= 25'(MOD));
    always_ff @(posedge clk) begin
        if (rst) acc <= '0;
        else     acc <= tick ? acc_n - 25'(MOD) : acc_n;
    end

    // -------------------------------------------- DDS phase increments
    // round(f / 48000 * 2^24): C4 D4 E4 G4 A4 C5 D5 E5, right = 1.5 x left
    logic [23:0] inc_l, inc_r;
    always_comb begin
        unique case (note_sel)
            3'd0: begin inc_l = 24'd91446;  inc_r = 24'd137169; end
            3'd1: begin inc_l = 24'd102642; inc_r = 24'd153962; end
            3'd2: begin inc_l = 24'd115214; inc_r = 24'd172821; end
            3'd3: begin inc_l = 24'd137014; inc_r = 24'd205521; end
            3'd4: begin inc_l = 24'd153791; inc_r = 24'd230687; end
            3'd5: begin inc_l = 24'd182889; inc_r = 24'd274334; end
            3'd6: begin inc_l = 24'd205287; inc_r = 24'd307930; end
            default: begin inc_l = 24'd230425; inc_r = 24'd345637; end
        endcase
    end

    logic [23:0] ph_l = '0, ph_r = '0;
    logic [7:0]  sl, sr;
    sin_lut u_sl (.a(ph_l[23:16]), .y(sl));
    sin_lut u_sr (.a(ph_r[23:16]), .y(sr));

    wire signed [8:0] cl = $signed({1'b0, sl}) - 9'sd128;   // -128 .. +127
    wire signed [8:0] cr = $signed({1'b0, sr}) - 9'sd128;
    logic [7:0] frame = '0;
    always_ff @(posedge clk) begin
        s_valid <= 1'b0;
        if (rst) begin
            ph_l <= '0; ph_r <= '0; frame <= '0;
        end else if (tick) begin
            s_valid <= 1'b1;
            s_left  <= 16'(cl) <<< 6;                // -8192 .. +8128
            s_right <= 16'(cr) <<< 6;
            s_frame <= frame;
            frame   <= (frame == 8'd191) ? 8'd0 : frame + 8'd1;
            ph_l    <= ph_l + inc_l;
            ph_r    <= ph_r + inc_r;
        end
    end
endmodule
`default_nettype wire
