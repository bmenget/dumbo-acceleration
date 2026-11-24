--------------------------------------------------------------------------------
--! @file       elephant_datapath_lfsr.vhd
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
use work.elephant_constants.all;

entity elephant_datapath_lfsr is
    port(
        load_key: in std_logic;
        clk: in std_logic;
        key_in: in std_logic_vector(STATE_SIZE-1 downto 0);
        en: in std_logic;
        ele_lfsr_output: out std_logic_vector(STATE_SIZE+24-1 downto 0)
    );
end elephant_datapath_lfsr;

architecture behavioral of elephant_datapath_lfsr is
    signal lfsr_input: std_logic_vector(STATE_SIZE+24-1 downto 0);
    signal lfsr_output: std_logic_vector(STATE_SIZE+24-1 downto 0);
    signal lfsr_temp_rot: std_logic_vector(7 downto 0);
begin
    --LFSR output
    --C code
    --BYTE temp = rotl3(input[0]) ^ (input[3] << 7) ^ (input[13] >> 7);
    -- BtoC: window widened by one mask (184 bits: prev, cur, next, next2); the newest mask is the
    -- top 160 bits, so the taps sit at offset 24 (was 16) and a load puts L in next2.
    lfsr_temp_rot <= (lfsr_output(4+24)  xor lfsr_output(24+24)) & lfsr_output(3+24 downto 0+24) & lfsr_output(7+24 downto 6+24) &
                     (lfsr_output(5+24) xor lfsr_output(111+24));
    lfsr_input <= lfsr_temp_rot & lfsr_output(STATE_SIZE+24-1 downto 8) when load_key = '0' else  key_in & x"000000";
    ele_lfsr_output <= lfsr_output;

    p_lfsr_data: process(clk, en)
    begin
        if rising_edge(clk) and en = '1' then
            lfsr_output <= lfsr_input;
        end if;
    end process;

end architecture behavioral;
