// System builds only: module "CryptoCore" (the name the GMU LWC wrapper instantiates, without generics) as a thin
// wrapper around CryptoCorePipe. Ring and FIFO sizes from defines, e.g.
//   SYNTH_OPTS="-verilog_define DUMBO_S=16 -verilog_define DUMBO_K=1 -verilog_define DUMBO_D=16"
// Used by lwc/system_filelist_pipe.txt instead of rtl/CryptoCore.sv (the two cannot be in one build).
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
    CryptoCorePipe #(.S(`DUMBO_S), .K(`DUMBO_K), .D(`DUMBO_D)) u_core (.*);
endmodule
