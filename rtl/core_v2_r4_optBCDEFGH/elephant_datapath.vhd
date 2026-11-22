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
-- optBCDEFGH datapath: as optBCDEFG, but new calls go into stage 0 of a ring only, so they all finish
-- in the ring's last stage after exactly PERM_CYCLES cycles (PERM_CYCLES mod NSTAGE = 0):
--  * Only stage-0 registers have a load mux (xr / ring); the other stages take the previous stage's
--    output directly.
--  * The result comes from the last stage of ring res_u (an NUNIT:1 mux; none for one ring).
--  * Calls finish in the order they were loaded, a fixed PERM_CYCLES later, so each call's mask goes
--    into a PERM_CYCLES-deep delay line (shift register, mapped to SRLs) instead of an indexed store.
--
-- optBCDEFG datapath: NUNIT rings of NSTAGE stage registers (r), each register carrying its own
-- staggered call, as optBCDE but with any number of rings and stages, and three timing changes:
--  * Load: x = src xor mask is registered (xr, and the mask in mr) one cycle before it goes into the
--    stage register b_ld selects. The load mux in front of each stage register is then xr / pout only.
--  * Round constants come in registered per stage register (rc), not looked up from a round counter.
--  * Result: res <= pout(res_i) with a binary index (one wide mux), res_mask <= mst(res_mi); the next
--    cycle u = res xor res_mask goes to the key, the tag, or the keystream FIFO.
--  * Keystream FIFO: the head kh shifts one word right per message word (ks_adv), so the outgoing word
--    is always kh(31:0) (no data_count mux before bdo). The rest of the FIFO is a circular store.
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

        iss_kind: in std_logic_vector(2 downto 0);       -- call being prepared (into xr / mr)
        iss_buf: in std_logic;                           -- its input buffer
        b_ld: in std_logic_vector(NUNIT-1 downto 0);      -- ring whose stage 0 takes xr
        rc: in rc_arr;                                   -- round constants of each register's call

        res_en: in std_logic;                            -- a call finishes this cycle
        res_u: in integer range 0 to NUNIT-1;            -- in the last stage of this ring

        key_en: in std_logic;                            -- key_out <= u
        tag_en: in std_logic;
        tag_sel: in std_logic_vector(1 downto 0);        -- 00 clear, 01 <= ib(0), 10 ^= u, 11 <= u
        ks_push: in std_logic;                           -- keystream FIFO <= u
        ks_pop: in std_logic;                            -- drop the head (its block is done)
        ks_adv: in std_logic;                            -- a message word used the head's low word
        ks_cnt: in integer range 0 to NKS;
        ks_clr: in std_logic;
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
    type sto_arr is array (0 to NKS-2) of blk_t;
    type mdl_arr is array (0 to PERM_CYCLES-1) of blk_t;
    signal r, pout: slot_arr;
    signal md: mdl_arr;                                  -- mask delay line: md(j) = mask loaded j+1 cycles ago
    signal ib: buf_arr;
    signal kh: blk_t;                                    -- keystream FIFO head (shifted per word)
    signal sto: sto_arr;                                 -- the rest of the FIFO
    signal rd, wr: integer range 0 to NKS-2;
    constant ZERO: blk_t := (others => '0');

    constant MW: integer := STATE_SIZE + 8*(MAC_MASKS-1);
    constant KW: integer := STATE_SIZE + 8*(KS_MASKS-1);
    signal mac_win: std_logic_vector(MW-1 downto 0);
    signal ks_win: std_logic_vector(KW-1 downto 0);
    signal wm0, wm2, wk0, wk1: blk_t;

    signal srcv, maskv, x, ib_cur: blk_t;
    signal xr, mr: blk_t;
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

    signal data_out_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal tag_mux: std_logic_vector(CCW_SIZE-1 downto 0);

    function inc(p: integer) return integer is
    begin
        if p = NKS-2 then return 0; else return p + 1; end if;
    end function;
begin
    assert NKS >= 2 report "optBCDEFG: NKS must be at least 2" severity failure;
    assert PERM_CYCLES >= 3 report "optBCDEFGH: a call must take at least 3 cycles" severity failure;
    assert PERM_CYCLES mod NSTAGE = 0
        report "optBCDEFGH: a call loaded in stage 0 must finish in the last stage" severity failure;

    gen_perm: for s in 0 to NSLOT-1 generate
        P: entity work.elephant_perm
            port map(input => r(s), rc => rc(s), output => pout(s));
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

    -- new call: source and mask, registered
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

    p_x: process(clk)
    begin
        if rising_edge(clk) then
            xr <= x;
            mr <= maskv;
        end if;
    end process;

    -- stage registers: the ring moves every call one stage; a new call can replace the one leaving the
    -- last stage, in stage 0 only
    p_slots: process(clk)
    begin
        if rising_edge(clk) then
            for p in 0 to NSLOT-1 loop
                if p mod NSTAGE = 0 and b_ld(p / NSTAGE) = '1' then
                    r(p) <= xr;
                else
                    r(p) <= pout(prv(p));
                end if;
            end loop;
        end if;
    end process;

    -- mask delay line (no reset, no enable: SRLs) and the finished call (result + its mask). A call
    -- loaded at the end of cycle t finishes in cycle t+PERM_CYCLES, when its mask is in md(PERM_CYCLES-1).
    p_res: process(clk)
    begin
        if rising_edge(clk) then
            md(0) <= mr;
            for j in 1 to PERM_CYCLES-1 loop
                md(j) <= md(j-1);
            end loop;
            res_mask <= md(PERM_CYCLES-1);
            if res_en = '1' then
                res <= pout(res_u * NSTAGE + NSTAGE - 1);
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

    -- keystream FIFO: head kh plus a circular store of NKS-1; ks_cnt counts all entries. Every push
    -- writes the store (write enable = ks_push only, independent of the loader's pop); when the pushed
    -- keystream goes straight into an empty head, rd skips its copy.
    p_ks: process(clk)
    begin
        if rising_edge(clk) then
            if ks_push = '1' then
                sto(wr) <= u;
                wr <= inc(wr);
            end if;
            if ks_push = '1' and ((ks_pop = '1' and ks_cnt = 1) or (ks_pop = '0' and ks_cnt = 0)) then
                kh <= u;
                rd <= inc(rd);
            elsif ks_pop = '1' and ks_cnt >= 2 then
                kh <= sto(rd);
                rd <= inc(rd);
            elsif ks_pop = '0' and ks_adv = '1' then
                kh <= x"00000000" & kh(STATE_SIZE-1 downto CCW_SIZE);
            end if;
            if ks_clr = '1' then
                rd <= 0;
                wr <= 0;
            end if;
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

    data_bdo <= bdi_or_key_rev xor kh(CCW_SIZE-1 downto 0);
    bdo <= reverse_byte(data_out_mux);
    -- v2: the tag is trunc64 of the final result
    tag_mux <= tag_out(63 downto 32) when data_count = 1 else tag_out(31 downto 0);
    data_out_mux <= data_bdo when bdo_sel ='0' else tag_mux;

end behavioral;
