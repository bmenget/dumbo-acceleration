--------------------------------------------------------------------------------
-- brody/gen: mask LFSR window of G_NMASK consecutive masks phi^(a-1) .. phi^(a-2+G_NMASK).
-- Derived from GMU's elephant_datapath_lfsr.vhd (GPL v3).
-- Bytes shift down; the newest mask is the top 160 bits. A load puts L in the newest mask.
-- step selects how many LFSR steps one enable performs (constants in elephant_constants). A multi-step
-- is the single step iterated at elaboration; the step is linear, so it synthesizes to an XOR network.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.elephant_constants.all;

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

    -- C: temp = rotl3(input[0]) ^ (input[3] << 7) ^ (input[13] >> 7); output = input[1..19] ++ temp
    function steps(v: std_logic_vector(LFSR_W-1 downto 0); n: natural) return std_logic_vector is
        variable x: std_logic_vector(LFSR_W-1 downto 0) := v;
        variable t: std_logic_vector(7 downto 0);
    begin
        for k in 1 to n loop
            t := (x(OFF+4) xor x(OFF+24)) & x(OFF+3 downto OFF) & x(OFF+7 downto OFF+6) &
                 (x(OFF+5) xor x(OFF+111));
            x := t & x(LFSR_W-1 downto 8);
        end loop;
        return x;
    end function;
begin
    lfsr_input <= key_in & std_logic_vector(to_unsigned(0, OFF)) when load_key = '1' else
                  steps(lfsr_output, G_NKS)                 when step = ST_MSG else
                  steps(lfsr_output, G_N)                          when step = ST_AD else
                  steps(lfsr_output, G_NMASK)                      when step = ST_ADINIT else
                  steps(lfsr_output, G_NMASK - 1);
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
