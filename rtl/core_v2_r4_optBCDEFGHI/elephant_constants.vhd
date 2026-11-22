--------------------------------------------------------------------------------
--! @file       elephant_constants.vhd
--! @brief
--! @author     Richard Haeussler
--! @copyright  Copyright (c) 2020 Cryptographic Engineering Research Group
--!             ECE Department, George Mason University Fairfax, VA, U.S.A.
--!             All rights Reserved.
--! @license    This project is released under the GNU Public License.
--!             The license and distribution terms for this file may be
--!             found in the file LICENSE in this distribution or at
--!             http://www.gnu.org/licenses/gpl-3.0.txt
--! @note       This is publicly available encryption source code that falls
--!             under the License Exception TSU (Technology and software-
--!             unrestricted)
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use ieee.math_real.all;

package elephant_constants is
    constant STATE_SIZE: integer := 160;
    constant CCW_SIZE: integer := 32;
    constant ADDR_BITs: integer := 3;
    constant MASK_ADDR_BITs: integer := 2;

    constant KEY_SIZE: integer := 4; --16 Bytes
    constant KEY_SIZE_BITS: integer := KEY_SIZE * CCW_SIZE;
    constant ELE_NPUB_SIZE: integer := 3; --12 Bytes
    constant NPUB_SIZE_BITS : integer := ELE_NPUB_SIZE * CCW_SIZE;
    constant ELE_TAG_SIZE: integer := 2; -- 8 Bytes
    constant TAG_SIZE_BITS: integer := ELE_TAG_SIZE * CCW_SIZE;
    constant BLOCK_SIZE: integer := 5; --20 Bytes --Message full 5

    -- optBCDEFG: rounds per pipeline stage (any divisor of 80 >= 2)
    constant PERM_ROUNDS_PER_CYCLE: integer := 4;
    constant PERM_CYCLES: integer := 80/PERM_ROUNDS_PER_CYCLE;
    constant PERM_CYCLES_BITS: integer := 7;

    -- optBCDEFGH: NUNIT rings of NSTAGE stage registers, one staggered call per register; new calls go
    -- into stage 0 only and finish in stage NSTAGE-1 (needs PERM_CYCLES mod NSTAGE = 0). See OPT_BCDEFGH.md
    constant NUNIT    : integer := 2;
    constant NSTAGE   : integer := 4;
    constant NSLOT    : integer := NUNIT * NSTAGE;
    constant NKS      : integer := 6;    -- keystream calls allowed ahead = keystream FIFO depth
    constant SEG_WAIT : integer := 16;   -- cycles to wait for a segment type before calling it empty
    constant MAC_MASKS: integer := 3;    -- AD/MAC mask window phi^m .. phi^(m+2)
    constant KS_MASKS : integer := 2;    -- keystream mask window phi^k, phi^(k+1)

    -- round group index of the call in each stage register
    type pc_arr is array (0 to NSLOT-1) of integer range 0 to PERM_CYCLES;

    -- round constants of one round group: one byte per round, first round in the top byte
    constant RCW: integer := 8 * PERM_ROUNDS_PER_CYCLE;
    subtype rc_t is std_logic_vector(RCW-1 downto 0);
    type rc_arr is array (0 to NSLOT-1) of rc_t;
    type rc_tab_t is array (0 to PERM_CYCLES) of rc_t;
    constant RC_TAB: rc_tab_t;           -- RC_TAB(g) = constants of round group g (RC_TAB(PERM_CYCLES) = 0)

    -- call kinds
    constant K_KEY : std_logic_vector(2 downto 0) := "000";  -- L = P(K||0)
    constant K_AD  : std_logic_vector(2 downto 0) := "001";  -- P(A_j xor phi^j) xor phi^j
    constant K_MAC : std_logic_vector(2 downto 0) := "010";  -- P(C_k xor phi^k xor phi^(k+2)) xor (same)
    constant K_KS  : std_logic_vector(2 downto 0) := "011";  -- P(N xor phi^k xor phi^(k+1)) xor (same)
    constant K_FIN : std_logic_vector(2 downto 0) := "100";  -- P(S xor L) xor L

    -- ring geometry: register p is stage p mod NSTAGE of ring p / NSTAGE; a call moves to nxt(p) each cycle
    function nxt(p: integer) return integer;
    function prv(p: integer) return integer;
end package elephant_constants;

package body elephant_constants is
    function rc_gen return rc_tab_t is
        variable t: rc_tab_t := (others => (others => '0'));
        variable l: std_logic_vector(6 downto 0) := "1110101";
        variable i: integer := 0;
    begin
        for g in 0 to PERM_CYCLES-1 loop
            for x in 0 to PERM_ROUNDS_PER_CYCLE-1 loop
                t(g)(RCW-1-8*x downto RCW-8-8*x) := '0' & l;
                l := l(5 downto 0) & (l(6) xor l(5));
            end loop;
        end loop;
        return t;
    end function;
    constant RC_TAB: rc_tab_t := rc_gen;

    function nxt(p: integer) return integer is
    begin
        return (p / NSTAGE) * NSTAGE + (p mod NSTAGE + 1) mod NSTAGE;
    end function;
    function prv(p: integer) return integer is
    begin
        return (p / NSTAGE) * NSTAGE + (p mod NSTAGE + NSTAGE - 1) mod NSTAGE;
    end function;
end package body elephant_constants;
