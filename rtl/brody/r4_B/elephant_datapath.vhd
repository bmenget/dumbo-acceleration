--------------------------------------------------------------------------------
--! @file       elephant_datapath.vhd
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
use work.Design_pkg.all;

entity elephant_datapath is
    port(
        --Signals to con
        key: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi_size: in std_logic_vector(1 downto 0);
        data_type_sel: std_logic;

        load_data_en: in std_logic;
        load_data_sel: in std_logic_vector(1 downto 0);
        -- option B: the state/tag input is src xor mask (was one 6-way lfsr_mux_sel)
        src_sel: in std_logic_vector(1 downto 0);
        mask_sel: in std_logic_vector(2 downto 0);
        ks_en: in std_logic;

        --Signals for key and npub
        key_en: in std_logic;
        npub_en: in std_logic;
        tag_en: in std_logic;
        tag_reset: in std_logic;
        
        ms_en: in std_logic;
        --Signals for permutation
        perm_en: in std_logic;
        load_lfsr: in std_logic;
        
        datap_lfsr_load: in std_logic;
        datap_lfsr_en: in std_logic;
        
        bdo: out std_logic_vector(CCW_SIZE-1 downto 0);
        bdo_sel: in std_logic;
        saving_bdo: in std_logic;
        data_count: in integer range 0 to BLOCK_SIZE+1; --std_logic_vector(2 downto 0);
        perm_count: in integer range 0 to PERM_CYCLES;
        clk: in std_logic
    );
end elephant_datapath;

architecture behavioral of elephant_datapath is
    
    signal permout: std_logic_vector(STATE_SIZE-1 downto 0);
    signal perm_input: std_logic_vector(STATE_SIZE-1 downto 0);
    
    signal datap_lfsr_out: std_logic_vector(STATE_SIZE+16-1 downto 0);
    signal lfsr_current: std_logic_vector(STATE_SIZE-1 downto 0);
    signal lfsr_next: std_logic_vector(STATE_SIZE-1 downto 0);
    signal lfsr_prev: std_logic_vector(STATE_SIZE-1 downto 0);
    signal mask: std_logic_vector(STATE_SIZE-1 downto 0);       -- option B: selected mask
    signal src: std_logic_vector(STATE_SIZE-1 downto 0);        -- option B: selected source
    signal nonce_blk: std_logic_vector(STATE_SIZE-1 downto 0);  -- option B: N || 0, read straight from npub_out
    signal ks_reg: std_logic_vector(STATE_SIZE-1 downto 0);     -- option B: keystream buffer, frees ms_reg for the MAC

    
    signal bdi_or_key: std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_key_rev : std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal padding_bdi: std_logic_vector(CCW_SIZE-1 downto 0);
--    signal bdi_or_reset: std_logic_vector(CCW_SIZE-1 downto 0);
    signal load_data_input_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    signal load_data_output: std_logic_vector(STATE_SIZE-1 downto 0);
    signal lfsr_xor_mux: std_logic_vector(STATE_SIZE-1 downto 0);
    
    signal key_out: std_logic_vector(STATE_SIZE-1 downto 0);
    signal npub_out: std_logic_vector(NPUB_SIZE_BITS-1 downto 0);
    signal tag_out: std_logic_vector(STATE_SIZE-1 downto 0);    -- v2: full 160-bit tag state S
    signal tag_input: std_logic_vector(STATE_SIZE-1 downto 0);
    
    -- Verifiy this size
    signal ms_reg_input_mux: std_logic_vector(STATE_SIZE-1 downto 0);
    signal ms_reg_out: std_logic_vector(STATE_SIZE-1 downto 0);
    signal ms_out_mux1: std_logic_vector(CCW_SIZE-1 downto 0);
    signal ms_out_mux2: std_logic_vector(CCW_SIZE-1 downto 0);
    
    signal data_out_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal tag_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    
begin

    PERM: entity work.elephant_perm
        port map(
            input => perm_input,
            clk => clk,
            perm_count => perm_count,
            load_lfsr => load_lfsr,
            output => permout
        );
    DATAP_LFSR: entity work.elephant_datapath_lfsr
        port map(
            load_key    => datap_lfsr_load,
            clk         => clk,
            key_in      => key_out,
            en          => datap_lfsr_en,
            ele_lfsr_output => datap_lfsr_out
        );
    p_ms_reg: process(clk, ms_en)
    begin
        if rising_edge(clk) and  ms_en = '1' then
            ms_reg_out <= ms_reg_input_mux;
        end if;
    end process;
    p_key_reg: process(clk, key_en)
    begin
        if rising_edge(clk) and key_en = '1' then
            key_out <= ms_reg_input_mux(STATE_SIZE-1 downto 0);
        end if;
    end process;

    p_npub_reg: process(clk, npub_en)
    begin
        if rising_edge(clk) and npub_en = '1' then
            npub_out <= load_data_output(STATE_SIZE-1 downto STATE_SIZE-NPUB_SIZE_BITS);
        end if;
    end process;

    p_tag_reg: process(clk, tag_en)
    begin
        if rising_edge(clk) and tag_en = '1' then
            tag_out <= tag_input;
        end if;
    end process;

    p_load_data: process(clk, load_data_en)
    begin
        if rising_edge(clk) and load_data_en = '1' then
            if load_data_sel = "11" then
                load_data_output <= x"0000000000000000" & npub_out;
            else
                load_data_output <= load_data_input_mux & load_data_output(STATE_SIZE-1 downto CCW_SIZE);
            end if;
        end if;
    end process;

    --Select between process key or bdi
    bdi_or_key <= bdi when data_type_sel = '0' else  key;
    bdi_or_key_rev <= reverse_byte(bdi_or_key);
    bdi_or_bdo <= bdi_or_key_rev when saving_bdo = '0' else data_bdo;
    
    
   --Logic for how padding works
    with bdi_size select
        padding_bdi <= x"00000001" when "00",
                       x"000001" & bdi_or_bdo(7 downto 0) when "01",
                       x"0001" & bdi_or_bdo(15 downto 0) when "10",
                       x"01" & bdi_or_bdo(23 downto 0) when others;
    --Also mux is very large at the momment might be able to reduce to CCW size
    --mux to reset load_data and shift data input
    with load_data_sel select
        load_data_input_mux <= x"00000000"  when "00",
                               bdi_or_bdo   when "01",
                               padding_bdi  when others;

    --Above and beyond logic see if there is a way to not include ms_reg_out in xor.
    --Would likely required this to happen after mux and => ms_reg would be zero prior
    --to the loading the state.
    lfsr_current <= datap_lfsr_out(STATE_SIZE+8-1 downto 8);
    lfsr_next <= datap_lfsr_out(STATE_SIZE+16-1 downto 16);
    lfsr_prev <= datap_lfsr_out(STATE_SIZE-1 downto 0);
    -- option B: lfsr_xor_mux = src xor mask. Window at position a: prev = phi^(a-1), cur = phi^a, next = phi^(a+1).
    --  src_sel   00 ms_reg          01 input block (load_data_output)
    --            10 N || 0          11 tag accumulator
    --  mask_sel  000 none           001 prev           (AD MAC block j, a = j+1)
    --            010 prev xor next  (ciphertext MAC block k, a = k+1)
    --            011 cur xor next   (keystream block k, a = k)
    --            1-- L              (final tag permutation)
    nonce_blk <= x"0000000000000000" & npub_out;
    with src_sel select
        src <= ms_reg_out       when "00",
               load_data_output when "01",
               nonce_blk        when "10",
               tag_out          when others;
    with mask_sel select
        mask <= (others => '0')         when "000",
                lfsr_prev               when "001",
                lfsr_prev xor lfsr_next when "010",
                lfsr_current xor lfsr_next when "011",
                key_out                 when others;
    lfsr_xor_mux <= src xor mask;

    tag_input <= lfsr_xor_mux xor tag_out when tag_reset = '0' else (others => '0');

    --Logic for ms_reg_mux and perm
    ms_reg_input_mux <= permout when perm_en = '1' else lfsr_xor_mux;
    perm_input <= ms_reg_out;

    -- option B: keystream buffer. Loaded right after a keystream permutation (window unchanged since its input
    -- was masked), so the message words can stream from it while ms_reg runs the next MAC permutation.
    p_ks_reg: process(clk)
    begin
        if rising_edge(clk) then
            if ks_en = '1' then
                ks_reg <= ms_reg_out xor lfsr_current xor lfsr_next;
            end if;
        end if;
    end process;

    with data_count select
        ms_out_mux2 <= ks_reg(CCW-1 downto 0) when 0,
                       ks_reg((2*CCW)-1 downto CCW) when 1,
                       ks_reg((3*CCW)-1 downto 2*CCW) when 2,
                       ks_reg((4*CCW)-1 downto 3*CCW) when 3,
                       ks_reg((5*CCW)-1 downto 4*CCW) when others;
    --ms_out_mux2 <= ms_out_mux1 when data_count /= 4 else ms_reg_out(STATE_SIZE-1 downto 4*CCW);
    data_bdo <= bdi_or_key_rev xor ms_out_mux2;
    bdo <= reverse_byte(data_out_mux);
    -- v2: the tag is trunc64 of the final result, held in ms_reg after the final permutation
    tag_mux <= ms_reg_out(63 downto 32) when data_count = 1 else ms_reg_out(31 downto 0);
    data_out_mux <= data_bdo when bdo_sel ='0' else tag_mux;
    
end behavioral;

