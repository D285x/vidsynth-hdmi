// ============================================================================
// sync_2ff.sv - two-flip-flop synchronizer for slow asynchronous inputs
// ============================================================================
`default_nettype none
module sync_2ff #(
    parameter int W = 1
)(
    input  wire logic         clk,
    input  wire logic [W-1:0] d,
    output logic      [W-1:0] q
);
    (* ASYNC_REG = "TRUE" *) logic [W-1:0] m = '0, s = '0;
    always_ff @(posedge clk) begin
        m <= d;
        s <= m;
    end
    assign q = s;
endmodule
`default_nettype wire
