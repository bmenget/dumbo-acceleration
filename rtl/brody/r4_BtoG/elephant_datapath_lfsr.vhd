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

-- BtoE (unchanged in BtoF): a window of NM consecutive masks (bytes shift down, the newest mask is the top 160 bits).
-- load puts L in the newest mask; step advances the window by one LFSR step (phi).
-- After load and NM-1 steps the window is phi^0 .. phi^(NM-1).
-- BtoE uses two: one for AD / MAC masks (NM = 3) and one for keystream masks (NM = 2), so the
-- keystream calls can run ahead of the MACs without sharing a window.
entity elephant_mask_lfsr is
    generic(NM: integer);
    port(
        clk: in std_logic;
        load: in std_logic;
        step: in std_logic;
        key_in: in std_logic_vector(STATE_SIZE-1 downto 0);
        win: out std_logic_vector(STATE_SIZE + 8*(NM-1) - 1 downto 0)
    );
end elephant_mask_lfsr;

architecture behavioral of elephant_mask_lfsr is
    constant W: integer := STATE_SIZE + 8*(NM-1);
    constant OFF: integer := W - STATE_SIZE;     -- bit 0 of the newest mask
    signal o: std_logic_vector(W-1 downto 0);
    signal t0: std_logic_vector(7 downto 0);

    -- C: temp = rotl3(input[i]) ^ (input[i+3] << 7) ^ (input[i+13] >> 7)
    function tbyte(v: std_logic_vector(W-1 downto 0); i: integer) return std_logic_vector is
        variable m0, m3, m13: integer;
    begin
        m0  := OFF + 8*i;
        m3  := OFF + 8*(i+3);
        m13 := OFF + 8*(i+13);
        return (v(m0+4) xor v(m3)) & v(m0+3 downto m0) & v(m0+7 downto m0+6) & (v(m0+5) xor v(m13+7));
    end function;
begin
    t0 <= tbyte(o, 0);
    win <= o;

    p_lfsr: process(clk)
    begin
        if rising_edge(clk) then
            if load = '1' then
                o <= key_in & std_logic_vector(to_unsigned(0, OFF));
            elsif step = '1' then
                o <= t0 & o(W-1 downto 8);
            end if;
        end if;
    end process;
end architecture behavioral;
