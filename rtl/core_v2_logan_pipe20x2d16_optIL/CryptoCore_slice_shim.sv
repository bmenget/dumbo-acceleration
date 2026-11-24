// core_v2_logan_pipe20x2d16_optIL: as core_v2_logan_pipe20x2d16_optI (register slices on bdi and bdo), plus a
// slice on the key channel, around this directory's modified CryptoCorePipe.sv (see OPT_IL.md).
//
// (optI header follows)
// core_v2_logan_pipe20x2d16_optI: Logan's CryptoCorePipe (rtl/logan/, unmodified) behind register slices on
// bdi and bdo, our option I (see rtl/core_v2_r4_optBCDEFGHI/OPT_BCDEFGHI.md and OPT_I.md in this directory).
//
// Module "CryptoCore" is what the LWC wrapper instantiates (no generics); ring and FIFO sizes come from the
// defines in this core's defines.txt, as in rtl/logan/CryptoCore_pipe_shim.sv, which this file replaces.
//
// Each slice is a 2-entry skid buffer: the side facing the wrapper sees a flip-flop ready (bdi_ready) or a
// flip-flop valid (bdo_valid); the core sees a registered word with all its side signals. One cycle of latency
// each way, one word per cycle in steady state. The key channel is not sliced (as in our option I).
`ifndef DUMBO_S
`define DUMBO_S 16
`endif
`ifndef DUMBO_K
`define DUMBO_K 1
`endif
`ifndef DUMBO_D
`define DUMBO_D 16
`endif
module CryptoCore (
    input  logic        clk, rst,
    input  logic [31:0] key,
    input  logic        key_valid,
    output logic        key_ready,
    input  logic        key_update,
    input  logic [31:0] bdi,
    input  logic [3:0]  bdi_pad_loc, bdi_valid_bytes,
    input  logic [2:0]  bdi_size,
    input  logic        bdi_eot, bdi_eoi,
    input  logic [3:0]  bdi_type,
    input  logic        bdi_valid,
    output logic        bdi_ready,
    input  logic        decrypt_in, hash_in,
    output logic [31:0] bdo,
    output logic [3:0]  bdo_type, bdo_valid_bytes,
    output logic        end_of_block, bdo_valid,
    input  logic        bdo_ready,
    output logic        msg_auth, msg_auth_valid,
    input  logic        msg_auth_ready
);
    // ---------------------------------------------------------------- input slice (wrapper -> core)
    localparam int IW = 32 + 4 + 4 + 3 + 1 + 1 + 4 + 1 + 1;
    logic [IW-1:0] in_w, ih, is_w;
    logic          ih_v, is_v;
    logic          c_bdi_ready;                       // the core's ready for the slice head

    assign in_w      = {bdi, bdi_pad_loc, bdi_valid_bytes, bdi_size, bdi_eot, bdi_eoi, bdi_type, decrypt_in, hash_in};
    assign bdi_ready = !is_v;                         // a flip-flop: room while the skid entry is empty

    always_ff @(posedge clk) begin
        if (!ih_v || c_bdi_ready) begin               // the head moves on (or is empty)
            if (is_v) begin
                ih <= is_w; ih_v <= 1'b1; is_v <= 1'b0;
            end else if (bdi_valid) begin
                ih <= in_w; ih_v <= 1'b1;
            end else begin
                ih_v <= 1'b0;
            end
        end else if (bdi_valid && !is_v) begin        // head stalled: park the incoming word
            is_w <= in_w; is_v <= 1'b1;
        end
        if (rst) begin ih_v <= 1'b0; is_v <= 1'b0; end
    end

    logic [31:0] c_bdi;
    logic [3:0]  c_pad_loc, c_vb, c_type;
    logic [2:0]  c_size;
    logic        c_eot, c_eoi, c_dec, c_hash;
    assign {c_bdi, c_pad_loc, c_vb, c_size, c_eot, c_eoi, c_type, c_dec, c_hash} = ih;

    // ---------------------------------------------------------------- key slice (wrapper -> core), optIL
    // His core reads key_valid only as a trigger in S_IDLE (the word stays at the head until S_KEY takes it)
    // and in S_KEY's adv; both slices add one cycle, so the key keeps its lead over the message.
    logic [32:0] kin_w, kh, ks_w;                     // {key, key_update}
    logic        kh_v, ks_v, c_key_ready;
    assign kin_w     = {key, key_update};
    assign key_ready = !ks_v;

    always_ff @(posedge clk) begin
        if (!kh_v || c_key_ready) begin
            if (ks_v) begin
                kh <= ks_w; kh_v <= 1'b1; ks_v <= 1'b0;
            end else if (key_valid) begin
                kh <= kin_w; kh_v <= 1'b1;
            end else begin
                kh_v <= 1'b0;
            end
        end else if (key_valid && !ks_v) begin
            ks_w <= kin_w; ks_v <= 1'b1;
        end
        if (rst) begin kh_v <= 1'b0; ks_v <= 1'b0; end
    end

    // ---------------------------------------------------------------- output slice (core -> wrapper)
    localparam int OW = 32 + 4 + 4 + 1;
    logic [OW-1:0] out_w, oh, os_w;
    logic          oh_v, os_v;
    logic [31:0]   c_bdo;
    logic [3:0]    c_bdo_type, c_bdo_vb;
    logic          c_eob, c_bdo_valid;

    assign out_w = {c_bdo, c_bdo_type, c_bdo_vb, c_eob};
    assign {bdo, bdo_type, bdo_valid_bytes, end_of_block} = oh;
    assign bdo_valid = oh_v;                          // a flip-flop

    always_ff @(posedge clk) begin
        if (!oh_v || bdo_ready) begin
            if (os_v) begin
                oh <= os_w; oh_v <= 1'b1; os_v <= 1'b0;
            end else if (c_bdo_valid) begin
                oh <= out_w; oh_v <= 1'b1;
            end else begin
                oh_v <= 1'b0;
            end
        end else if (c_bdo_valid && !os_v) begin
            os_w <= out_w; os_v <= 1'b1;
        end
        if (rst) begin oh_v <= 1'b0; os_v <= 1'b0; end
    end

    // ---------------------------------------------------------------- Logan's core (this directory's copy)
    CryptoCorePipe #(.S(`DUMBO_S), .K(`DUMBO_K), .D(`DUMBO_D)) u_core (
        .clk, .rst,
        .key(kh[32:1]), .key_valid(kh_v), .key_ready(c_key_ready), .key_update(kh[0]),
        .bdi(c_bdi), .bdi_pad_loc(c_pad_loc), .bdi_valid_bytes(c_vb), .bdi_size(c_size),
        .bdi_eot(c_eot), .bdi_eoi(c_eoi), .bdi_type(c_type),
        .bdi_valid(ih_v), .bdi_ready(c_bdi_ready),
        .decrypt_in(c_dec), .hash_in(c_hash),
        .bdo(c_bdo), .bdo_type(c_bdo_type), .bdo_valid_bytes(c_bdo_vb), .end_of_block(c_eob),
        .bdo_valid(c_bdo_valid), .bdo_ready(!os_v),   // registered "output has room"
        .msg_auth, .msg_auth_valid, .msg_auth_ready
    );
endmodule
