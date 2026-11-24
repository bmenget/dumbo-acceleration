// ECE545 core_v2_logan_pipe16x2d16_optIL: as core_v2_logan_pipe20x2d16_optIL's copy of rtl/logan/CryptoCorePipe.sv
// (Logan's, commit 74a0ef4; KB / TI data selects off the handshake, marked "optIL"), plus parameter P (ring
// entry/exit points, passed to this directory's spongent_perm_pipe.sv; see OPT_RING.md). Otherwise unchanged.
//
// Elephant-Dumbo AEAD core on the pipelined permutation ring (spongent_perm_pipe), with the GMU LWC Hardware API
// "CryptoCore" ports (CCW = CCSW = 32), same conventions as rtl/CryptoCore.sv (see its header).
// Behaviour = the designers' C reference (elephant160v2/ref; model/ref_c.py). Encrypt/decrypt only (no hash).
//
// Structure (plan in docs/architecture_notes.md, "Plan for the AEAD around the ring"):
//   * Ring of S stages x K rounds: up to S permutation calls in flight, results in call order, latency 80/K+1.
//   * Keystream calls KS_i = P(N||0 ^ phi2(h_i)) need no data, so they are issued ahead as soon as the nonce
//     is known (speculatively: the message length is not known in advance). Their results, already unmasked
//     (y = P ^ phi2(h_i), h_i regenerated at the exit by HO), go into a D-entry FIFO; message words are then
//     encrypted/decrypted as they arrive. Speculative results past the message end are discarded (flushed
//     after the final call, when the ring is empty).
//   * Tag calls (AD blocks 2.., CT blocks): the block is assembled word by word in TS, then TI = TS ^ m waits
//     for a ring slot. The tag is an XOR-sum, so ACC gets m when the call is inserted and the raw ring output
//     when it leaves; no mask is stored per call. The first AD block (N || A ..) goes straight into ACC.
//   * Ring input: a pending TI (tag, key or final call) has priority, else a keystream call if the FIFO has room.
//   * K* = P(K || 0) on key load; final T = P(ACC ^ K*) ^ K*, first 8 bytes.
// call_used pulses once per permutation call whose result is used (key, AD, CT, final calls when inserted;
// keystream calls when their result is consumed) -> comparable with the C reference's call count. ring_ins
// pulses on every ring insertion (includes discarded speculative keystream calls).
module CryptoCorePipe #(
    parameter int S = 16,                     // ring stages (calls in flight)
    parameter int K = 1,                      // rounds per stage; S*K must divide 80
    parameter int D = 16,                     // keystream FIFO entries (power of 2), = max keystream lookahead
    parameter int P = 1                       // ECE545: ring entry/exit points (80/K a multiple of S/P)
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
    if (D < 2 || (D & (D - 1)) != 0) begin : g_bad_d
        $error("CryptoCorePipe: D must be a power of 2 >= 2");
    end
    localparam int DW = $clog2(D);

    localparam logic [3:0] HDR_AD = 4'b0001, HDR_PT = 4'b0100, HDR_CT = 4'b0101, HDR_TAG = 4'b1000;
    localparam logic [1:0] T_KS = 2'd0, T_TAG = 2'd1, T_KEY = 2'd2, T_FIN = 2'd3;   // ring call tags

    function automatic logic [31:0] bswap(input logic [31:0] v);
        bswap = {v[7:0], v[15:8], v[23:16], v[31:24]};
    endfunction
    function automatic logic [3:0] rev4(input logic [3:0] v);
        rev4 = {v[0], v[1], v[2], v[3]};
    endfunction
    // phi1: shift down one byte; new byte 19 = rotl(x0,3) ^ (x3 << 7) ^ (x13 >> 7)
    function automatic logic [159:0] phi1(input logic [159:0] h);
        logic [7:0] x0, x3, x13;
        x0 = h[7:0]; x3 = h[31:24]; x13 = h[111:104];
        phi1 = {{x0[4:0], x0[7:5]} ^ {x3[0], 7'b0} ^ {7'b0, x13[7]}, h[159:8]};
    endfunction
    function automatic logic [159:0] phi2(input logic [159:0] h);     // phi1 ^ id
        phi2 = h ^ phi1(h);
    endfunction
    function automatic logic [159:0] phi22(input logic [159:0] h);    // phi2^2 = phi1^2 ^ id (GF(2))
        phi22 = h ^ phi1(phi1(h));
    endfunction

    // ------------------------------------------------------------------ state
    typedef enum logic [3:0] {
        S_IDLE, S_KEY, S_KWAIT, S_MSTART, S_AD0, S_AD, S_MSG0, S_MSG, S_FIN, S_FWAIT, S_TAG, S_AUTH
    } st_t;
    (* fsm_encoding = "one_hot" *) st_t st;
    logic [2:0]   tw;                         // word index within the block being assembled / tag word
    logic         dec_r, in_done, need_pad, eoi_r, auth_r, key_ok, blk_data, ks_run;
    logic [159:0] KSTAR, HK, HO, HC, ACC, TS, TI, MI;
    logic [95:0]  NONCE;
    logic [63:0]  TAGR;
    logic         ti_v, ti_dir;               // TI pending; ti_dir: first AD block (into ACC, no call)
    logic [1:0]   ti_type;
    logic [DW:0]  wp, rp, ks_out;             // FIFO pointers; ks_out = keystream calls issued, not consumed
    // tag calls inserted but not yet returned: up to S + 1, because a slot is refilled in the cycle its call
    // finishes, one cycle before that call's result appears on the registered ring output
    logic [$clog2(S+2)-1:0] tag_out;

    // ------------------------------------------------------------------ ring
    logic         r_v, r_rdy, o_v;
    logic [159:0] r_in, o_st, ksi;
    logic [1:0]   r_tag, o_tag;
    logic         ti_ring, ks_req, r_acc, ti_take, ks_take;
    spongent_perm_pipe #(.S(S), .K(K), .TW(2), .P(P)) u_ring (
        .clk, .rst, .in_valid(r_v), .in_ready(r_rdy), .in_state(r_in), .in_tag(r_tag),
        .out_valid(o_v), .out_state(o_st), .out_tag(o_tag));

    assign ksi     = {64'b0, NONCE} ^ phi2(HK);                  // keystream call input N || 0 ^ phi2(h)
    assign ti_ring = ti_v && !ti_dir;
    assign ks_req  = ks_run && (ks_out != (DW+1)'(D));
    assign r_v     = ti_ring || ks_req;
    assign r_in    = ti_ring ? TI : ksi;
    assign r_tag   = ti_ring ? ti_type : T_KS;
    assign r_acc   = r_v && r_rdy;
    assign ti_take = r_acc && ti_ring;
    assign ks_take = r_acc && !ti_ring;

    logic ex_ks, ex_tag, ex_key, ex_fin;
    assign ex_ks  = o_v && (o_tag == T_KS);
    assign ex_tag = o_v && (o_tag == T_TAG);
    assign ex_key = o_v && (o_tag == T_KEY);
    assign ex_fin = o_v && (o_tag == T_FIN);

    // keystream FIFO (unmasked keystream blocks, block order)
    logic [159:0] ksf [0:D-1];
    logic [159:0] ksf_head;
    logic         ks_avail;
    always_ff @(posedge clk)
        if (ex_ks) ksf[wp[DW-1:0]] <= o_st ^ phi2(HO);
    assign ksf_head = ksf[rp[DW-1:0]];
    assign ks_avail = (wp != rp);

    // KB: the keystream block for the message block being processed, prefetched from the FIFO head so the data
    // path reads a register (KB[31:0], rotated one word per data word), not the LUT-RAM and a word mux. The next
    // block is loaded in the cycle the current one is consumed (no bubble).
    logic [159:0] KB;
    logic         kb_v, kb_cons, kb_load;

    // ------------------------------------------------------------------ word datapath
    logic [31:0] bdi_le, key_le, y_word, raw, in_word, dw, ts_word, tag_word;
    logic [3:0]  vb, pl;
    logic        take, ad_empty, lastok, blk_end, adv, comp, ks_pop;
    logic [159:0] ts_full, cmask;

    assign bdi_le   = bswap(bdi);
    assign key_le   = bswap(key);
    assign vb       = rev4(bdi_valid_bytes);
    assign pl       = rev4(bdi_pad_loc);
    assign y_word   = KB[31:0];
    assign raw      = (st == S_MSG && !dec_r) ? (bdi_le ^ y_word) : bdi_le;      // encrypt: CT call pads C
    always_comb
        for (int k = 0; k < 4; k++)
            in_word[8*k +: 8] = vb[k] ? raw[8*k +: 8] : {7'b0, pl[k]};
    // first block, word 3: no AD segment (next input is the message): pad right after the nonce
    assign ad_empty = (st == S_AD0) && (tw == 3'd3) && !in_done && bdi_valid && (bdi_type != HDR_AD);
    // a data word is written only when it is taken, so select on in_done (registered) instead of take: keeps the
    // handshake signals (bdi_valid, bdo_ready, FIFO state) out of the data path
    assign dw       = ad_empty ? 32'h0000_0001 : (!in_done ? in_word : (need_pad ? 32'h0000_0001 : 32'h0));
    always_comb
        unique case (st)
            S_KEY:   ts_word = (tw < 3'd4) ? key_le : 32'h0;                     // K || 0
            S_AD0:   ts_word = (tw < 3'd3) ? bdi_le : dw;                        // N || A ..
            default: ts_word = dw;
        endcase
    assign ts_full  = {ts_word, TS[159:32]};
    assign lastok   = (tw != 3'd4) || !ti_v;                     // the last word needs TI free
    assign blk_end  = (tw == 3'd0) && in_done && !need_pad;      // AD / message input finished
    assign tag_word = tw[0] ? TAGR[63:32] : TAGR[31:0];

    // ------------------------------------------------------------------ handshakes
    always_comb begin
        bdi_ready = 1'b0;
        adv       = 1'b0;
        unique case (st)
            S_KEY:  adv = lastok && ((tw < 3'd4) ? key_valid : 1'b1);
            S_AD0:  begin
                bdi_ready = (tw < 3'd3) || (!in_done && bdi_type == HDR_AD && lastok);
                adv       = (tw < 3'd3) ? bdi_valid : ((in_done || bdi_valid) && lastok);
            end
            S_AD:   begin
                bdi_ready = !blk_end && !in_done && lastok;
                adv       = !blk_end && (in_done || bdi_valid) && lastok;
            end
            S_MSG:  begin
                bdi_ready = !blk_end && !in_done && kb_v && bdo_ready && lastok;
                adv       = !blk_end && lastok && (in_done || (bdi_valid && kb_v && bdo_ready));
            end
            S_TAG:  begin
                bdi_ready = dec_r;
                adv       = dec_r ? bdi_valid : bdo_ready;
            end
            default: ;
        endcase
    end
    assign take      = bdi_ready && bdi_valid;
    assign key_ready = (st == S_KEY) && (tw < 3'd4) && lastok;
    assign comp      = adv && (tw == 3'd4) && (st inside {S_KEY, S_AD0, S_AD, S_MSG});
    assign ks_pop    = comp && (st == S_MSG) && (blk_data || take);    // keystream block consumed
    assign kb_cons   = ks_pop;
    assign kb_load   = (!kb_v || kb_cons) && ks_avail;

    always_comb begin
        unique case (st)
            S_MSG:   cmask = phi22(HC);                                         // CT stream
            S_AD:    cmask = HC;                                                // AD stream
            default: cmask = '0;
        endcase
    end

    assign bdo_valid = (st == S_MSG) ? (!blk_end && !in_done && bdi_valid && kb_v && lastok)
                     : (st == S_TAG) ? !dec_r : 1'b0;
    always_comb begin
        logic [31:0] o;
        for (int k = 0; k < 4; k++) o[8*k +: 8] = vb[k] ? (bdi_le[8*k +: 8] ^ y_word[8*k +: 8]) : 8'h00;
        if (st == S_TAG) begin
            bdo = bswap(tag_word); bdo_valid_bytes = 4'hF; bdo_type = HDR_TAG; end_of_block = (tw == 3'd1);
        end else begin
            bdo = bswap(o); bdo_valid_bytes = bdi_valid_bytes; end_of_block = bdi_eot;
            bdo_type = dec_r ? HDR_PT : HDR_CT;
        end
    end
    assign msg_auth_valid = (st == S_AUTH);
    assign msg_auth       = auth_r;

    logic call_used, ring_ins;                                   // observation (testbench call counts)
    assign call_used = ti_take || ks_pop;
    assign ring_ins  = r_acc;

    // ------------------------------------------------------------------ datapath registers
    logic acc_ins;
    assign acc_ins = (ti_take && ti_type == T_TAG) || (ti_v && ti_dir);
    always_ff @(posedge clk) begin
        if (adv && (st inside {S_KEY, S_AD0, S_AD, S_MSG})) TS <= ts_full;
        if (adv && st == S_AD0 && tw < 3'd3) NONCE <= {bdi_le, NONCE[95:32]};
        if (ex_key) KSTAR <= o_st;
        // optIL (ECE545 option L applied to this core, see OPT_IL.md): the data selects of KB and TI come from
        // registers; the handshake-derived kb_load / take / comp only drive the enables. KB loads when it is
        // empty or its last word is in use (tw == 4); in the one case that differs from before (the last word
        // is taken while no keystream block is ready) kb_v drops to 0 that cycle and KB is not read until the
        // next kb_load overwrites it.
        if (kb_load || (take && st == S_MSG))
            KB <= (!kb_v || tw == 3'd4) ? ksf_head : {KB[31:0], KB[159:32]};

        // TI / MI: the call waiting for a ring slot, and what goes into ACC when it is inserted
        // (comp never happens in S_FIN, so selecting on st is the same as selecting on comp)
        if (comp || (st == S_FIN && !ti_v && tag_out == '0))
            TI <= (st == S_FIN) ? (ACC ^ KSTAR) : (ts_full ^ cmask);
        if (comp)
            MI <= (st == S_AD0) ? ts_full : cmask;

        // masks: h for the keystream issue side (HK), keystream exit side (HO), tag calls (HC)
        if (st == S_MSTART) begin
            HK <= KSTAR; HO <= KSTAR; HC <= phi1(KSTAR);        // AD stream starts at a = 1
        end else begin
            if (ks_take) HK <= phi1(HK);
            if (ex_ks)   HO <= phi1(HO);
            if (st == S_MSG0) HC <= KSTAR;                       // CT stream starts at a = 0
            else if (comp && (st inside {S_AD, S_MSG})) HC <= phi1(HC);
        end

        if (st == S_MSTART) ACC <= '0;
        else ACC <= ACC ^ (acc_ins ? MI : '0) ^ (ex_tag ? o_st : '0);

        if (ex_fin) TAGR <= o_st[63:0] ^ KSTAR[63:0];
    end

    // ------------------------------------------------------------------ control
    always_ff @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; tw <= '0; key_ok <= 1'b0; ti_v <= 1'b0; ti_dir <= 1'b0; ti_type <= T_TAG;
            dec_r <= 1'b0; in_done <= 1'b0; need_pad <= 1'b0; eoi_r <= 1'b0; auth_r <= 1'b0;
            blk_data <= 1'b0; ks_run <= 1'b0; wp <= '0; rp <= '0; ks_out <= '0; tag_out <= '0; kb_v <= 1'b0;
        end else begin
            if (adv) tw <= (tw == 3'd4 || (st == S_TAG && tw == 3'd1)) ? 3'd0 : tw + 3'd1;

            // TI handshake
            if (ti_take || (ti_v && ti_dir)) ti_v <= 1'b0;
            if (comp) begin
                ti_v    <= 1'b1;
                ti_dir  <= (st == S_AD0);
                ti_type <= (st == S_KEY) ? T_KEY : T_TAG;
            end

            // counters
            tag_out <= tag_out + ((ti_take && ti_type == T_TAG) ? 1'b1 : 1'b0) - (ex_tag ? 1'b1 : 1'b0);
            ks_out  <= ks_out + (ks_take ? 1'b1 : 1'b0) - (ks_pop ? 1'b1 : 1'b0);
            if (ex_ks)  wp <= wp + 1'b1;
            if (kb_load) rp <= rp + 1'b1;
            if (kb_load) kb_v <= 1'b1;
            else if (kb_cons) kb_v <= 1'b0;
            if (st == S_MSG) begin
                if (comp)      blk_data <= 1'b0;
                else if (take) blk_data <= 1'b1;
            end

            // input-stream bookkeeping for data words (first block words 3,4 / AD / message)
            if (adv && (st inside {S_AD, S_MSG} || (st == S_AD0 && tw >= 3'd3))) begin
                if (take) begin
                    if (bdi_eot) begin
                        in_done <= 1'b1; need_pad <= (vb == 4'hF);
                        if (bdi_eoi) begin eoi_r <= 1'b1; ks_run <= 1'b0; end   // nothing follows
                        if (st == S_MSG) ks_run <= 1'b0;                        // message complete
                    end
                end else if (ad_empty) begin
                    in_done <= 1'b1; need_pad <= 1'b0;          // pad byte placed in this word
                end else if (need_pad) begin
                    need_pad <= 1'b0;
                end
            end

            unique case (st)
            S_IDLE:
                if (key_valid) begin tw <= '0; st <= S_KEY; end            // new key: compute K*
                else if (bdi_valid && !hash_in && key_ok) st <= S_MSTART;  // message (NPUB first)

            S_KEY:   if (comp) st <= S_KWAIT;
            S_KWAIT: if (ex_key) begin key_ok <= 1'b1; st <= S_IDLE; end

            S_MSTART: begin
                dec_r <= decrypt_in; in_done <= 1'b0; need_pad <= 1'b0; eoi_r <= 1'b0;
                blk_data <= 1'b0; tw <= '0; st <= S_AD0;
            end

            // first AD block = N || A[0..7] (into ACC, no call); keystream calls start after the nonce
            S_AD0: begin
                if (adv && tw == 3'd2) begin
                    if (bdi_eoi) begin in_done <= 1'b1; need_pad <= 1'b1; eoi_r <= 1'b1; end  // no AD, no message
                    else ks_run <= 1'b1;
                end
                if (comp) st <= S_AD;
            end
            S_AD:  if (blk_end) st <= S_MSG0;                    // AD finished (incl. a spilled pad block)

            S_MSG0: begin
                if (eoi_r) begin                                 // empty message: one CT pad block
                    in_done <= 1'b1; need_pad <= 1'b1; ks_run <= 1'b0;
                end else begin
                    in_done <= 1'b0; need_pad <= 1'b0;
                end
                st <= S_MSG;
            end
            S_MSG: if (blk_end) st <= S_FIN;

            // final call once every tag call is back (ACC complete)
            S_FIN: if (!ti_v && tag_out == '0) begin
                ti_v <= 1'b1; ti_dir <= 1'b0; ti_type <= T_FIN; ks_run <= 1'b0; st <= S_FWAIT;
            end
            S_FWAIT: if (ex_fin) begin
                // the ring is empty now (calls leave in order): drop speculative keystream blocks
                wp <= '0; rp <= '0; ks_out <= '0; kb_v <= 1'b0; tw <= '0; st <= S_TAG;
            end

            // tag: encrypt -> two bdo words; decrypt -> compare with the two received tag words
            S_TAG: begin
                if (take) auth_r <= ((tw == 3'd0) ? 1'b1 : auth_r) && (tag_word == bdi_le);
                if (adv && tw == 3'd1) st <= dec_r ? S_AUTH : S_IDLE;
            end
            S_AUTH: if (msg_auth_ready) st <= S_IDLE;

            default: st <= S_IDLE;
            endcase
        end
    end

    logic unused;
    assign unused = ^{key_update, bdi_size};
endmodule
