// ============================================================================
// vs_pkg.sv - shared definitions for the vidsynth video synthesizer
//
// Video modes (parameter MODE everywhere):
//   0 = 640x480  @ 60 Hz, CTA-861 VIC 1, 4:3,  negative syncs
//   1 = 1280x720 @ 60 Hz, CTA-861 VIC 4, 16:9, positive syncs
// ============================================================================
`default_nettype none
package vs_pkg;

    // ---------------------------------------------------------- video timing
    function automatic int h_act (int mode); return (mode == 1) ? 1280 : 640; endfunction
    function automatic int h_fp  (int mode); return (mode == 1) ?  110 :  16; endfunction
    function automatic int h_sync(int mode); return (mode == 1) ?   40 :  96; endfunction
    function automatic int h_bp  (int mode); return (mode == 1) ?  220 :  48; endfunction
    function automatic int v_act (int mode); return (mode == 1) ?  720 : 480; endfunction
    function automatic int v_fp  (int mode); return (mode == 1) ?    5 :  10; endfunction
    function automatic int v_sync(int mode); return (mode == 1) ?    5 :   2; endfunction
    function automatic int v_bp  (int mode); return (mode == 1) ?   20 :  33; endfunction
    function automatic int h_tot (int mode); return h_act(mode) + h_fp(mode) + h_sync(mode) + h_bp(mode); endfunction
    function automatic int v_tot (int mode); return v_act(mode) + v_fp(mode) + v_sync(mode) + v_bp(mode); endfunction
    function automatic bit sync_pos(int mode); return (mode == 1); endfunction
    function automatic int vic   (int mode); return (mode == 1) ? 4 : 1; endfunction
    function automatic bit wide  (int mode); return (mode == 1); endfunction   // 16:9

    // pattern coordinates are scaled by 2^coord_shift (720p -> 640x360 virtual)
    function automatic int coord_shift(int mode); return (mode == 1) ? 1 : 0; endfunction

    // ------------------------------------------------- audio clock regeneration
    // 128 * fs = f_TMDS * N / CTS, N = 6144 for 48 kHz.
    // Mode 0: f_TMDS = 25.0 MHz      -> CTS = 25000 (exact)
    // Mode 1: f_TMDS = 74.21875 MHz  -> CTS = 74219 (fs = 47,999.84 Hz)
    localparam int ACR_N = 6144;
    function automatic int acr_cts(int mode); return (mode == 1) ? 74219 : 25000; endfunction

    // pixel clock in Hz (for dividers such as the I2C bit clock)
    function automatic int pix_hz(int mode); return (mode == 1) ? 74_218_750 : 25_000_000; endfunction

    // --------------------------------------------------------- TMDS channel
    typedef enum logic [2:0] {
        TM_CTRL   = 3'd0,   // control token from c[1:0]
        TM_VIDEO  = 3'd1,   // 8b/10b TMDS video character from d[7:0]
        TM_TERC4  = 3'd2,   // TERC4 character from t4[3:0]
        TM_VGUARD = 3'd3,   // video leading guard band
        TM_DGUARD = 3'd4    // data island guard band (channels 1 and 2)
    } tmds_mode_t;

endpackage
`default_nettype wire
