// ECE545 core_v2_logan_pipe16x2d16_optIL: Logan's spongent_perm_pipe.sv (rtl/logan/, commit 74a0ef4) extended
// to P entry/exit points (see OPT_RING.md in this directory). With P = 1 it behaves like his original, except
// that "a call finishes here" is registered one cycle ahead (same cycle-level behaviour, shorter paths).
//
// Pipelined Spongent-pi[160]: a ring of S pipeline stages, each computing K rounds (R = S*K physical rounds).
//
// Points: P loop points, point i in front of stage register q_i = i*S/P (at the output of stage q_i-1's rounds).
// A call inserted at a point needs 80/K stage steps; when 80/K is a multiple of S/P it always finishes at a
// point (not necessarily the one it entered at: with S = 16, K = 2, P = 2 it makes 2.5 laps and leaves at the
// opposite point). Its slot is free at that point in the same cycle, so with one insertion opportunity per
// point per cycle all S slots stay busy: steady-state throughput S*K/80 calls/cycle, as the original, but S*K
// no longer has to divide 80 (16 x 2 = 32 rounds: the 32-bit bus limit for Dumbo, 2 calls per 20-byte block).
//
// Interface: as the original (no back-pressure on the output):
//   in_valid/in_ready : the call (in_state, in_tag) is accepted in a cycle where both are high; at most one
//                       call per cycle, at the lowest-numbered point whose slot is empty or finishing.
//   out_valid         : one-cycle pulse, 80/K + 1 cycles after the call was accepted. Every call has the same
//                       latency and at most one is accepted per cycle, so results leave in acceptance order and
//                       at most one call finishes per cycle.
//   out_state/out_tag : the permuted state and the tag the call was accepted with (registered).
//
// Each slot carries its own 7-bit round-constant LFSR; "finished" = the LFSR value after 80 rounds. fin_r(i) =
// "the call at the output of stage q_i-1 finishes this cycle", computed one cycle ahead from the stage before
// (needs S/P >= 2, so that stage q_i-2 is not itself an insertion point feeding q_i-1).
// Bit convention as spongent_round: state[i] == model bit i (byte 0 = state[7:0]).
module spongent_perm_pipe #(
    parameter int S  = 4,              // pipeline stages (= max calls in flight)
    parameter int K  = 1,              // rounds per stage (combinational depth)
    parameter int TW = 4,              // tag width
    parameter int P  = 1               // entry/exit points (ECE545 addition)
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
    localparam int SP = S / P;                 // stages between points
    localparam int L  = 80 / K;                // stage steps per call
    if (S < 1 || K < 1 || P < 1 || (80 % K) != 0 || (S % P) != 0 || (L % SP) != 0) begin : g_bad_skp
        $error("spongent_perm_pipe: need K | 80, P | S and (80/K) a multiple of S/P");
    end
    if (SP < 2) begin : g_bad_sp
        $error("spongent_perm_pipe: points must be at least 2 stages apart (S/P >= 2)");
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
    function automatic int prv(input int k);   // the stage feeding stage k
        prv = (k + S - 1) % S;
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
            logic busy;                        // profile probe (profile.txt): stage s holds a call
            assign busy = vl[s];
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

    // points: fin_r(i) registered one cycle ahead from the stage two before point i
    logic [P-1:0] fin_r, free, acc;
    logic         accept, fin_any;
    always_comb begin
        for (int i = 0; i < P; i++)
            free[i] = !vl[prv(i*SP)] || fin_r[i];
        acc = '0;
        for (int i = P-1; i >= 0; i--)          // lowest-numbered free point wins
            if (free[i]) acc = P'(1) << i;
        if (!in_valid) acc = '0;
    end
    assign in_ready = |free;
    assign accept   = |acc;
    assign fin_any  = |fin_r;

    // datapath registers (no reset: vl qualifies everything)
    always_ff @(posedge clk) begin
        for (int k = 0; k < S; k++) begin
            if (k % SP == 0 && acc[k / SP]) begin
                st[k] <= in_state;
                lf[k] <= LFSR0;
                tg[k] <= in_tag;
            end else begin
                st[k] <= nst[prv(k)];
                lf[k] <= nlf[prv(k)];
                tg[k] <= tg[prv(k)];
            end
        end
        // result: at most one point finishes per cycle
        out_state <= nst[prv(0)];
        out_tag   <= tg[prv(0)];
        for (int i = 1; i < P; i++)
            if (fin_r[i]) begin
                out_state <= nst[prv(i*SP)];
                out_tag   <= tg[prv(i*SP)];
            end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k < S; k++) vl[k] <= 1'b0;
            fin_r     <= '0;
            out_valid <= 1'b0;
        end else begin
            for (int k = 0; k < S; k++) begin
                if (k % SP == 0)
                    vl[k] <= acc[k / SP] || (vl[prv(k)] && !fin_r[k / SP]);
                else
                    vl[k] <= vl[prv(k)];
            end
            // the call now in stage q_i-2 reaches the output of stage q_i-1 next cycle (S/P >= 2: no insertion
            // between), and finishes there if K more rounds after this cycle's complete its 80
            for (int i = 0; i < P; i++)
                fin_r[i] <= vl[prv(prv(i*SP))] && (lfsr_adv(lf[prv(prv(i*SP))], 2*K) == LFSR_80);
            out_valid <= fin_any;
        end
    end
endmodule
