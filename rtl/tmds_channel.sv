// ============================================================================
// tmds_channel.sv - one TMDS channel encoder for DVI/HDMI
// Produces, per pixel clock, one registered 10-bit character:
//   TM_VIDEO  : DVI 1.0 transition-minimised, DC-balanced 8b/10b of d
//   TM_CTRL   : control token selected by c[1:0]
//   TM_TERC4  : HDMI TERC4 character of t4[3:0]
//   TM_VGUARD : HDMI video leading guard band for this channel
//   TM_DGUARD : HDMI data island guard band (channels 1 and 2)
// Character words are written bit 9 first; bit 0 is transmitted first.
// ============================================================================
`default_nettype none
module tmds_channel #(
    parameter int CH = 0                 // 0 = blue, 1 = green, 2 = red
)(
    input  wire logic       clk,
    input  wire logic       rst,
    input  wire vs_pkg::tmds_mode_t mode,
    input  wire logic [7:0] d,
    input  wire logic [1:0] c,
    input  wire logic [3:0] t4,
    output logic      [9:0] q
);
    import vs_pkg::*;

    // ------------------------------------------------ stage 1: XOR / XNOR
    function automatic logic [3:0] ones8(input logic [7:0] v);
        ones8 = '0;
        for (int i = 0; i < 8; i++) ones8 += 4'(v[i]);
    endfunction

    wire  [3:0] n1d     = ones8(d);
    wire        use_xnr = (n1d > 4'd4) || (n1d == 4'd4 && d[0] == 1'b0);
    function automatic logic [8:0] minimise(input logic [7:0] v, input logic xnr);
        logic [8:0] m;
        m[0] = v[0];
        for (int k = 1; k < 8; k++)
            m[k] = xnr ? ~(m[k-1] ^ v[k]) : (m[k-1] ^ v[k]);
        m[8] = ~xnr;
        return m;
    endfunction
    wire [8:0] qm = minimise(d, use_xnr);

    // ------------------------------------------- stage 2: DC balancing
    wire  [3:0]        n1q = ones8(qm[7:0]);
    wire  signed [5:0] d10 = ($signed({2'b0, n1q}) - 6'sd4) <<< 1;   // n1 - n0
    logic signed [5:0] cnt = '0;                                      // running disparity

    // ------------------------------------------------------ TERC4 table
    function automatic logic [9:0] terc4(input logic [3:0] v);
        unique case (v)
            4'h0: terc4 = 10'b1010011100;  4'h1: terc4 = 10'b1001100011;
            4'h2: terc4 = 10'b1011100100;  4'h3: terc4 = 10'b1011100010;
            4'h4: terc4 = 10'b0101110001;  4'h5: terc4 = 10'b0100011110;
            4'h6: terc4 = 10'b0110001110;  4'h7: terc4 = 10'b0100111100;
            4'h8: terc4 = 10'b1011001100;  4'h9: terc4 = 10'b0100111001;
            4'hA: terc4 = 10'b0110011100;  4'hB: terc4 = 10'b1011000110;
            4'hC: terc4 = 10'b1010001110;  4'hD: terc4 = 10'b1001110001;
            4'hE: terc4 = 10'b0101100011;  default: terc4 = 10'b1011000011;
        endcase
    endfunction

    function automatic logic [9:0] ctrl_token(input logic [1:0] v);
        unique case (v)
            2'b00: ctrl_token = 10'b1101010100;
            2'b01: ctrl_token = 10'b0010101011;
            2'b10: ctrl_token = 10'b0101010100;
            default: ctrl_token = 10'b1010101011;
        endcase
    endfunction

    localparam logic [9:0] VGUARD = (CH == 1) ? 10'b0100110011 : 10'b1011001100;
    localparam logic [9:0] DGUARD = 10'b0100110011;

    always_ff @(posedge clk) begin
        if (rst) begin
            q   <= ctrl_token(2'b00);
            cnt <= '0;
        end else begin
            unique case (mode)
                TM_VIDEO: begin
                    if (cnt == 0 || n1q == 4'd4) begin
                        q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
                        cnt <= qm[8] ? cnt + d10 : cnt - d10;
                    end else if ((cnt > 0 && n1q > 4'd4) || (cnt < 0 && n1q < 4'd4)) begin
                        q   <= {1'b1, qm[8], ~qm[7:0]};
                        cnt <= cnt + (qm[8] ? 6'sd2 : 6'sd0) - d10;
                    end else begin
                        q   <= {1'b0, qm[8], qm[7:0]};
                        cnt <= cnt - (qm[8] ? 6'sd0 : 6'sd2) + d10;
                    end
                end
                TM_TERC4:  begin q <= terc4(t4);     cnt <= '0; end
                TM_VGUARD: begin q <= VGUARD;        cnt <= '0; end
                TM_DGUARD: begin q <= DGUARD;        cnt <= '0; end
                default:   begin q <= ctrl_token(c); cnt <= '0; end
            endcase
        end
    end

`ifndef SYNTHESIS
    // the running disparity of TMDS video stays bounded
    a_disparity: assert property (@(posedge clk) disable iff (rst)
        (cnt >= -6'sd16) && (cnt <= 6'sd16));
`endif
endmodule
`default_nettype wire
