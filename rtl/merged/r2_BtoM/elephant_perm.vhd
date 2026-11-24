--------------------------------------------------------------------------------
--! @file       elephant_perm.vhd
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
use work.elephant_constants.all;

--------------------------------------------------------------------------------
-- BtoG: PERM_ROUNDS_PER_CYCLE Spongent-pi[160] rounds, combinational. The round constants come in
-- registered (rc, one byte per round, first round in the top byte) instead of being looked up from a
-- round counter here, so the stage path starts at the state register.
--------------------------------------------------------------------------------
entity elephant_perm is
    port(
        input: in std_logic_vector(STATE_SIZE-1 downto 0);
        rc: in rc_t;
        output: out std_logic_vector(STATE_SIZE-1 downto 0)
    );
end elephant_perm;

architecture elephant_perm of elephant_perm is
    type state_arr is array (0 to PERM_ROUNDS_PER_CYCLE) of std_logic_vector(STATE_SIZE-1 downto 0);
    signal st: state_arr;

    type rom_array is array (0 to 15) of std_logic_vector(0 to 3);
    constant sbox: rom_array :=(
        x"e", x"d", x"b", x"0", x"2", x"1", x"4", x"f",
        x"7", x"a", x"8", x"5", x"9", x"c", x"3", x"6"
    );

    function rev7(a: std_logic_vector(6 downto 0)) return std_logic_vector is
    begin
        return a(0) & a(1) & a(2) & a(3) & a(4) & a(5) & a(6);
    end function;
begin
    st(0) <= input;
    rnd: for x in 0 to PERM_ROUNDS_PER_CYCLE-1 generate
        signal c: std_logic_vector(6 downto 0);
        signal a, s: std_logic_vector(STATE_SIZE-1 downto 0);
    begin
        c <= rc(RCW-2-8*x downto RCW-8-8*x);
        a <= (rev7(c) xor st(x)(STATE_SIZE-1 downto 153)) & st(x)(152 downto 7) & (c xor st(x)(6 downto 0));
        sbox_gen: for i in 39 downto 0 generate
            s(i*4 + 3 downto i*4) <= sbox(to_integer(unsigned(a(i*4 + 3 downto i*4))));
        end generate;
        player: for j in 0 to 158 generate
            st(x+1)((40 * j) mod (STATE_SIZE-1)) <= s(j);
        end generate;
        st(x+1)(STATE_SIZE-1) <= s(STATE_SIZE-1);
    end generate;
    output <= st(PERM_ROUNDS_PER_CYCLE);
end architecture elephant_perm;
