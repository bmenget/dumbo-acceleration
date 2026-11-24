// Pipelined Spongent-pi[160]: a ring of S pipeline stages, each computing K rounds (R = S*K physical rounds).
//
// A call enters at stage 0, circulates 80/(S*K) laps and leaves at the same point it entered, so the ring
// behaves like S interleaved iterative cores of K rounds/cycle sharing one set of round logic: slot s is at
// the loop point every S cycles. Up to S calls are in flight; steady-state throughput S*K/80 calls/cycle.
// Calls finish in the order they were accepted (fixed latency), and a finishing call frees its slot in the
// same cycle, so back-to-back insertion never stalls.
//
// Interface (no back-pressure on the output: the consumer must take every out_valid pulse):
//   in_valid/in_ready : handshake; the call (in_state, in_tag) is accepted in a cycle where both are high.
//                       in_ready is high when the slot now at the loop point is empty or finishing.
//   out_valid         : one-cycle pulse, 80/K + 1 cycles after the cycle the call was accepted
//                       (same convention as spongent_perm_iter: 80/R + 1 cycles after start).
//   out_state/out_tag : the permuted state and the tag the call was accepted with (registered).
//
// Each slot carries its own 7-bit round-constant LFSR; "finished" = the LFSR value after 80 rounds, which is
// unique among the values after 0..80 rounds (period 127), so no round counter is needed. The insertion mux
// sits after stage S-1's rounds (6-input LUT per bit, one level), so only that round loses the 2-S-box-bits-
// per-LUT6 packing; the other rounds feed pipeline registers directly.
// Bit convention as spongent_round: state[i] == model bit i (byte 0 = state[7:0]).
module spongent_perm_pipe #(
    parameter int S  = 4,              // pipeline stages (= max calls in flight)
    parameter int K  = 1,              // rounds per stage (combinational depth)
    parameter int TW = 4               // tag width
) (
    input  logic          clk,
    input  logic          rst,         // synchronous, active high (LWC convention)
    input  logic          in_valid,
    output logic          in_ready,
    input  logic [159:0]  in_state,
    input  logic [TW-1:0] in_tag,
    output logic          out_valid,
    output logic [159:0]  out_state,
    output logic [TW-1:0] out_tag
);
    if (S < 1 || K < 1 || (80 % (S * K)) != 0) begin : g_bad_sk
        $error("spongent_perm_pipe: S >= 1, K >= 1 and S*K must divide 80");
    end
    if (TW < 1) begin : g_bad_tw
        $error("spongent_perm_pipe: TW must be >= 1");
    end

    function automatic logic [6:0] lfsr_step(input logic [6:0] v);
        lfsr_step = {v[5:0], v[6] ^ v[5]};
    endfunction
    function automatic logic [6:0] lfsr_adv(input logic [6:0] v, input int j);
        lfsr_adv = v;
        for (int k = 0; k < j; k++) lfsr_adv = lfsr_step(lfsr_adv);
    endfunction
    function automatic logic [7:0] bitrev8(input logic [7:0] v);
        for (int k = 0; k < 8; k++) bitrev8[k] = v[7-k];
    endfunction

    localparam logic [6:0] LFSR0   = 7'h75;
    localparam logic [6:0] LFSR_80 = lfsr_adv(LFSR0, 80);   // value after the last round of a call

    // stage registers
    logic [159:0]  st [0:S-1];
    logic [6:0]    lf [0:S-1];
    logic          vl [0:S-1];
    logic [TW-1:0] tg [0:S-1];

    // combinational K rounds after each stage register
    logic [159:0] nst [0:S-1];
    logic [6:0]   nlf [0:S-1];

    genvar s, j;
    generate
        for (s = 0; s < S; s++) begin : g_stage
            logic [159:0] chain [0:K];
            assign chain[0] = st[s];
            for (j = 0; j < K; j++) begin : g_round
                spongent_round u_round (
                    .state_in (chain[j]),
                    .rc_lo    ({1'b0, lfsr_adv(lf[s], j)}),
                    .rc_hi    (bitrev8({1'b0, lfsr_adv(lf[s], j)})),
                    .state_out(chain[j+1])
                );
            end
            assign nst[s] = chain[K];
            assign nlf[s] = lfsr_adv(lf[s], K);
        end
    endgenerate

    // loop point: output of stage S-1's rounds
    logic fin, accept;
    assign fin      = vl[S-1] && (nlf[S-1] == LFSR_80);
    assign in_ready = !vl[S-1] || fin;
    assign accept   = in_valid && in_ready;

    // datapath registers (no reset: vl qualifies everything)
    always_ff @(posedge clk) begin
        for (int k = 1; k < S; k++) begin
            st[k] <= nst[k-1];
            lf[k] <= nlf[k-1];
            tg[k] <= tg[k-1];
        end
        if (accept) begin
            st[0] <= in_state;
            lf[0] <= LFSR0;
            tg[0] <= in_tag;
        end else begin
            st[0] <= nst[S-1];
            lf[0] <= nlf[S-1];
            tg[0] <= tg[S-1];
        end
        out_state <= nst[S-1];
        out_tag   <= tg[S-1];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k < S; k++) vl[k] <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            for (int k = 1; k < S; k++) vl[k] <= vl[k-1];
            vl[0]     <= accept ? 1'b1 : (vl[S-1] && !fin);
            out_valid <= fin;
        end
    end
endmodule
