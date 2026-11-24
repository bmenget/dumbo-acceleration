// Elephant-Dumbo AEAD core with the GMU LWC Hardware API "CryptoCore" interface (CCW = CCSW = 32).
// Behaviour = the designers' C reference (elephant160v2/ref; model/ref_c.py). Encrypt/decrypt only (hash_in is ignored: Dumbo has no hash).
// Drop-in for the CryptoCore of the LWC development package (port names and meanings as in its
// CryptoCore_template.vhd); the wrapper itself is not part of this repo.
//
// Interface conventions (LWC API): 32-bit words, first byte in bits [31:24]; *_valid_bytes and
// bdi_pad_loc are big-endian (bit 3 = first byte). Internally everything is little-endian like the
// model (byte k of a 160-bit block = bits [8k+7:8k]; word j = bits [32j+31:32j]).
//
// Word-serial datapath (one 32-bit word per clock):
//   * S (in spongent_perm_ws), M (mask of the call in flight), H (mask LFSR h = phi1^a(K*)), KS (K*),
//     ACC (tag sum) and NONCE are rotating registers: each step shifts word 0 out and a new word into
//     word 4, so only the incoming word has logic; after 5 steps a register is back in order.
//   * A "pass" is 5 steps. In one pass the finished call is unloaded (y = S ^ M, word by word) and
//     the next call is loaded (S <- X ^ m, M <- m). Per message block: pass A (unload CT call into
//     ACC, load keystream call), pass B (unload keystream -> bdo = bdi ^ y, load CT call). Then
//     80/R cycles of rounds each. 2 * (5 + 80/R) cycles per 20-byte block.
//   * Masks: m = h, phi2(h) = h ^ phi1(h) or phi2^2(h) = h ^ phi1^2(h). phi1 shifts by one byte,
//     so mask byte k needs only h bytes k, k+1, k+2 (bytes 20/21 = phi1 / phi1^2 feedback bytes).
//     H is stepped (h <- phi1(h)) or reloaded (h <- K*) by a 5-step H-only pass that runs while the
//     permutation is busy. The final call uses mask K* by loading H with K* first.
//   * K* = P(K || 0) is computed when a key is loaded and kept, so messages without a new key work.
// Call order: K* (on key load) | AD blocks 2..n (+pad) | per message block: keystream, CT |
// CT pad block if needed | final. The tag is an XOR-sum, so the order is free.
// Default R can be set from the tool when the wrapper instantiates the core without generics
// (the LWC wrapper's VHDL component has none): e.g. synth_design -verilog_define DUMBO_R=4.
`ifndef DUMBO_R
`define DUMBO_R 1
`endif
module CryptoCore #(
    parameter int R = `DUMBO_R                // rounds per clock of the permutation (divides 80)
) (
    input  logic        clk,
    input  logic        rst,
    // key
    input  logic [31:0] key,
    input  logic        key_valid,
    output logic        key_ready,
    input  logic        key_update,
    // data in
    input  logic [31:0] bdi,
    input  logic [3:0]  bdi_pad_loc,
    input  logic [3:0]  bdi_valid_bytes,
    input  logic [2:0]  bdi_size,
    input  logic        bdi_eot,
    input  logic        bdi_eoi,
    input  logic [3:0]  bdi_type,
    input  logic        bdi_valid,
    output logic        bdi_ready,
    input  logic        decrypt_in,
    input  logic        hash_in,
    // data out
    output logic [31:0] bdo,
    output logic [3:0]  bdo_type,
    output logic [3:0]  bdo_valid_bytes,
    output logic        end_of_block,
    output logic        bdo_valid,
    input  logic        bdo_ready,
    // tag verification result
    output logic        msg_auth,
    output logic        msg_auth_valid,
    input  logic        msg_auth_ready
);
    // LWC segment types
    localparam logic [3:0] HDR_AD = 4'b0001, HDR_PT = 4'b0100, HDR_CT = 4'b0101, HDR_TAG = 4'b1000;

    function automatic logic [31:0] bswap(input logic [31:0] v);
        bswap = {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction
    function automatic logic [3:0] rev4(input logic [3:0] v);
        rev4 = {v[0], v[1], v[2], v[3]};
    endfunction
    // phi1 feedback byte from bytes x0, x3, x13: rotl(x0,3) ^ (x3 << 7) ^ (x13 >> 7)
    function automatic logic [7:0] fb(input logic [7:0] x0, input logic [7:0] x3, input logic [7:0] x13);
        fb = {x0[4:0], x0[7:5]} ^ {x3[0], 7'b0} ^ {7'b0, x13[7]};
    endfunction

    // ------------------------------------------------------------------ state
    typedef enum logic [4:0] {
        S_IDLE, S_KEY, S_KUNL, S_HI0, S_HI1, S_HI2, S_AD0, S_AD0D, S_ADP, S_ADD, S_DSTART,
        S_MSGA, S_MSGB, S_BD, S_PADP, S_PD, S_FINP, S_TAGP, S_AUTH
    } st_t;
    typedef enum logic [1:0] { M_ZERO, M_H, M_PHI2, M_PHI22 } msel_t;
    typedef enum logic [1:0] { H_NONE, H_STEP, H_COPY } hop_t;

    // one-hot: on the -1 part this gave +3.6% Fmax and -32 LUT in the GMU wrapper (results log, E1)
    (* fsm_encoding = "one_hot" *) st_t st;
    logic [2:0]   w;                         // word index within a pass (0..4)
    logic         dec_r, in_done, need_pad, eoi_r, pend, auth_r;
    logic [159:0] M, H, KS, ACC;
    logic [95:0]  NONCE;
    hop_t         h_op;
    logic [2:0]   h_w;
    logic [7:0]   t1_r;

    // ------------------------------------------------------------------ permutation
    logic        p_start, p_shift, p_busy, p_done;
    logic [31:0] s_lo, w_in;
    spongent_perm_ws #(.R(R)) u_perm (
        .clk, .rst, .start(p_start), .shift(p_shift), .w_in, .busy(p_busy), .done(p_done), .s_lo);

    // ------------------------------------------------------------------ word datapath
    logic [31:0] bdi_le, key_le, y, raw, in_word, dw, x_word, m_word, acc_in;
    logic [3:0]  vb, pl;
    logic        last_w, go, take, ad_empty;
    msel_t       msel;

    assign bdi_le = bswap(bdi);
    assign key_le = bswap(key);
    assign vb     = rev4(bdi_valid_bytes);
    assign pl     = rev4(bdi_pad_loc);
    assign y      = s_lo ^ M[31:0];                         // gadget output word
    assign last_w = (st == S_TAGP) ? (w == 3'd1) : (w == 3'd4);
    assign go     = !p_busy && (h_op == H_NONE);            // S/H passes wait for both engines

    // message / AD input word: valid bytes kept, pad byte 0x01 at bdi_pad_loc, rest zero.
    // Encrypt CT call: the ciphertext (bdi ^ keystream) is what gets padded.
    assign raw = (st == S_MSGB && !dec_r) ? (bdi_le ^ y) : bdi_le;
    always_comb
        for (int k = 0; k < 4; k++)
            in_word[8*k +: 8] = vb[k] ? raw[8*k +: 8] : {7'b0, pl[k]};
    // AD0, word 3: no AD segment (next input is the message): pad right after the nonce
    assign ad_empty = (st == S_AD0) && (w == 3'd3) && !in_done && bdi_valid && (bdi_type != HDR_AD);
    assign dw = take ? in_word : ((need_pad || ad_empty) ? 32'h0000_0001 : 32'h0);

    // mask word from h bytes 4w..4w+5 (H rotating in step with S); at w = 4 bytes 20, 21 are the
    // phi1 / phi1^2 feedback bytes, computed from the original bytes 0,3,13 / 1,4,14 which sit at
    // positions (b + 4) mod 20 at that point.
    logic [47:0] hwin;
    logic [7:0]  t1, t2;
    assign t1   = fb(H[8*4 +: 8], H[8*7 +: 8], H[8*17 +: 8]);
    assign t2   = fb(H[8*5 +: 8], H[8*8 +: 8], H[8*18 +: 8]);
    assign hwin = (w == 3'd4) ? {t2, t1, H[31:0]} : H[47:0];
    always_comb begin
        unique case (st)
            S_ADP, S_FINP:  msel = M_H;
            S_MSGA:         msel = M_PHI2;
            S_MSGB, S_PADP: msel = M_PHI22;
            default:        msel = M_ZERO;
        endcase
        for (int k = 0; k < 4; k++) begin
            logic [7:0] b0, b1, b2;
            b0 = hwin[8*k +: 8]; b1 = hwin[8*(k+1) +: 8]; b2 = hwin[8*(k+2) +: 8];
            unique case (msel)
                M_H:     m_word[8*k +: 8] = b0;
                M_PHI2:  m_word[8*k +: 8] = b0 ^ b1;
                M_PHI22: m_word[8*k +: 8] = b0 ^ b2;
                default: m_word[8*k +: 8] = 8'h00;
            endcase
        end
    end

    assign acc_in = ACC[31:0] ^ (pend ? y : 32'h0);         // ACC update in unload passes
    always_comb begin
        unique case (st)
            S_KEY:                  x_word = (w < 3'd4) ? key_le : 32'h0;     // K || 0
            S_MSGA:                 x_word = (w < 3'd3) ? NONCE[31:0] : 32'h0; // N || 0
            S_ADP, S_MSGB, S_PADP:  x_word = dw;
            S_FINP:                 x_word = acc_in;                           // final: whole tag sum
            default:                x_word = 32'h0;
        endcase
    end
    assign w_in = x_word ^ m_word;

    // ------------------------------------------------------------------ handshakes
    always_comb begin
        bdi_ready = 1'b0;
        unique case (st)
            S_AD0:  bdi_ready = (w < 3'd3) || (!in_done && bdi_type == HDR_AD);
            S_ADP:  bdi_ready = go && !in_done;
            S_MSGB: bdi_ready = go && !in_done && bdo_ready;
            S_TAGP: bdi_ready = go && dec_r;
            default: ;
        endcase
    end
    assign take      = bdi_ready && bdi_valid;
    assign key_ready = (st == S_KEY) && go && (w < 3'd4);

    logic adv;                                              // the pass advances one word
    always_comb begin
        unique case (st)
            S_KEY:  adv = go && ((w < 3'd4) ? key_valid : 1'b1);
            S_AD0:  adv = (w < 3'd3) ? bdi_valid : (in_done || bdi_valid);
            S_ADP:  adv = go && (in_done || bdi_valid);
            S_MSGB: adv = go && (in_done || (bdi_valid && bdo_ready));
            S_TAGP: adv = go && (dec_r ? bdi_valid : bdo_ready);
            S_KUNL, S_MSGA, S_PADP, S_FINP: adv = go;
            default: adv = 1'b0;
        endcase
    end
    logic s_pass, load_pass;
    assign s_pass    = (st inside {S_KEY, S_KUNL, S_ADP, S_MSGA, S_MSGB, S_PADP, S_FINP, S_TAGP});
    assign load_pass = (st inside {S_KEY, S_ADP, S_MSGA, S_MSGB, S_PADP, S_FINP});
    assign p_shift   = adv && s_pass;
    assign p_start   = adv && load_pass && last_w;

    assign bdo_valid       = (st == S_MSGB) ? (go && !in_done && bdi_valid)
                           : (st == S_TAGP) ? (go && !dec_r) : 1'b0;
    always_comb begin
        logic [31:0] o;
        for (int k = 0; k < 4; k++) o[8*k +: 8] = vb[k] ? (bdi_le[8*k +: 8] ^ y[8*k +: 8]) : 8'h00;
        if (st == S_TAGP) begin
            bdo = bswap(y); bdo_valid_bytes = 4'hF; bdo_type = HDR_TAG; end_of_block = (w == 3'd1);
        end else begin
            bdo = bswap(o); bdo_valid_bytes = bdi_valid_bytes; end_of_block = bdi_eot;
            bdo_type = dec_r ? HDR_PT : HDR_CT;
        end
    end
    assign msg_auth_valid = (st == S_AUTH);
    assign msg_auth       = auth_r;

    // ------------------------------------------------------------------ registers
    // rotating registers (no reset needed: always fully written before use)
    always_ff @(posedge clk) begin
        if (p_shift) M <= {m_word, M[159:32]};
        // ACC: AD0 fills it with the first AD block (N || A ...); unload passes add y
        if (adv && st == S_AD0)                                  ACC <= {(w < 3'd3) ? bdi_le : dw, ACC[159:32]};
        else if (adv && st inside {S_ADP, S_MSGA, S_PADP, S_FINP}) ACC <= {acc_in, ACC[159:32]};
        // NONCE: stored from the NPUB words, read (rotated) by every keystream load
        if (adv && w < 3'd3 && st == S_AD0)      NONCE <= {bdi_le, NONCE[95:32]};
        else if (adv && w < 3'd3 && st == S_MSGA) NONCE <= {NONCE[31:0], NONCE[95:32]};
        // KS: K* from the setup call's output
        if (adv && st == S_KUNL)     KS <= {y, KS[159:32]};
        else if (h_op == H_COPY)     KS <= {KS[31:0], KS[159:32]};
        // H: rotates (unchanged) while a pass reads masks; H-only passes step / reload it
        if (adv && st inside {S_ADP, S_MSGA, S_MSGB, S_PADP, S_FINP}) H <= {H[31:0], H[159:32]};
        else if (h_op == H_COPY) H <= {KS[31:0], H[159:32]};
        else if (h_op == H_STEP) H <= {(h_w == 3'd4) ? {t1_r, H[31:8]} : H[39:8], H[159:32]};
        if (h_op == H_STEP && h_w == 3'd0) t1_r <= fb(H[7:0], H[31:24], H[111:104]);
    end

    // control
    always_ff @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; w <= '0; h_op <= H_NONE; h_w <= '0;
            dec_r <= 1'b0; in_done <= 1'b0; need_pad <= 1'b0; eoi_r <= 1'b0; pend <= 1'b0;
            auth_r <= 1'b0;
        end else begin
            // H-only pass engine
            if (h_op != H_NONE) begin
                h_w <= (h_w == 3'd4) ? 3'd0 : h_w + 3'd1;
                if (h_w == 3'd4) h_op <= H_NONE;
            end

            if (adv) w <= last_w ? 3'd0 : w + 3'd1;
            if (p_start) pend <= 1'b1;

            // input-stream bookkeeping for data words (AD0 words 3,4 / ADP / MSGB / PADP)
            if (adv && (st inside {S_ADP, S_MSGB, S_PADP} || (st == S_AD0 && w >= 3'd3))) begin
                if (take) begin
                    if (bdi_eot) begin
                        in_done <= 1'b1; need_pad <= (vb == 4'hF);
                        if (bdi_eoi) eoi_r <= 1'b1;
                    end
                end else if (ad_empty) begin
                    in_done <= 1'b1; need_pad <= 1'b0;          // pad byte placed in this word
                end else if (need_pad) begin
                    need_pad <= 1'b0;
                end
            end

            unique case (st)
            S_IDLE:
                if (key_valid) st <= S_KEY;                      // new key: compute K*
                else if (bdi_valid && !hash_in) st <= S_HI0;     // message (NPUB first)

            S_KEY:  if (adv && last_w) st <= S_KUNL;
            S_KUNL: if (adv && last_w) begin pend <= 1'b0; st <= S_IDLE; end

            // message start: h <- K*, then h <- phi1(h)  (AD stream starts at a = 1)
            S_HI0: if (h_op == H_NONE) begin h_op <= H_COPY; st <= S_HI1; end
            S_HI1: if (h_op == H_NONE) begin h_op <= H_STEP; st <= S_HI2; end
            S_HI2: if (h_op == H_NONE) begin
                in_done <= 1'b0; need_pad <= 1'b0; eoi_r <= 1'b0; pend <= 1'b0;
                st <= S_AD0;
            end

            // first AD block = N || A[0..7]: straight into ACC (no permutation call)
            S_AD0: begin
                if (adv && w == 3'd0) dec_r <= decrypt_in;
                if (adv && w == 3'd2 && bdi_eoi) begin           // no AD and no message
                    in_done <= 1'b1; need_pad <= 1'b1; eoi_r <= 1'b1;
                end
                if (adv && last_w) st <= S_AD0D;
            end
            S_AD0D:
                if (!in_done || need_pad) st <= S_ADP;           // more AD blocks (h = phi1(K*))
                else begin h_op <= H_COPY; st <= S_DSTART; end   // AD done: h <- K* for the message

            S_ADP: if (adv && last_w) st <= S_ADD;
            S_ADD:
                if (!in_done || need_pad) begin h_op <= H_STEP; st <= S_ADP; end
                else begin h_op <= H_COPY; st <= S_DSTART; end

            S_DSTART:
                if (eoi_r) begin                                 // empty message: one CT pad block
                    in_done <= 1'b1; need_pad <= 1'b1; st <= S_PADP;
                end else begin
                    in_done <= 1'b0; need_pad <= 1'b0; st <= S_MSGA;
                end

            S_MSGA: if (adv && last_w) st <= S_MSGB;
            S_MSGB: if (adv && last_w) st <= S_BD;
            S_BD:
                if (!in_done)     begin h_op <= H_STEP; st <= S_MSGA; end
                else if (need_pad) begin h_op <= H_STEP; st <= S_PADP; end   // pad spills over
                else              begin h_op <= H_COPY; st <= S_FINP; end

            S_PADP: if (adv && last_w) st <= S_PD;
            S_PD:   begin h_op <= H_COPY; st <= S_FINP; end

            S_FINP: if (adv && last_w) st <= S_TAGP;

            // tag: encrypt -> two bdo words; decrypt -> compare with the two received tag words
            S_TAGP: begin
                if (take) auth_r <= ((w == 3'd0) ? 1'b1 : auth_r) && (y == bdi_le);
                if (adv && last_w) begin
                    pend <= 1'b0;
                    st <= dec_r ? S_AUTH : S_IDLE;
                end
            end
            S_AUTH: if (msg_auth_ready) st <= S_IDLE;

            default: st <= S_IDLE;
            endcase
        end
    end

    // unused inputs (kept for interface compatibility)
    logic unused;
    assign unused = ^{key_update, bdi_size};
endmodule
