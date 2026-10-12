// ============================================================================
// edid_reader.sv - reads a display's EDID over DDC (I2C) and parses it
//
// I2C master, standard mode (~100 kHz, 4 quarter-bit phases per bit),
// open-drain: *_oe = 1 pulls the line low, 0 releases it. Clock stretching
// is honoured. Sequence (random read of 256 bytes from device 0x50):
//   START, 0xA0, 0x00, repeated START, 0xA1, 256 x read (ACK, last NACK), STOP
// Bytes are parsed on the fly; nothing is stored:
//   edid_ok  : header 00 FF FF FF FF FF FF 00 and checksums of blocks read
//   is_hdmi  : CTA block has a Vendor-Specific Data Block with OUI 00-0C-03
//   qs       : Video Capability Data Block has QS (bit 6) set
//   has_720p : Video Data Block lists VIC 4
// The read is repeated every REFRESH_CYCLES; results update only after a
// complete, valid read; a failed read clears edid_ok.
// ============================================================================
`default_nettype none
module edid_reader #(
    parameter int CLK_HZ         = 25_000_000,
    parameter int I2C_HZ         = 100_000,
    parameter int REFRESH_CYCLES = 25_000_000       // about 1 s at 25 MHz
)(
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic scl_i,      // bus level (synchronised here)
    input  wire logic sda_i,
    output logic      scl_oe,     // 1 = pull SCL low
    output logic      sda_oe,     // 1 = pull SDA low
    output logic      edid_ok,
    output logic      is_hdmi,
    output logic      qs,
    output logic      has_720p,
    output logic      busy
);
    // ------------------------------------------------- input synchronisers
    (* ASYNC_REG = "TRUE" *) logic [1:0] scl_s = 2'b11, sda_s = 2'b11;
    always_ff @(posedge clk) begin
        scl_s <= {scl_s[0], scl_i};
        sda_s <= {sda_s[0], sda_i};
    end
    wire scl = scl_s[1];
    wire sda = sda_s[1];

    // ------------------------------------------------- quarter-bit tick
    localparam int QDIV = (CLK_HZ / (4 * I2C_HZ)) < 2 ? 2 : (CLK_HZ / (4 * I2C_HZ));
    logic [$clog2(QDIV+1)-1:0] qcnt = '0;
    wire  qtick = (qcnt == '0);
    always_ff @(posedge clk)
        qcnt <= qtick ? $bits(qcnt)'(QDIV - 1) : qcnt - 1'b1;

    // ------------------------------------------------- refresh timer
    logic [31:0] timer = 32'd1000;            // first read soon after reset
    wire         start_req = (timer == 0);

    // ------------------------------------------------- bit engine FSM
    typedef enum logic [3:0] {
        S_IDLE, S_START, S_WBYTE, S_WACK, S_RBYTE, S_RACK, S_STOP, S_DONE
    } state_t;
    state_t st = S_IDLE;

    logic [1:0] ph  = '0;        // quarter phase within the current bit
    logic [2:0] bitn = '0;       // bit index, MSB first
    logic [7:0] sh  = '0;        // shift register
    logic [2:0] step = '0;       // 0:A0 1:00 2:restart 3:A1 4:read bytes
    logic [8:0] nbyte = '0;      // bytes read
    logic       fail = 1'b0;

    // ------------------------------------------------- byte parser
    // Fed one byte at a time (b_stb) while the read is in progress.
    logic       b_stb = 1'b0, p_clear = 1'b0;
    logic [8:0] b_idx;
    logic [7:0] b_val;

    logic       hdr_ok, cta, oui_ok, vcdb;
    logic [7:0] sum0, sum1, ext_cnt, dtd_off, next_hdr, pstart;
    logic [2:0] tag;
    logic       p_hdmi, p_qs, p_720;

    function automatic logic [7:0] hdr_byte(input logic [2:0] i);
        return (i == 3'd0 || i == 3'd7) ? 8'h00 : 8'hFF;
    endfunction

    always_ff @(posedge clk) begin
        if (p_clear) begin
            hdr_ok <= 1'b1; sum0 <= '0; sum1 <= '0; ext_cnt <= '0;
            cta <= 1'b0; dtd_off <= '0; next_hdr <= 8'd4; pstart <= '0; tag <= '0;
            oui_ok <= 1'b0; vcdb <= 1'b0; p_hdmi <= 1'b0; p_qs <= 1'b0; p_720 <= 1'b0;
        end else if (b_stb) begin
            if (b_idx < 9'd128) begin
                sum0 <= sum0 + b_val;
                if (b_idx < 9'd8 && b_val != hdr_byte(b_idx[2:0])) hdr_ok <= 1'b0;
                if (b_idx == 9'd126) ext_cnt <= b_val;
            end else begin : blk1
                logic [7:0] o, k;
                o = {1'b0, b_idx[6:0]};               // offset within block 1 (idx - 128)
                k = o - pstart;                       // payload index in the current data block
                sum1 <= sum1 + b_val;
                if (o == 8'd0) cta     <= (b_val == 8'h02);
                if (o == 8'd2) dtd_off <= b_val;
                if (cta && o >= 8'd4 && o < dtd_off) begin
                    if (o == next_hdr) begin          // data block header: tag | length
                        tag      <= b_val[7:5];
                        pstart   <= o + 8'd1;
                        next_hdr <= o + 8'd1 + {3'b000, b_val[4:0]};
                    end else begin
                        if (tag == 3'd2 && b_val[6:0] == 7'd4) p_720 <= 1'b1;      // VIC 4
                        if (tag == 3'd3) begin                                     // VSDB OUI 03 0C 00
                            if (k == 8'd0) oui_ok <= (b_val == 8'h03);
                            if (k == 8'd1) oui_ok <= oui_ok && (b_val == 8'h0C);
                            if (k == 8'd2 && oui_ok && b_val == 8'h00) p_hdmi <= 1'b1;
                        end
                        if (tag == 3'd7) begin                                     // extended tag
                            if (k == 8'd0) vcdb <= (b_val == 8'h00);               // VCDB
                            if (k == 8'd1 && vcdb) p_qs <= b_val[6];               // QS
                        end
                    end
                end
            end
        end
    end

    // ------------------------------------------------- main FSM
    always_ff @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; scl_oe <= 1'b0; sda_oe <= 1'b0;
            timer <= 32'd1000; busy <= 1'b0;
            edid_ok <= 1'b0; is_hdmi <= 1'b0; qs <= 1'b0; has_720p <= 1'b0;
        end else begin
            b_stb <= 1'b0; p_clear <= 1'b0;
            if (st == S_IDLE && timer != 0) timer <= timer - 1;
            if (qtick) begin
                unique case (st)
                S_IDLE: if (start_req) begin
                    st <= S_START; step <= 3'd0; ph <= '0; busy <= 1'b1; fail <= 1'b0;
                    nbyte <= '0; p_clear <= 1'b1;
                end
                S_START: begin                     // also used for repeated START
                    unique case (ph)
                        2'd0: begin sda_oe <= 1'b0; scl_oe <= 1'b1; end   // SCL low, SDA high
                        2'd1: scl_oe <= 1'b0;                            // SCL high
                        2'd2: if (scl) sda_oe <= 1'b1;                   // SDA falls: START
                        default: scl_oe <= 1'b1;                         // SCL low
                    endcase
                    if (ph != 2'd2 || scl) ph <= ph + 2'd1;
                    if (ph == 2'd3) begin
                        st <= S_WBYTE; bitn <= 3'd7;
                        sh <= (step == 3'd0) ? 8'hA0 : 8'hA1;
                        step <= (step == 3'd0) ? 3'd0 : 3'd3;
                    end
                end
                S_WBYTE: begin
                    unique case (ph)
                        2'd0: sda_oe <= ~sh[7];                          // set data while SCL low
                        2'd1: scl_oe <= 1'b0;                            // release SCL
                        2'd2: ;                                          // SCL high (stretch wait)
                        default: begin scl_oe <= 1'b1; sh <= {sh[6:0], 1'b0}; end
                    endcase
                    if (ph != 2'd2 || scl) ph <= ph + 2'd1;
                    if (ph == 2'd3) begin
                        if (bitn == 3'd0) st <= S_WACK;
                        bitn <= bitn - 3'd1;
                    end
                end
                S_WACK: begin
                    unique case (ph)
                        2'd0: sda_oe <= 1'b0;                            // release SDA
                        2'd1: scl_oe <= 1'b0;
                        2'd2: if (scl && sda) fail <= 1'b1;              // NACK
                        default: scl_oe <= 1'b1;
                    endcase
                    if (ph != 2'd2 || scl) ph <= ph + 2'd1;
                    if (ph == 2'd3) begin
                        if (fail) st <= S_STOP;
                        else unique case (step)
                            3'd0: begin st <= S_WBYTE; sh <= 8'h00; bitn <= 3'd7; step <= 3'd1; end
                            3'd1: begin st <= S_START; step <= 3'd2; end
                            default: begin st <= S_RBYTE; bitn <= 3'd7; step <= 3'd4; end
                        endcase
                    end
                end
                S_RBYTE: begin
                    unique case (ph)
                        2'd0: sda_oe <= 1'b0;                            // release SDA
                        2'd1: scl_oe <= 1'b0;
                        2'd2: if (scl) sh <= {sh[6:0], sda};             // sample
                        default: scl_oe <= 1'b1;
                    endcase
                    if (ph != 2'd2 || scl) ph <= ph + 2'd1;
                    if (ph == 2'd3) begin
                        if (bitn == 3'd0) st <= S_RACK;
                        bitn <= bitn - 3'd1;
                    end
                end
                S_RACK: begin
                    unique case (ph)
                        2'd0: begin
                            sda_oe <= (nbyte != 9'd255);                 // ACK, NACK on the last
                            b_stb  <= 1'b1; b_idx <= nbyte; b_val <= sh; // hand byte to parser
                        end
                        2'd1: scl_oe <= 1'b0;
                        2'd2: ;
                        default: scl_oe <= 1'b1;
                    endcase
                    if (ph != 2'd2 || scl) ph <= ph + 2'd1;
                    if (ph == 2'd3) begin
                        nbyte <= nbyte + 9'd1;
                        if (nbyte == 9'd255) st <= S_STOP;
                        else begin st <= S_RBYTE; bitn <= 3'd7; end
                    end
                end
                S_STOP: begin
                    unique case (ph)
                        2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end  // SCL low, SDA low
                        2'd1: scl_oe <= 1'b0;                            // SCL high
                        2'd2: if (scl) sda_oe <= 1'b0;                   // SDA rises: STOP
                        default: ;
                    endcase
                    if (ph != 2'd2 || scl) ph <= ph + 2'd1;
                    if (ph == 2'd3) st <= S_DONE;
                end
                default: begin                                           // S_DONE
                    busy  <= 1'b0;
                    timer <= 32'(REFRESH_CYCLES);
                    st    <= S_IDLE;
                    if (!fail && hdr_ok && sum0 == 8'd0 && (ext_cnt == 8'd0 || sum1 == 8'd0)) begin
                        edid_ok  <= 1'b1;
                        is_hdmi  <= (ext_cnt != 8'd0) && cta && p_hdmi;
                        qs       <= (ext_cnt != 8'd0) && cta && p_qs;
                        has_720p <= (ext_cnt != 8'd0) && cta && p_720;
                    end else begin
                        edid_ok  <= 1'b0;
                    end
                end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
