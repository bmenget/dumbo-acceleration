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

--------------------------------------------------------------------------------
-- optBCD datapath: four permutation slots, two pipelined units.
--  Unit A = slots 0 (A0) and 1 (A1), unit B = slots 2 (B0) and 3 (B1). Each unit is an 8-round loop
--  cut into two 4-round stages: r(0) -> P -> r(1) -> P -> r(0). Two calls are in flight per unit, one in
--  each stage register; both stages always process the same 4-round group (perm_count), so after an even
--  number of cycles (PERM_CYCLES = 20) every call is back in the register it was loaded into.
--  Outside PERM a slot loads x(s) = src(s) xor mask(s); mode picks both for all slots at once, and
--  unmask = '1' makes every slot's source its own register (unmask after a permutation).
--  Window w(i) = phi^(a-1+i), i = 0..6 (w0 = prev, w1 = cur, w2 = next, ...).
--
--  mode     A0               A1               B0               B1
--  KEY      buf0             -                -                -
--  AD       buf0 ^ w0        buf1 ^ w1        buf2 ^ w2        buf3 ^ w3        (blocks j..j+3, a = j+1)
--  KS0      N ^ w0^w1        N ^ w1^w2        N ^ w2^w3        N ^ w3^w4        (KS(0..3), a = 1)
--  MSG      buf0 ^ w0^w2     buf1 ^ w1^w3     N ^ w4^w5        N ^ w5^w6        (MAC(k), MAC(k+1), KS(k+4), KS(k+5), a = k+1)
--  FIN      tag ^ L          -                -                -
--------------------------------------------------------------------------------
entity elephant_datapath is
    port(
        key: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi_size: in std_logic_vector(1 downto 0);
        data_type_sel: std_logic;

        load_data_en: in std_logic;
        load_data_sel: in std_logic_vector(1 downto 0);
        load_buf: in std_logic_vector(1 downto 0);      -- input buffer the loader writes

        mode: in std_logic_vector(2 downto 0);
        unmask: in std_logic;
        ld: in std_logic_vector(3 downto 0);            -- per-slot load (outside PERM)
        te: in std_logic_vector(3 downto 0);            -- per-slot: xor x(s) into the tag
        ks_en: in std_logic;
        ks_from_b: in std_logic;                        -- '1': ks0/ks1 <= r(2)/r(3); '0': <= x(0)/x(1)
        ks_buf_sel: in std_logic;                       -- message words stream from ks1 when '1'

        key_en: in std_logic;
        npub_en: in std_logic;
        tag_en: in std_logic;
        tag_reset: in std_logic;

        perm_en: in std_logic;
        load_lfsr: in std_logic;

        datap_lfsr_load: in std_logic;
        datap_lfsr_en: in std_logic;
        datap_lfsr_step: in std_logic_vector(1 downto 0);

        bdo: out std_logic_vector(CCW_SIZE-1 downto 0);
        bdo_sel: in std_logic;
        saving_bdo: in std_logic;
        data_count: in integer range 0 to BLOCK_SIZE+1;
        perm_count: in integer range 0 to PERM_CYCLES;
        clk: in std_logic
    );
end elephant_datapath;

architecture behavioral of elephant_datapath is
    type slot_arr is array (0 to 3) of std_logic_vector(STATE_SIZE-1 downto 0);
    signal r, pout, x, srcv, maskv, ib: slot_arr;
    type win_arr is array (0 to LFSR_MASKS-1) of std_logic_vector(STATE_SIZE-1 downto 0);
    signal w: win_arr;
    signal datap_lfsr_out: std_logic_vector(LFSR_W-1 downto 0);
    constant ZERO: std_logic_vector(STATE_SIZE-1 downto 0) := (others => '0');

    signal nonce_blk: std_logic_vector(STATE_SIZE-1 downto 0);
    signal ks0, ks1, ks_cur: std_logic_vector(STATE_SIZE-1 downto 0);

    signal bdi_or_key: std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_key_rev : std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal padding_bdi: std_logic_vector(CCW_SIZE-1 downto 0);
    signal load_data_input_mux: std_logic_vector(CCW_SIZE-1 downto 0);

    signal key_out: std_logic_vector(STATE_SIZE-1 downto 0);
    signal npub_out: std_logic_vector(NPUB_SIZE_BITS-1 downto 0);
    signal tag_out: std_logic_vector(STATE_SIZE-1 downto 0);
    signal tag_input: std_logic_vector(STATE_SIZE-1 downto 0);

    signal ms_out_mux2: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_out_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal tag_mux: std_logic_vector(CCW_SIZE-1 downto 0);

begin
    assert PERM_CYCLES mod 2 = 0
        report "optBCD: two-stage units need an even PERM_CYCLES" severity failure;

    gen_perm: for s in 0 to 3 generate
        P: entity work.elephant_perm
            port map(
                input => r(s),
                clk => clk,
                perm_count => perm_count,
                load_lfsr => load_lfsr,
                output => pout(s)
            );
    end generate;

    DATAP_LFSR: entity work.elephant_datapath_lfsr
        port map(
            load_key    => datap_lfsr_load,
            clk         => clk,
            key_in      => key_out,
            en          => datap_lfsr_en,
            step        => datap_lfsr_step,
            ele_lfsr_output => datap_lfsr_out
        );
    gen_win: for i in 0 to LFSR_MASKS-1 generate
        w(i) <= datap_lfsr_out(8*i + STATE_SIZE-1 downto 8*i);
    end generate;

    -- slot registers: during PERM each takes its unit partner's stage output
    p_slots: process(clk)
    begin
        if rising_edge(clk) then
            if perm_en = '1' then
                r(0) <= pout(1);
                r(1) <= pout(0);
                r(2) <= pout(3);
                r(3) <= pout(2);
            else
                for s in 0 to 3 loop
                    if ld(s) = '1' then
                        r(s) <= x(s);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- L = P(K||0): the key permutation runs in A0 and its last stage is pout(1) -> r(0).
    -- Taken straight from the permutation, not through the slot load mux.
    p_key_reg: process(clk)
    begin
        if rising_edge(clk) then
            if key_en = '1' then
                key_out <= pout(1);
            end if;
        end if;
    end process;

    p_npub_reg: process(clk)
    begin
        if rising_edge(clk) then
            if npub_en = '1' then
                npub_out <= ib(0)(STATE_SIZE-1 downto STATE_SIZE-NPUB_SIZE_BITS);
            end if;
        end if;
    end process;

    p_tag_reg: process(clk)
    begin
        if rising_edge(clk) then
            if tag_en = '1' then
                tag_out <= tag_input;
            end if;
        end if;
    end process;

    -- input block buffers (word shift registers)
    p_load_data: process(clk)
    begin
        if rising_edge(clk) then
            if load_data_en = '1' then
                if load_buf = "00" and load_data_sel = "11" then
                    ib(0) <= x"0000000000000000" & npub_out;
                else
                    case load_buf is
                        when "00"   => ib(0) <= load_data_input_mux & ib(0)(STATE_SIZE-1 downto CCW_SIZE);
                        when "01"   => ib(1) <= load_data_input_mux & ib(1)(STATE_SIZE-1 downto CCW_SIZE);
                        when "10"   => ib(2) <= load_data_input_mux & ib(2)(STATE_SIZE-1 downto CCW_SIZE);
                        when others => ib(3) <= load_data_input_mux & ib(3)(STATE_SIZE-1 downto CCW_SIZE);
                    end case;
                end if;
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
    with load_data_sel select
        load_data_input_mux <= x"00000000"  when "00",
                               bdi_or_bdo   when "01",
                               padding_bdi  when others;

    -- slot sources and masks (table at the top)
    nonce_blk <= x"0000000000000000" & npub_out;

    srcv(0) <= r(0)      when unmask = '1' else
               tag_out   when mode = MD_FIN else
               nonce_blk when mode = MD_KS0 else
               ib(0);
    srcv(1) <= r(1)      when unmask = '1' else
               nonce_blk when mode = MD_KS0 else
               ib(1);
    srcv(2) <= r(2)      when unmask = '1' else
               ib(2)     when mode = MD_AD else
               nonce_blk;
    srcv(3) <= r(3)      when unmask = '1' else
               ib(3)     when mode = MD_AD else
               nonce_blk;

    with mode select
        maskv(0) <= w(0)              when MD_AD,
                    w(0) xor w(1)     when MD_KS0,
                    w(0) xor w(2)     when MD_MSG,
                    key_out           when MD_FIN,
                    ZERO              when others;
    with mode select
        maskv(1) <= w(1)              when MD_AD,
                    w(1) xor w(2)     when MD_KS0,
                    w(1) xor w(3)     when MD_MSG,
                    ZERO              when others;
    with mode select
        maskv(2) <= w(2)              when MD_AD,
                    w(2) xor w(3)     when MD_KS0,
                    w(4) xor w(5)     when MD_MSG,
                    ZERO              when others;
    with mode select
        maskv(3) <= w(3)              when MD_AD,
                    w(3) xor w(4)     when MD_KS0,
                    w(5) xor w(6)     when MD_MSG,
                    ZERO              when others;

    gen_x: for s in 0 to 3 generate
        x(s) <= srcv(s) xor maskv(s);
    end generate;

    -- tag accumulator: tag xor every enabled slot term
    p_tag_in: process(all)
        variable acc: std_logic_vector(STATE_SIZE-1 downto 0);
    begin
        acc := tag_out;
        for s in 0 to 3 loop
            if te(s) = '1' then
                acc := acc xor x(s);
            end if;
        end loop;
        if tag_reset = '1' then
            tag_input <= (others => '0');
        else
            tag_input <= acc;
        end if;
    end process;

    -- keystream buffers: KS(0)/KS(1) come unmasked from A0/A1 (mode KS0, unmask); later keystreams were
    -- unmasked in place in B0/B1 and are copied when their blocks start streaming
    p_ks: process(clk)
    begin
        if rising_edge(clk) then
            if ks_en = '1' then
                if ks_from_b = '1' then
                    ks0 <= r(2);
                    ks1 <= r(3);
                else
                    ks0 <= x(0);
                    ks1 <= x(1);
                end if;
            end if;
        end if;
    end process;
    ks_cur <= ks1 when ks_buf_sel = '1' else ks0;

    with data_count select
        ms_out_mux2 <= ks_cur(CCW-1 downto 0) when 0,
                       ks_cur((2*CCW)-1 downto CCW) when 1,
                       ks_cur((3*CCW)-1 downto 2*CCW) when 2,
                       ks_cur((4*CCW)-1 downto 3*CCW) when 3,
                       ks_cur((5*CCW)-1 downto 4*CCW) when others;
    data_bdo <= bdi_or_key_rev xor ms_out_mux2;
    bdo <= reverse_byte(data_out_mux);
    -- v2: the tag is trunc64 of the final result, held in A0 after the final permutation
    tag_mux <= r(0)(63 downto 32) when data_count = 1 else r(0)(31 downto 0);
    data_out_mux <= data_bdo when bdo_sel ='0' else tag_mux;

end behavioral;
