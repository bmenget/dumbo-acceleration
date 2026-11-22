--------------------------------------------------------------------------------
-- core_v2_gen: parameterized Dumbo v2 core (see rtl/core_v2_gen/GEN.md).
-- Derived from GMU's arch-1 Elephant core (GPL v3, see rtl/UPSTREAM.md).
--
-- The four configuration lines below (G_R, G_S, G_U, G_FAST_LOADER) are rewritten by
-- scripts/sweep.py for each design point; keep their exact "constant G_X : type := value;" form.
-- The checked-in values are core_v2_r4_optBCD's configuration (R=8, S=2, U=2).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- helper used by the derived constants below (a package's own functions can't be called by its constants)
package gen_util is
    function imax(a, b: integer) return integer;
end package gen_util;
package body gen_util is
    function imax(a, b: integer) return integer is
    begin
        if a > b then return a; else return b; end if;
    end function;
end package body gen_util;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.gen_util.all;

package elephant_constants is
    constant STATE_SIZE: integer := 160;
    constant CCW_SIZE: integer := 32;

    constant KEY_SIZE: integer := 4; --16 Bytes
    constant KEY_SIZE_BITS: integer := KEY_SIZE * CCW_SIZE;
    constant ELE_NPUB_SIZE: integer := 3; --12 Bytes
    constant NPUB_SIZE_BITS : integer := ELE_NPUB_SIZE * CCW_SIZE;
    constant ELE_TAG_SIZE: integer := 2; -- 8 Bytes
    constant TAG_SIZE_BITS: integer := ELE_TAG_SIZE * CCW_SIZE;
    constant BLOCK_SIZE: integer := 5; --20 Bytes

    ----------------------------------------------------------------------------
    -- Configuration
    constant G_R : integer := 8;
    constant G_S : integer := 2;
    constant G_U : integer := 2;
    constant G_FAST_LOADER : boolean := false;
    -- G_R: rounds of logic per unit (unrolling); G_S: pipeline stages per unit (must divide G_R);
    -- G_U: units; G_FAST_LOADER: decide the next block buffer in the same cycle as a block's last word.
    ----------------------------------------------------------------------------

    constant G_RPS : integer := G_R / G_S;                        -- rounds per stage (critical path)
    constant G_N   : integer := G_U * G_S;                        -- permutation calls in flight (slots)
    constant G_M   : integer := G_N / 2;                          -- message blocks per round
    constant G_NKS : integer := imax(G_M, 1);                     -- keystream buffers (= MAC slots per round)
    constant G_NKS0 : integer := imax(2 * G_M, 1);                -- slots used by the message's first round
    constant PERM_CYCLES : integer := (80 + G_RPS - 1) / G_RPS;   -- cycles (stage passes) per call
    constant G_TAIL : integer := 80 - (PERM_CYCLES - 1) * G_RPS;  -- rounds used in the last pass
    constant G_ROT  : integer := PERM_CYCLES mod G_S;             -- stage offset of a result vs. its load
    constant G_NMASK : integer := imax(imax(3 * G_M + 1, G_N), 3); -- masks in the LFSR window
    constant LFSR_W : integer := STATE_SIZE + 8 * (G_NMASK - 1);

    -- slot-mux mode (selects every slot's source and mask; see elephant_datapath.vhd)
    constant MD_KEY : std_logic_vector(2 downto 0) := "000";  -- slot 0: input buffer 0, no mask
    constant MD_AD  : std_logic_vector(2 downto 0) := "001";  -- AD blocks j..j+N-1
    constant MD_KS0 : std_logic_vector(2 downto 0) := "010";  -- message start: KS(0..2M-1)
    constant MD_MSG : std_logic_vector(2 downto 0) := "011";  -- MACs and keystreams of one message round
    constant MD_FIN : std_logic_vector(2 downto 0) := "100";  -- slot 0: tag xor L
    constant MD_KS1 : std_logic_vector(2 downto 0) := "101";  -- N = 1 only: KS(k+1) before MAC(k)

    -- LFSR step selects
    constant ST_MSG    : std_logic_vector(1 downto 0) := "00";  -- max(M,1) steps per message round
    constant ST_AD     : std_logic_vector(1 downto 0) := "01";  -- N steps per AD batch
    constant ST_ADINIT : std_logic_vector(1 downto 0) := "10";  -- after a load: to a = 2
    constant ST_MSGINIT: std_logic_vector(1 downto 0) := "11";  -- after a load: to a = 1
end package elephant_constants;
