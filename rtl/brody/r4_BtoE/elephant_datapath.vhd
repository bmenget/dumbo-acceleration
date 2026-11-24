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
-- BtoE datapath: four stage registers in two 2-stage rings (as BtoD), but calls are staggered.
--  r(0) <-> r(1) and r(2) <-> r(3) swap through their 4-round stages every cycle. Each register carries
--  its own call with its own round-group index pc(p), so the four calls can be at different rounds.
--  * Load: at most one call per cycle. x = src xor mask (chosen by iss_kind) goes into the register
--    iss_ld selects, replacing whatever the ring would have moved there (a free or finished call).
--  * Masks: each call's mask is kept in a mask store (one entry per call position, m_we) for unmasking.
--  * Result: when a call finishes, its stage output and stored mask are registered (res, res_mask);
--    the next cycle u = res xor res_mask goes to the key, the tag, or the keystream FIFO.
--  Mask windows: wm = phi^m .. phi^(m+2) (AD / MAC), wk = phi^k, phi^(k+1) (keystream).
--
--  kind   src           mask
--  KEY    ib(iss_buf)   0
--  AD     ib(iss_buf)   wm0
--  MAC    ib(iss_buf)   wm0 xor wm2
--  KS     N || 0        wk0 xor wk1
--  FIN    tag           L
--------------------------------------------------------------------------------
entity elephant_datapath is
    port(
        key: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi_size: in std_logic_vector(1 downto 0);
        data_type_sel: std_logic;

        load_data_en: in std_logic;
        load_data_sel: in std_logic_vector(1 downto 0);
        load_buf: in std_logic;                          -- input buffer the loader writes

        iss_ld: in std_logic_vector(NSLOT-1 downto 0);    -- register that takes the new call
        iss_kind: in std_logic_vector(2 downto 0);
        iss_buf: in std_logic;                           -- input buffer of the new call
        m_we: in std_logic_vector(NSLOT-1 downto 0);      -- mask store entry of the new call
        pc: in pc_arr;                                   -- round group of each register's call

        res_en: in std_logic;                            -- a call finishes this cycle
        res_sel: in std_logic_vector(NSLOT-1 downto 0);   -- its register (one-hot)
        res_msel: in std_logic_vector(NSLOT-1 downto 0);  -- its mask store entry (one-hot)

        key_en: in std_logic;                            -- key_out <= u
        tag_en: in std_logic;
        tag_sel: in std_logic_vector(1 downto 0);        -- 00 clear, 01 <= ib(0), 10 ^= u, 11 <= u
        ks_push: in std_logic;                           -- keystream FIFO <= u
        ks_pop: in std_logic;                            -- drop the head (its block is done)
        ks_cnt: in integer range 0 to NKS;
        npub_en: in std_logic;

        mac_load: in std_logic;
        mac_step: in std_logic;
        ks_load: in std_logic;
        ks_step: in std_logic;

        bdo: out std_logic_vector(CCW_SIZE-1 downto 0);
        bdo_sel: in std_logic;
        saving_bdo: in std_logic;
        data_count: in integer range 0 to BLOCK_SIZE+1;
        clk: in std_logic
    );
end elephant_datapath;

architecture behavioral of elephant_datapath is
    subtype blk_t is std_logic_vector(STATE_SIZE-1 downto 0);
    type slot_arr is array (0 to NSLOT-1) of blk_t;
    type buf_arr is array (0 to 1) of blk_t;
    type ks_arr is array (0 to NKS-1) of blk_t;
    signal r, pout, mst: slot_arr;
    signal ib: buf_arr;
    signal ks: ks_arr;
    constant ZERO: blk_t := (others => '0');

    constant MW: integer := STATE_SIZE + 8*(MAC_MASKS-1);
    constant KW: integer := STATE_SIZE + 8*(KS_MASKS-1);
    signal mac_win: std_logic_vector(MW-1 downto 0);
    signal ks_win: std_logic_vector(KW-1 downto 0);
    signal wm0, wm2, wk0, wk1: blk_t;

    signal srcv, maskv, x, ib_cur: blk_t;
    signal res, res_mask, u: blk_t;

    signal nonce_blk: blk_t;
    signal key_out: blk_t;
    signal npub_out: std_logic_vector(NPUB_SIZE_BITS-1 downto 0);
    signal tag_out: blk_t;

    signal bdi_or_key: std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_key_rev : std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal padding_bdi: std_logic_vector(CCW_SIZE-1 downto 0);
    signal load_data_input_mux: std_logic_vector(CCW_SIZE-1 downto 0);

    signal ms_out_mux2: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_out_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal tag_mux: std_logic_vector(CCW_SIZE-1 downto 0);

    -- the other register of the same ring
    function prt(p: integer) return integer is
    begin
        if p mod 2 = 0 then return p + 1; else return p - 1; end if;
    end function;
begin
    assert PERM_CYCLES mod 2 = 0
        report "BtoE: two-stage rings need an even PERM_CYCLES" severity failure;

    gen_perm: for s in 0 to NSLOT-1 generate
        P: entity work.elephant_perm
            port map(
                input => r(s),
                clk => clk,
                perm_count => pc(s),
                load_lfsr => '0',
                output => pout(s)
            );
    end generate;

    MAC_LFSR: entity work.elephant_mask_lfsr
        generic map(NM => MAC_MASKS)
        port map(clk => clk, load => mac_load, step => mac_step, key_in => key_out, win => mac_win);
    KS_LFSR: entity work.elephant_mask_lfsr
        generic map(NM => KS_MASKS)
        port map(clk => clk, load => ks_load, step => ks_step, key_in => key_out, win => ks_win);
    wm0 <= mac_win(STATE_SIZE-1 downto 0);
    wm2 <= mac_win(16 + STATE_SIZE-1 downto 16);
    wk0 <= ks_win(STATE_SIZE-1 downto 0);
    wk1 <= ks_win(8 + STATE_SIZE-1 downto 8);

    -- new call: source and mask
    nonce_blk <= x"0000000000000000" & npub_out;
    ib_cur <= ib(1) when iss_buf = '1' else ib(0);
    srcv <= tag_out   when iss_kind = K_FIN else
            nonce_blk when iss_kind = K_KS else
            ib_cur;
    maskv <= wm0             when iss_kind = K_AD else
             wm0 xor wm2     when iss_kind = K_MAC else
             wk0 xor wk1     when iss_kind = K_KS else
             key_out         when iss_kind = K_FIN else
             ZERO;
    x <= srcv xor maskv;

    -- stage registers: the ring moves every call one stage, unless a new call replaces it
    p_slots: process(clk)
    begin
        if rising_edge(clk) then
            for p in 0 to NSLOT-1 loop
                if iss_ld(p) = '1' then
                    r(p) <= x;
                else
                    r(p) <= pout(prt(p));
                end if;
            end loop;
        end if;
    end process;

    -- mask store, finished call (result + its mask)
    p_res: process(clk)
        variable a, b: blk_t;
    begin
        if rising_edge(clk) then
            for e in 0 to NSLOT-1 loop
                if m_we(e) = '1' then
                    mst(e) <= maskv;
                end if;
            end loop;
            if res_en = '1' then
                a := ZERO;
                b := ZERO;
                for p in 0 to NSLOT-1 loop
                    if res_sel(p) = '1' then a := a or pout(p); end if;
                    if res_msel(p) = '1' then b := b or mst(p); end if;
                end loop;
                res <= a;
                res_mask <= b;
            end if;
        end if;
    end process;
    u <= res xor res_mask;

    p_key_reg: process(clk)
    begin
        if rising_edge(clk) then
            if key_en = '1' then
                key_out <= u;
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
                case tag_sel is
                    when "00"   => tag_out <= (others => '0');
                    when "01"   => tag_out <= ib(0);            -- v2: N||AD0 initializes the tag
                    when "10"   => tag_out <= tag_out xor u;    -- AD / MAC result
                    when others => tag_out <= u;                -- final: P(S xor L) xor L
                end case;
            end if;
        end if;
    end process;

    -- keystream FIFO, head in ks(0)
    p_ks: process(clk)
    begin
        if rising_edge(clk) then
            for i in 0 to NKS-1 loop
                if ks_pop = '1' then
                    if ks_push = '1' and i = ks_cnt-1 then
                        ks(i) <= u;
                    elsif i < NKS-1 then
                        ks(i) <= ks(i+1);
                    end if;
                elsif ks_push = '1' and i = ks_cnt then
                    ks(i) <= u;
                end if;
            end loop;
        end if;
    end process;

    -- input block buffers (word shift registers)
    p_load_data: process(clk)
    begin
        if rising_edge(clk) then
            if load_data_en = '1' then
                if load_buf = '0' then
                    ib(0) <= load_data_input_mux & ib(0)(STATE_SIZE-1 downto CCW_SIZE);
                else
                    ib(1) <= load_data_input_mux & ib(1)(STATE_SIZE-1 downto CCW_SIZE);
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

    with data_count select
        ms_out_mux2 <= ks(0)(CCW-1 downto 0) when 0,
                       ks(0)((2*CCW)-1 downto CCW) when 1,
                       ks(0)((3*CCW)-1 downto 2*CCW) when 2,
                       ks(0)((4*CCW)-1 downto 3*CCW) when 3,
                       ks(0)((5*CCW)-1 downto 4*CCW) when others;
    data_bdo <= bdi_or_key_rev xor ms_out_mux2;
    bdo <= reverse_byte(data_out_mux);
    -- v2: the tag is trunc64 of the final result
    tag_mux <= tag_out(63 downto 32) when data_count = 1 else tag_out(31 downto 0);
    data_out_mux <= data_bdo when bdo_sel ='0' else tag_mux;

end behavioral;
