--------------------------------------------------------------------------------
--! @file       CryptoCore.vhd
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
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_misc.all;
use work.NIST_LWAPI_pkg.all;
use work.Design_pkg.all;
use work.elephant_constants.all;

entity CryptoCore is
    Port (
        clk             : in   STD_LOGIC;
        rst             : in   STD_LOGIC;
        --PreProcessor===============================================
        ----!key----------------------------------------------------
        key             : in   STD_LOGIC_VECTOR (CCSW     -1 downto 0);
        key_valid       : in   STD_LOGIC;
        key_ready       : out  STD_LOGIC;
        ----!Data----------------------------------------------------
        bdi             : in   STD_LOGIC_VECTOR (CCW     -1 downto 0);
        bdi_valid       : in   STD_LOGIC;
        bdi_ready       : out  STD_LOGIC;
        bdi_pad_loc     : in   STD_LOGIC_VECTOR (CCWdiv8 -1 downto 0);
        bdi_valid_bytes : in   STD_LOGIC_VECTOR (CCWdiv8 -1 downto 0);
        bdi_size        : in   STD_LOGIC_VECTOR (3       -1 downto 0);
        bdi_eot         : in   STD_LOGIC;
        bdi_eoi         : in   STD_LOGIC;
        bdi_type        : in   STD_LOGIC_VECTOR (4       -1 downto 0);
        decrypt_in      : in   STD_LOGIC;
        key_update      : in   STD_LOGIC;
        hash_in         : in   std_logic;
        --!Post Processor=========================================
        bdo             : out  STD_LOGIC_VECTOR (CCW      -1 downto 0);
        bdo_valid       : out  STD_LOGIC;
        bdo_ready       : in   STD_LOGIC;
        bdo_type        : out  STD_LOGIC_VECTOR (4       -1 downto 0);
        bdo_valid_bytes : out  STD_LOGIC_VECTOR (CCWdiv8 -1 downto 0);
        end_of_block    : out  STD_LOGIC;
        msg_auth_valid  : out  STD_LOGIC;
        msg_auth_ready  : in   STD_LOGIC;
        msg_auth        : out  STD_LOGIC
    );
end CryptoCore;


--------------------------------------------------------------------------------
-- option B: I/O overlapped with the permutation (see rtl/ACCELERATION.md, option B,
-- and rtl/brody/r4_B/README.md).
--
-- Two cooperating parts in one process:
--  * the block filler ("loader"): accepts bdi words into load_data_output, pads,
--    tracks done_state/append_one and, for the message, drives bdo from ks_reg.
--    It runs whenever fill_active = '1' and data_cnt_int < BLOCK_SIZE, regardless
--    of the main state, so it can work while the permutation runs.
--    The block is complete when data_cnt_int = BLOCK_SIZE (blk_full).
--  * the main FSM (ctl_s): schedules permutations and consumes full blocks.
--
-- Schedule (window position a: prev = phi^(a-1), cur = phi^a, next = phi^(a+1)):
--  AD block 0 (N||AD0): tag <= block, no permutation; LFSR loaded and stepped to a = 2.
--  AD block j >= 1:     PERM(block xor prev) while block j+1 fills; tag ^= result; step.
--  Message, LFSR reloaded to a = 0:
--     KS(0)             PERM(N xor cur xor next) -> ks_reg; step to a = 1; block 0 streams.
--     block k filled, more data (no eot yet), window a = k+1:
--        KS(k+1)        PERM(N xor cur xor next) -> ks_reg
--        MAC(k)         PERM(C_k xor prev xor next) while block k+1 streams from ks_reg;
--                       tag ^= result; step to a = k+2
--     last block filled: MAC(k) (plus a padding-only MAC block if the message ended on a
--                        block boundary, filled while MAC(k) runs)
--  Final: PERM(tag xor L) xor L -> ms_reg, tag = low 64 bits.
--------------------------------------------------------------------------------
architecture behavioral of CryptoCore is
    --internal signals for datapath
    signal bdo_s: std_logic_vector(CCW - 1 downto 0);
    signal bdo_sel: std_logic;
    signal saving_bdo: std_logic;
    signal bdi_size_intern: std_logic_vector(1 downto 0);
    signal data_type_sel: std_logic;

    signal load_data_en: std_logic;
    signal load_data_sel: std_logic_vector(1 downto 0);
    signal src_sel: std_logic_vector(1 downto 0);
    signal mask_sel: std_logic_vector(2 downto 0);
    signal ks_en: std_logic;
    signal key_en: std_logic;
    signal npub_en: std_logic;
    signal tag_en: std_logic;
    signal tag_reset: std_logic;

    signal ms_en: std_logic;

    --Signals for permutation
    signal load_lfsr:std_logic;
    signal perm_en: std_logic;

    --Signals for datapath lsfr
    signal datap_lfsr_load: std_logic;
    signal datap_lfsr_en: std_logic;

    --Signals for data counter
    signal n_data_cnt_int, data_cnt_int :integer range 0 to BLOCK_SIZE+1;
    signal perm_cnt_int, n_perm_cnt_int: integer range 0 to PERM_CYCLES;
    signal aux_cnt, n_aux_cnt: integer range 0 to 4;   -- LFSR init / reload sequencing

    -- src_sel / mask_sel codes (see elephant_datapath.vhd)
    constant SRC_MS    : std_logic_vector(1 downto 0) := "00";
    constant SRC_BLK   : std_logic_vector(1 downto 0) := "01";
    constant SRC_NONCE : std_logic_vector(1 downto 0) := "10";
    constant SRC_TAG   : std_logic_vector(1 downto 0) := "11";
    constant M_NONE      : std_logic_vector(2 downto 0) := "000";
    constant M_PREV      : std_logic_vector(2 downto 0) := "001";
    constant M_PREV_NEXT : std_logic_vector(2 downto 0) := "010";
    constant M_CUR_NEXT  : std_logic_vector(2 downto 0) := "011";
    constant M_KEY       : std_logic_vector(2 downto 0) := "100";

    type ctl_state is (IDLE, STORE_KEY, PERM_KEY, LOAD_KEY,
                       AD_INIT, AD_WAIT, MSG_LFSR, MSG_WAIT,
                       PERM, POST, FINAL_PRE, TAG_S);
    signal n_ctl_s, ctl_s: ctl_state;
    -- what the running permutation is for (decides POST)
    type job_t is (J_AD, J_KS, J_MAC, J_FINAL);
    signal job, n_job: job_t;

    signal fill_active, n_fill_active: std_logic;  -- loader owns data_cnt_int / load_data
    signal fill_msg, n_fill_msg: std_logic;        -- '0' AD block, '1' message block
    signal blk_full: std_logic;
    signal ks_first, n_ks_first: std_logic;        -- next keystream permutation is KS(0)

    signal done_state, n_done_state: std_logic;
    signal append_one, n_append_one: std_logic;
    signal first_blk, n_first_blk: std_logic;  -- v2: first AD block (N||AD0) is not permuted
    signal decrypt_op, n_decrypt_op: std_logic;
    signal n_tag_verified, tag_verified :std_logic;

begin
    ELEPHANT_DATAP: entity work.elephant_datapath
        port map(
            key        => key,
            bdi        => bdi,
            bdi_size => bdi_size_intern,
            data_type_sel => data_type_sel,

            load_data_en  => load_data_en,
            load_data_sel => load_data_sel,
            src_sel => src_sel,
            mask_sel => mask_sel,
            ks_en => ks_en,
            key_en => key_en,
            npub_en => npub_en,
            tag_en => tag_en,
            tag_reset => tag_reset,
            ms_en => ms_en,

            perm_en => perm_en,
            load_lfsr  => load_lfsr,

            datap_lfsr_load => datap_lfsr_load,
            datap_lfsr_en => datap_lfsr_en,

            bdo => bdo_s,
            bdo_sel => bdo_sel,
            saving_bdo => saving_bdo,
            data_count => data_cnt_int,
            perm_count => perm_cnt_int,
            clk        => clk
        );

    -- Round-constant LFSR inside elephant_perm (used only when PERM_ROUNDS_PER_CYCLE = 1):
    -- held in reset whenever no round is computed.
    load_lfsr <= not perm_en;
    blk_full <= '1' when fill_active = '1' and data_cnt_int = BLOCK_SIZE else '0';

state_control: process(all)
begin
    bdo_valid <= '0';
    bdo_valid_bytes <= bdi_valid_bytes;
    bdo_type <=(others => '0');
    bdo_sel <= '0';
    saving_bdo <= '0';
    msg_auth <= '0';
    msg_auth_valid <= '0';
    end_of_block <= '0';

    key_ready <= '0';
    bdi_ready <= '0';
    bdi_size_intern <= bdi_size(1 downto 0);
    bdo <= bdo_s;
    data_type_sel <= '0';

    load_data_en <= '0';
    load_data_sel <= "00";
    src_sel <= SRC_BLK;
    mask_sel <= M_NONE;
    ks_en <= '0';
    key_en <= '0';
    npub_en <= '0';
    tag_reset <= '0';
    tag_en <= '0';
    ms_en <= '0';

    perm_en <= '0';
    datap_lfsr_load <= '0';
    datap_lfsr_en <= '0';

    n_ctl_s <= ctl_s;
    n_job <= job;
    n_fill_active <= fill_active;
    n_fill_msg <= fill_msg;
    n_ks_first <= ks_first;
    n_done_state <= done_state;
    n_append_one <= append_one;
    n_first_blk <= first_blk;
    n_decrypt_op <= decrypt_op;
    n_tag_verified <= tag_verified;
    n_perm_cnt_int <= 0;
    n_aux_cnt <= aux_cnt;
    n_data_cnt_int <= data_cnt_int;

    ----------------------------------------------------------------------------
    -- Main FSM. It touches data_cnt_int / load_data / bdi only while the loader
    -- is idle (fill_active = '0') or holding a full block (blk_full = '1').
    ----------------------------------------------------------------------------
    case ctl_s is
    when IDLE =>
        n_tag_verified <= '1';
        tag_reset <= '1';
        tag_en <= '1';
        n_data_cnt_int <= 0;
        n_done_state <= '0';
        n_append_one <= '0';
        n_first_blk <= '1';
        n_fill_active <= '0';
        n_ks_first <= '1';
        n_aux_cnt <= 0;
        if bdi_valid = '1' or key_valid = '1' then
            if key_update = '1' then
                n_ctl_s <= STORE_KEY;
            else
                n_ctl_s <= LOAD_KEY;
            end if;
        end if;
    when STORE_KEY =>
        if data_cnt_int <= BLOCK_SIZE then
            if data_cnt_int < KEY_SIZE then
                if key_valid = '1' then
                    n_data_cnt_int <= data_cnt_int + 1;
                    key_ready <= '1';
                    load_data_en <= '1';
                    data_type_sel <= '1'; --select key type
                    load_data_sel <= "01";
                end if;
            else
                n_data_cnt_int <= data_cnt_int + 1;
                if data_cnt_int <= KEY_SIZE then
                    load_data_sel <= "00"; --zero pad
                    load_data_en <= '1';
                else
                    ms_en <= '1';          -- ms <= K || 0 (SRC_BLK, no mask)
                end if;
            end if;
        else
            n_ctl_s <= PERM_KEY;
            n_data_cnt_int <= 0;
            load_data_en <= '1'; -- clear input data reg
            load_data_sel <= "11";
        end if;
    when PERM_KEY =>
        if perm_cnt_int < PERM_CYCLES then
            perm_en <= '1';
            n_perm_cnt_int <= perm_cnt_int + 1;
            ms_en <= '1';
            if perm_cnt_int = PERM_CYCLES-1 then
                --Save the perm key
                key_en <= '1';
                if data_cnt_int = ELE_NPUB_SIZE then
                    -- nonce complete and captured (npub_en below): first AD block continues at word 3
                    n_ctl_s <= AD_INIT;
                    n_fill_active <= '1';
                    n_fill_msg <= '0';
                    n_aux_cnt <= 0;
                else
                    n_ctl_s <= LOAD_KEY;   -- finish loading the nonce
                end if;
            end if;
        end if;
        --Obtain NPUB
        if data_cnt_int < ELE_NPUB_SIZE then
            if bdi_valid = '1' then
                n_decrypt_op <= decrypt_in;
                bdi_ready <= '1';
                n_data_cnt_int <= data_cnt_int + 1;
                load_data_en <= '1';
                load_data_sel <= "01";
            end if;
        --Store npub and then shift it all the way to beginning of the register
        elsif data_cnt_int = ELE_NPUB_SIZE then
            npub_en <= '1';
        end if;
    when LOAD_KEY =>
        --Obtain NPUB
        if data_cnt_int < ELE_NPUB_SIZE then
            if bdi_valid = '1' then
                n_data_cnt_int <= data_cnt_int + 1;
                n_decrypt_op <= decrypt_in;
                bdi_ready <= '1';
                load_data_en <= '1';
                load_data_sel <= "01";
            end if;
        --Store npub and then shift it all the way to beginning of the register
        elsif data_cnt_int = ELE_NPUB_SIZE then
            npub_en <= '1';
            n_ctl_s <= AD_INIT;
            n_fill_active <= '1';   -- loader fills N||AD0 from word 3
            n_fill_msg <= '0';
            n_aux_cnt <= 0;
        end if;

    when AD_INIT =>
        -- While the loader fills N||AD0: load the mask LFSR with L and step it 3 times (a = 2,
        -- the window AD block 1 needs). key_out is valid here in both the new-key and reuse paths.
        if aux_cnt < 4 then
            datap_lfsr_en <= '1';
            if aux_cnt = 0 then
                datap_lfsr_load <= '1';
            end if;
            n_aux_cnt <= aux_cnt + 1;
        elsif blk_full = '1' then
            -- v2: N||AD0 is not permuted; it initializes the tag (tag is 0 here)
            tag_en <= '1';
            src_sel <= SRC_BLK;
            mask_sel <= M_NONE;
            n_first_blk <= '0';
            if done_state = '0' or append_one = '1' then
                n_data_cnt_int <= 0;        -- fill AD block 1
                n_ctl_s <= AD_WAIT;
            else
                n_fill_active <= '0';
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        end if;

    when AD_WAIT =>
        -- AD block j (>= 1) is full: permute it, and fill block j+1 meanwhile if there is one
        if blk_full = '1' then
            ms_en <= '1';
            src_sel <= SRC_BLK;
            mask_sel <= M_PREV;             -- phi^j
            n_job <= J_AD;
            n_ctl_s <= PERM;
            if done_state = '0' or append_one = '1' then
                n_data_cnt_int <= 0;
            else
                n_fill_active <= '0';
            end if;
        end if;

    when MSG_LFSR =>
        -- Reload the mask LFSR with L for the message and step once (a = 0), then start KS(0).
        n_done_state <= '0';
        n_append_one <= '0';
        if aux_cnt < 2 then
            datap_lfsr_en <= '1';
            if aux_cnt = 0 then
                datap_lfsr_load <= '1';
            end if;
            n_aux_cnt <= aux_cnt + 1;
        else
            ms_en <= '1';
            src_sel <= SRC_NONCE;
            mask_sel <= M_CUR_NEXT;         -- phi^0 xor phi^1
            n_job <= J_KS;
            n_ctl_s <= PERM;
        end if;

    when MSG_WAIT =>
        -- message block k is full (window a = k+1)
        if blk_full = '1' then
            ms_en <= '1';
            n_ctl_s <= PERM;
            if done_state = '0' then
                -- more message follows: keystream for block k+1 first, MAC(k) after it
                src_sel <= SRC_NONCE;
                mask_sel <= M_CUR_NEXT;     -- phi^(k+1) xor phi^(k+2)
                n_job <= J_KS;
            else
                -- last data block: MAC(k) now; a padding-only block follows if the
                -- message ended on a block boundary (filled while MAC(k) runs)
                src_sel <= SRC_BLK;
                mask_sel <= M_PREV_NEXT;    -- phi^k xor phi^(k+2)
                n_job <= J_MAC;
                if append_one = '1' then
                    n_data_cnt_int <= 0;
                else
                    n_fill_active <= '0';
                end if;
            end if;
        end if;

    when FINAL_PRE =>
        ms_en <= '1';
        src_sel <= SRC_TAG;
        mask_sel <= M_KEY;                  -- S xor L
        n_job <= J_FINAL;
        n_ctl_s <= PERM;

    when PERM =>
        if perm_cnt_int < PERM_CYCLES then
            perm_en <= '1';
            n_perm_cnt_int <= perm_cnt_int + 1;
            ms_en <= '1';
            if perm_cnt_int = PERM_CYCLES-1 then
                n_ctl_s <= POST;
            end if;
        end if;

    when POST =>
        case job is
        when J_AD =>
            tag_en <= '1';
            src_sel <= SRC_MS;
            mask_sel <= M_PREV;             -- tag ^= P(A_j xor phi^j) xor phi^j
            datap_lfsr_en <= '1';
            if fill_active = '1' then
                n_ctl_s <= AD_WAIT;
            else
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        when J_KS =>
            ks_en <= '1';                   -- ks_reg <= P(..) xor cur xor next
            if ks_first = '1' then
                n_ks_first <= '0';
                datap_lfsr_en <= '1';       -- a = 0 -> 1
                n_fill_active <= '1';
                n_fill_msg <= '1';
                n_data_cnt_int <= 0;
                if not (bdi_type = HDR_PT or bdi_type = HDR_CT) then
                    -- empty PT/CT: only the padding block 0x01 00.. is MACed
                    n_done_state <= '1';
                    n_append_one <= '1';
                end if;
                n_ctl_s <= MSG_WAIT;
            else
                -- KS(k+1) done; start MAC(k) on the full block and let block k+1 stream meanwhile
                ms_en <= '1';
                src_sel <= SRC_BLK;
                mask_sel <= M_PREV_NEXT;    -- phi^k xor phi^(k+2)
                n_data_cnt_int <= 0;
                n_job <= J_MAC;
                n_ctl_s <= PERM;
            end if;
        when J_MAC =>
            tag_en <= '1';
            src_sel <= SRC_MS;
            mask_sel <= M_PREV_NEXT;
            datap_lfsr_en <= '1';
            if fill_active = '1' then
                n_ctl_s <= MSG_WAIT;
            else
                n_ctl_s <= FINAL_PRE;
            end if;
        when J_FINAL =>
            -- T = trunc64(P(S xor L) xor L), read from ms_reg in TAG_S
            ms_en <= '1';
            src_sel <= SRC_MS;
            mask_sel <= M_KEY;
            n_data_cnt_int <= 0;
            n_ctl_s <= TAG_S;
        end case;

    when TAG_S =>
        bdo_sel <= '1';
        if decrypt_op /= '1' then
            bdo_valid_bytes <= (others => '1');
            bdo_type <= HDR_TAG;
            if bdo_ready = '1' then
                bdo_valid <= '1';
                n_data_cnt_int <= data_cnt_int + 1;
                if data_cnt_int = ELE_TAG_SIZE-1 then
                    end_of_block <= '1';
                    n_ctl_s <= IDLE;
                end if;
            end if;
        else
            if bdi_valid = '1' and msg_auth_ready = '1' then
                bdi_ready <= '1';
                n_data_cnt_int <= data_cnt_int + 1;
                if data_cnt_int = ELE_TAG_SIZE-1 then
                    n_ctl_s <= IDLE;
                    msg_auth_valid <= '1';
                    if (bdi /= bdo_s) then
                        msg_auth <= '0';
                    else
                        msg_auth <= tag_verified;
                    end if;
                else
                    if bdi /= bdo_s then
                        n_tag_verified <= '0';
                    end if;
                end if;
            end if;
        end if;
    end case;

    ----------------------------------------------------------------------------
    -- Loader: fills one 20-byte block word by word, in any main state.
    ----------------------------------------------------------------------------
    if fill_active = '1' and data_cnt_int < BLOCK_SIZE then
        if fill_msg = '0' then
            -- AD. Block 0 decides "no (more) AD" from bdi_type, as in brody/base_r10; later blocks only
            -- end on the eot flags, so a header cycle between AD segments cannot end the AD early.
            if done_state /= '1' and append_one /= '1' and (first_blk = '0' or bdi_type = HDR_AD) then
                if bdi_valid = '1' and bdi_type = HDR_AD then
                    bdi_ready <= '1';
                    n_data_cnt_int <= data_cnt_int + 1;
                    load_data_en <= '1';
                    if bdi_valid_bytes = "1111" then
                        load_data_sel <= "01";
                    else
                        load_data_sel <= "10";
                    end if;
                    if bdi_eot = '1' then
                        if (data_cnt_int = BLOCK_SIZE-1 and bdi_valid_bytes = "1111") = False then
                            n_done_state <= '1';
                        end if;
                        if bdi_valid_bytes = "1111" then
                            n_append_one <= '1';
                        end if;
                    end if;
                end if;
            else
                n_data_cnt_int <= data_cnt_int + 1;
                load_data_en <= '1';
                if append_one = '1' or done_state = '0' then
                    load_data_sel <= "10";      -- 0x01 padding byte
                    bdi_size_intern <= "00";
                    n_append_one <= '0';
                    n_done_state <= '1';
                else
                    load_data_sel <= "00";      -- zero pad
                end if;
            end if;
        else
            -- Message: out word = in word xor ks_reg slice; the block register keeps the ciphertext
            if done_state /= '1' and append_one /= '1' then
                if bdi_valid = '1' and bdo_ready = '1' and (bdi_type = HDR_PT or bdi_type = HDR_CT) then
                    bdi_ready <= '1';
                    bdo_valid_bytes <= bdi_valid_bytes;
                    bdo_valid <= '1';
                    n_data_cnt_int <= data_cnt_int + 1;
                    load_data_en <= '1';
                    if bdi_valid_bytes = "1111" then
                        load_data_sel <= "01";
                    else
                        load_data_sel <= "10";
                    end if;
                    if bdi_type = HDR_PT then
                        bdo_type <= HDR_CT;
                        saving_bdo <= '1';
                    else
                        bdo_type <= HDR_PT;
                    end if;
                    if bdi_eot = '1' then
                        n_done_state <= '1';
                        if bdi_valid_bytes = "1111" then
                            n_append_one <= '1';
                        end if;
                    end if;
                end if;
            else
                n_data_cnt_int <= data_cnt_int + 1;
                load_data_en <= '1';
                if append_one = '1' then
                    load_data_sel <= "10";      -- 0x01 padding byte
                    bdi_size_intern <= "00";
                    n_append_one <= '0';
                    n_done_state <= '1';
                else
                    load_data_sel <= "00";      -- zero pad
                end if;
            end if;
        end if;
    end if;

end process;

p_reg: process(clk)
begin
    if rising_edge(clk) then
        perm_cnt_int <= n_perm_cnt_int;
        data_cnt_int <= n_data_cnt_int;
        aux_cnt <= n_aux_cnt;
        job <= n_job;
        if rst = '1' then
            ctl_s <= IDLE;
            done_state <= '0';
            decrypt_op <= '0';
            tag_verified <= '0';
            append_one <= '0';
            first_blk <= '1';
            fill_active <= '0';
            fill_msg <= '0';
            ks_first <= '1';
        else
            ctl_s <= n_ctl_s;
            done_state <= n_done_state;
            decrypt_op <= n_decrypt_op;
            tag_verified <= n_tag_verified;
            append_one <= n_append_one;
            first_blk <= n_first_blk;
            fill_active <= n_fill_active;
            fill_msg <= n_fill_msg;
            ks_first <= n_ks_first;
        end if;
    end if;
end process;
end behavioral;
