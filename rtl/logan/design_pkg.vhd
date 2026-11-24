-- Design_pkg for Logan's SystemVerilog cores (rtl/logan/*.sv) under our wrapper (rtl/lwc/).
-- Ours, not from Logan's repo: his lwc/design_pkg.vhd targets the newer GMUCERG/LWC wrapper (9232d6d),
-- which derives CCWdiv8 itself; our older wrapper (GMU Elephant repo, src_rtl/v1/LWC) reads it from here.
-- These are the only constants rtl/lwc/*.vhd and tb/LWC_TB.vhd use from Design_pkg.

library IEEE;
use IEEE.STD_LOGIC_1164.all;

package Design_pkg is
    constant TAG_SIZE        : integer := 64;     -- Dumbo tag: 8 bytes
    constant HASH_VALUE_SIZE : integer := 128;    -- unused (Dumbo has no hash); same value as core_v2
    constant CCSW            : integer := 32;     -- CryptoCore key width
    constant CCW             : integer := 32;     -- CryptoCore data width
    constant CCWdiv8         : integer := CCW / 8;
end Design_pkg;
