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
use work.elephant_constants.all;

-- BtoD: mask LFSR window of LFSR_MASKS masks (bytes shift down, the newest mask is the top 160 bits).
-- A load puts L in the newest mask. step selects how many LFSR steps one enable performs:
-- "00" 1, "01" 2, others 4. Step i of a multi-step only reads bytes i, i+3, i+13 of the newest mask,
-- which are all still original bytes for i <= 6, so up to 7 steps fit in one cycle.
entity elephant_datapath_lfsr is
    port(
        load_key: in std_logic;
        clk: in std_logic;
        key_in: in std_logic_vector(STATE_SIZE-1 downto 0);
        en: in std_logic;
        step: in std_logic_vector(1 downto 0);
        ele_lfsr_output: out std_logic_vector(LFSR_W-1 downto 0)
    );
end elephant_datapath_lfsr;

architecture behavioral of elephant_datapath_lfsr is
    constant OFF: integer := LFSR_W - STATE_SIZE;     -- bit 0 of the newest mask
    signal lfsr_output: std_logic_vector(LFSR_W-1 downto 0);
    signal lfsr_input: std_logic_vector(LFSR_W-1 downto 0);
    signal t0, t1, t2, t3: std_logic_vector(7 downto 0);

    -- C: temp = rotl3(input[i]) ^ (input[i+3] << 7) ^ (input[i+13] >> 7)
    function tbyte(o: std_logic_vector(LFSR_W-1 downto 0); i: integer) return std_logic_vector is
        variable m0, m3, m13: integer;
    begin
        m0  := OFF + 8*i;
        m3  := OFF + 8*(i+3);
        m13 := OFF + 8*(i+13);
        return (o(m0+4) xor o(m3)) & o(m0+3 downto m0) & o(m0+7 downto m0+6) & (o(m0+5) xor o(m13+7));
    end function;
begin
    t0 <= tbyte(lfsr_output, 0);
    t1 <= tbyte(lfsr_output, 1);
    t2 <= tbyte(lfsr_output, 2);
    t3 <= tbyte(lfsr_output, 3);

    lfsr_input <= key_in & std_logic_vector(to_unsigned(0, OFF))       when load_key = '1' else
                  t0 & lfsr_output(LFSR_W-1 downto 8)                    when step = "00" else
                  t1 & t0 & lfsr_output(LFSR_W-1 downto 16)              when step = "01" else
                  t3 & t2 & t1 & t0 & lfsr_output(LFSR_W-1 downto 32);
    ele_lfsr_output <= lfsr_output;

    p_lfsr_data: process(clk)
    begin
        if rising_edge(clk) then
            if en = '1' then
                lfsr_output <= lfsr_input;
            end if;
        end if;
    end process;

end architecture behavioral;
