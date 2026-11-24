// Spongent-pi[160] permutation with a 32-bit word-shift port (for word-serial datapaths).
// R rounds per clock (R must divide 80), 80/R clocks per call.
//
//   shift (while !busy): S <= {w_in, S[159:32]}   (word 0 = S[31:0] leaves, w_in enters as word 4;
//                        after 5 shifts the words entered in order sit at positions 0..4)
//   start (while !busy): rounds run on the next 80/R clocks; may coincide with the last shift.
//   done : one-cycle pulse when the rounds have finished (busy falls on the same edge).
//   s_lo : S[31:0], the word that the next shift removes.
// Bit convention as spongent_round: S[i] == model bit i (byte 0 = S[7:0]).
module spongent_perm_ws #(
    parameter int R = 1
) (
    input  logic        clk,
    input  logic        rst,          // synchronous, active high (LWC convention)
    input  logic        start,
    input  logic        shift,
    input  logic [31:0] w_in,
    output logic        busy,
    output logic        done,
    output logic [31:0] s_lo
);
    localparam int NCYC = 80 / R;
    if (80 % R != 0) begin : g_bad_r
        $error("R must divide 80");
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

    logic [159:0] st;
    logic [6:0]   lfsr;
    logic [$clog2(NCYC+1)-1:0] cnt;

    logic [159:0] chain [0:R];
    assign chain[0] = st;
    genvar j;
    generate
        for (j = 0; j < R; j++) begin : g_round
            spongent_round u_round (
                .state_in (chain[j]),
                .rc_lo    ({1'b0, lfsr_adv(lfsr, j)}),
                .rc_hi    (bitrev8({1'b0, lfsr_adv(lfsr, j)})),
                .state_out(chain[j+1])
            );
        end
    endgenerate

    assign s_lo = st[31:0];

    // state register: no reset needed (always fully loaded by 5 shifts before use)
    always_ff @(posedge clk) begin
        if (busy)       st <= chain[R];
        else if (shift) st <= {w_in, st[159:32]};
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; done <= 1'b0; cnt <= '0; lfsr <= 7'h75;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    busy <= 1'b1; lfsr <= 7'h75; cnt <= '0;
                end
            end else begin
                lfsr <= lfsr_adv(lfsr, R);
                cnt  <= cnt + 1'b1;
                if (cnt == NCYC - 1) begin
                    busy <= 1'b0; done <= 1'b1;
                end
            end
        end
    end
endmodule
