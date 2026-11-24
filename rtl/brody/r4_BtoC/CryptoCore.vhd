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
-- BtoC: options B + C of rtl/ACCELERATION.md (see rtl/brody/r4_BtoC/README.md).
-- B: I/O overlapped with the permutation. C: two permutation units in lockstep
-- (unit A: ms_reg, unit B: msb_reg in elephant_datapath).
--
-- Two cooperating parts in one process, as in option B:
--  * the block filler ("loader"): accepts bdi words, pads, tracks done_state/append_one
--    and, for the message, drives bdo from ks_reg. It runs whenever fill_active = '1' and
--    data_cnt_int < BLOCK_SIZE. For AD blocks >= 1 it fills a PAIR: the first block into
--    load_data_output, then (if there is more AD) the second into load_data_output2.
--  * the main FSM (ctl_s): schedules permutations and consumes full blocks.
--
-- Mask window at position a: prev = phi^(a-1), cur = phi^a, next = phi^(a+1), next2 = phi^(a+2).
--  AD block 0 (N||AD0): tag <= block, no permutation; LFSR loaded and stepped to a = 0.
--  AD pair (j, j+1), j >= 1, set up at a = j-1:
--     A: P(A_j xor next)   B: P(A_{j+1} xor next2)   (a single last block uses A only)
--     the LFSR steps once during the permutation (a = j), so the unmask is
--     tag ^= (A xor cur) xor (B xor next); one more step (a = j+1) for the next pair.
--     The next pair fills meanwhile.
--  Message, LFSR reloaded to a = 0:
--     A: KS(0) = P(N xor cur xor next) -> ks_reg      B: KS(1) = P(N xor next xor next2), kept in msb_reg
--     step to a = 1; block 0 streams from ks_reg.
--     block k full, window a = k+1, msb_reg holds KS(k+1):
--        more data:  ks_reg <= KS(k+1);  A: MAC(k) = P(C_k xor prev xor next)
--                                        B: KS(k+2) = P(N xor next xor next2)
--                    block k+1 streams from ks_reg meanwhile
--        last block: A: MAC(k) only (plus a padding-only MAC block if the message ended on a
--                    block boundary, filled while MAC(k) runs)
--     tag ^= MAC result; step.
--  Final: P(tag xor L) xor L on unit A -> ms_reg, tag = low 64 bits.
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
    signal load_buf_sel: std_logic;
    signal src_sel: std_logic_vector(1 downto 0);
    signal mask_sel: std_logic_vector(2 downto 0);
    signal ks_en: std_logic;
    signal ks_sel: std_logic;
    signal srcb_sel: std_logic_vector(1 downto 0);
    signal maskb_sel: std_logic_vector(1 downto 0);
    signal msb_en: std_logic;
    signal tagb_en: std_logic;
    signal key_en: std_logic;
    signal npub_en: std_logic;
    signal tag_en: std_logic;
    signal tag_reset: std_logic;

    signal ms_en: std_logic;

    --Signals for permutation
    signal load_lfsr:std_logic;
    signal perm_en: std_logic;
    signal perm_b_en: std_logic;    -- busy probe for unit B (profile.txt)

    --Signals for datapath lsfr
    signal datap_lfsr_load: std_logic;
    signal datap_lfsr_en: std_logic;

    --Signals for data counter
    signal n_data_cnt_int, data_cnt_int :integer range 0 to BLOCK_SIZE+1;
    signal perm_cnt_int, n_perm_cnt_int: integer range 0 to PERM_CYCLES;
    signal aux_cnt, n_aux_cnt: integer range 0 to 4;   -- LFSR init / reload sequencing

    -- unit A src_sel / mask_sel codes (see elephant_datapath.vhd)
    constant SRC_MS    : std_logic_vector(1 downto 0) := "00";
    constant SRC_BLK   : std_logic_vector(1 downto 0) := "01";
    constant SRC_NONCE : std_logic_vector(1 downto 0) := "10";
    constant SRC_TAG   : std_logic_vector(1 downto 0) := "11";
    constant M_NONE      : std_logic_vector(2 downto 0) := "000";
    constant M_CUR       : std_logic_vector(2 downto 0) := "001";
    constant M_PREV_NEXT : std_logic_vector(2 downto 0) := "010";
    constant M_CUR_NEXT  : std_logic_vector(2 downto 0) := "011";
    constant M_KEY       : std_logic_vector(2 downto 0) := "100";
    constant M_NEXT      : std_logic_vector(2 downto 0) := "101";
    -- unit B srcb_sel / maskb_sel codes
    constant SB_MS    : std_logic_vector(1 downto 0) := "00";
    constant SB_BLK2  : std_logic_vector(1 downto 0) := "01";
    constant SB_NONCE : std_logic_vector(1 downto 0) := "10";
    constant MB_NEXT        : std_logic_vector(1 downto 0) := "00";
    constant MB_NEXT2       : std_logic_vector(1 downto 0) := "01";
    constant MB_NEXT_NEXT2  : std_logic_vector(1 downto 0) := "10";

    type ctl_state is (IDLE, STORE_KEY, PERM_KEY, LOAD_KEY,
                       AD_INIT, AD_WAIT, MSG_LFSR, MSG_WAIT,
                       PERM, POST, FINAL_PRE, TAG_S);
    signal n_ctl_s, ctl_s: ctl_state;
    -- what the running permutation is for (decides POST)
    type job_t is (J_AD, J_KS0, J_MAC, J_FINAL);
    signal job, n_job: job_t;
    signal b_active, n_b_active: std_logic;        -- unit B takes part in the running permutation

    signal fill_active, n_fill_active: std_logic;  -- loader owns data_cnt_int / load_data
    signal fill_msg, n_fill_msg: std_logic;        -- '0' AD block, '1' message block
    signal fill_b2, n_fill_b2: std_logic;          -- loader writes the second block buffer
    signal blk_full: std_logic;                    -- current block complete
    signal more_ad: std_logic;                     -- another AD block follows the current one
    signal ad_ready: std_logic;                    -- AD pair (or single last block) complete

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
            load_buf_sel => load_buf_sel,
            src_sel => src_sel,
            mask_sel => mask_sel,
            ks_en => ks_en,
            ks_sel => ks_sel,
            srcb_sel => srcb_sel,
            maskb_sel => maskb_sel,
            msb_en => msb_en,
            tagb_en => tagb_en,
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
    perm_b_en <= perm_en and b_active;
    blk_full <= '1' when fill_active = '1' and data_cnt_int = BLOCK_SIZE else '0';
    more_ad  <= '1' when done_state = '0' or append_one = '1' else '0';
    ad_ready <= '1' when blk_full = '1' and (fill_b2 = '1' or more_ad = '0') else '0';

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
    load_buf_sel <= '0';
    src_sel <= SRC_BLK;
    mask_sel <= M_NONE;
    ks_en <= '0';
    ks_sel <= '0';
    srcb_sel <= SB_MS;
    maskb_sel <= MB_NEXT;
    msb_en <= '0';
    tagb_en <= '0';
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
    n_b_active <= b_active;
    n_fill_active <= fill_active;
    n_fill_msg <= fill_msg;
    n_fill_b2 <= fill_b2;
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
    -- is idle (fill_active = '0') or holding a complete block.
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
        n_fill_b2 <= '0';
        n_b_active <= '0';
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
        -- unit A only (msb_en stays '0')
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
                    n_fill_b2 <= '0';
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
            n_fill_b2 <= '0';
            n_aux_cnt <= 0;
        end if;

    when AD_INIT =>
        -- While the loader fills N||AD0: load the mask LFSR with L (lands in next2, a = -2) and
        -- step it twice (a = 0), the window the first AD pair (1, 2) is set up with.
        if aux_cnt < 3 then
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
            if more_ad = '1' then
                n_data_cnt_int <= 0;        -- fill AD pair (1, 2)
                n_fill_b2 <= '0';
                n_ctl_s <= AD_WAIT;
            else
                n_fill_active <= '0';
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        end if;

    when AD_WAIT =>
        -- AD pair (j, j+1) or a single last block j is complete, window a = j-1
        if ad_ready = '1' then
            ms_en <= '1';
            src_sel <= SRC_BLK;
            mask_sel <= M_NEXT;             -- phi^j
            if fill_b2 = '1' then
                msb_en <= '1';
                srcb_sel <= SB_BLK2;
                maskb_sel <= MB_NEXT2;      -- phi^(j+1)
                n_b_active <= '1';
            else
                n_b_active <= '0';
            end if;
            n_job <= J_AD;
            n_ctl_s <= PERM;
            if more_ad = '1' then
                n_data_cnt_int <= 0;        -- fill the next pair meanwhile
                n_fill_b2 <= '0';
            else
                n_fill_active <= '0';
            end if;
        end if;

    when MSG_LFSR =>
        -- Reload the mask LFSR with L for the message and step twice (a = 0), then start
        -- KS(0) on unit A and KS(1) on unit B.
        n_done_state <= '0';
        n_append_one <= '0';
        if aux_cnt < 3 then
            datap_lfsr_en <= '1';
            if aux_cnt = 0 then
                datap_lfsr_load <= '1';
            end if;
            n_aux_cnt <= aux_cnt + 1;
        else
            ms_en <= '1';
            src_sel <= SRC_NONCE;
            mask_sel <= M_CUR_NEXT;         -- phi^0 xor phi^1
            msb_en <= '1';
            srcb_sel <= SB_NONCE;
            maskb_sel <= MB_NEXT_NEXT2;     -- phi^1 xor phi^2
            n_b_active <= '1';
            n_job <= J_KS0;
            n_ctl_s <= PERM;
        end if;

    when MSG_WAIT =>
        -- message block k is full (window a = k+1); msb_reg holds KS(k+1)
        if blk_full = '1' then
            ms_en <= '1';
            src_sel <= SRC_BLK;
            mask_sel <= M_PREV_NEXT;        -- MAC(k): phi^k xor phi^(k+2)
            n_job <= J_MAC;
            n_ctl_s <= PERM;
            if done_state = '0' then
                -- more message follows: block k+1 streams from KS(k+1) while
                -- unit B computes KS(k+2)
                ks_en <= '1';
                ks_sel <= '1';
                msb_en <= '1';
                srcb_sel <= SB_NONCE;
                maskb_sel <= MB_NEXT_NEXT2; -- phi^(k+2) xor phi^(k+3)
                n_b_active <= '1';
                n_data_cnt_int <= 0;
            else
                -- last data block; a padding-only block follows if the message ended
                -- on a block boundary (filled while MAC(k) runs)
                n_b_active <= '0';
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
        n_b_active <= '0';
        n_job <= J_FINAL;
        n_ctl_s <= PERM;

    when PERM =>
        if perm_cnt_int < PERM_CYCLES then
            perm_en <= '1';
            n_perm_cnt_int <= perm_cnt_int + 1;
            ms_en <= '1';
            msb_en <= b_active;
            if job = J_AD and perm_cnt_int = 0 then
                datap_lfsr_en <= '1';       -- a = j-1 -> j: AD unmask uses cur / next
            end if;
            if perm_cnt_int = PERM_CYCLES-1 then
                n_ctl_s <= POST;
            end if;
        end if;

    when POST =>
        case job is
        when J_AD =>
            -- tag ^= (P(A_j xor phi^j) xor phi^j) [xor (P(A_j+1 xor phi^(j+1)) xor phi^(j+1))]
            tag_en <= '1';
            src_sel <= SRC_MS;
            mask_sel <= M_CUR;
            tagb_en <= b_active;
            srcb_sel <= SB_MS;
            maskb_sel <= MB_NEXT;
            datap_lfsr_en <= '1';           -- a = j -> j+1
            if fill_active = '1' then
                n_ctl_s <= AD_WAIT;
            else
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        when J_KS0 =>
            ks_en <= '1';                   -- ks_reg <= KS(0) = P(..) xor cur xor next
            ks_sel <= '0';
            msb_en <= '1';                  -- msb_reg <= KS(1) = P(..) xor next xor next2
            srcb_sel <= SB_MS;
            maskb_sel <= MB_NEXT_NEXT2;
            datap_lfsr_en <= '1';           -- a = 0 -> 1
            n_fill_active <= '1';
            n_fill_msg <= '1';
            n_fill_b2 <= '0';
            n_data_cnt_int <= 0;
            if not (bdi_type = HDR_PT or bdi_type = HDR_CT) then
                -- empty PT/CT: only the padding block 0x01 00.. is MACed
                n_done_state <= '1';
                n_append_one <= '1';
            end if;
            n_ctl_s <= MSG_WAIT;
        when J_MAC =>
            tag_en <= '1';
            src_sel <= SRC_MS;
            mask_sel <= M_PREV_NEXT;
            if b_active = '1' then
                msb_en <= '1';              -- unmask KS(k+2)
                srcb_sel <= SB_MS;
                maskb_sel <= MB_NEXT_NEXT2;
            end if;
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
        load_buf_sel <= fill_b2;
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
    elsif fill_active = '1' and fill_msg = '0' and first_blk = '0' and fill_b2 = '0' and
          data_cnt_int = BLOCK_SIZE and more_ad = '1' then
        -- first block of an AD pair is complete and more AD follows: fill the second buffer
        n_data_cnt_int <= 0;
        n_fill_b2 <= '1';
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
            fill_b2 <= '0';
            b_active <= '0';
        else
            ctl_s <= n_ctl_s;
            done_state <= n_done_state;
            decrypt_op <= n_decrypt_op;
            tag_verified <= n_tag_verified;
            append_one <= n_append_one;
            first_blk <= n_first_blk;
            fill_active <= n_fill_active;
            fill_msg <= n_fill_msg;
            fill_b2 <= n_fill_b2;
            b_active <= n_b_active;
        end if;
    end if;
end process;
end behavioral;
