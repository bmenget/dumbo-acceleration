// One round of Spongent-pi[160]: round-constant XOR -> 40 x 4-bit S-box -> pLayer.
// Purely combinational. Bit convention: state_in[i] == model bit i, i.e. byte k is
// state[8k+7:8k] (byte 0 in the low bits). Matches the designers' C reference.
module spongent_round (
    input  logic [159:0] state_in,
    input  logic [7:0]   rc_lo,    // XORed into byte 0   (LCounter[r])
    input  logic [7:0]   rc_hi,    // XORed into byte 19  (bit-reversed LCounter[r])
    output logic [159:0] state_out
);
    // Spongent 4-bit S-box
    function automatic logic [3:0] sbox4(input logic [3:0] x);
        case (x)
            4'h0: sbox4 = 4'hE;  4'h1: sbox4 = 4'hD;  4'h2: sbox4 = 4'hB;  4'h3: sbox4 = 4'h0;
            4'h4: sbox4 = 4'h2;  4'h5: sbox4 = 4'h1;  4'h6: sbox4 = 4'h4;  4'h7: sbox4 = 4'hF;
            4'h8: sbox4 = 4'h7;  4'h9: sbox4 = 4'hA;  4'hA: sbox4 = 4'h8;  4'hB: sbox4 = 4'h5;
            4'hC: sbox4 = 4'h9;  4'hD: sbox4 = 4'hC;  4'hE: sbox4 = 4'h3;  default: sbox4 = 4'h6;
        endcase
    endfunction

    logic [159:0] x, sb;

    assign x = state_in ^ {rc_hi, 144'b0, rc_lo};

    genvar n, i;
    generate
        for (n = 0; n < 40; n++) begin : g_sbox
            assign sb[4*n +: 4] = sbox4(x[4*n +: 4]);
        end
        // pLayer: bit i -> (i*40) mod 159, bit 159 fixed. Pure wiring.
        for (i = 0; i < 160; i++) begin : g_player
            localparam int J = (i == 159) ? 159 : ((i * 40) % 159);
            assign state_out[J] = sb[i];
        end
    endgenerate
endmodule
