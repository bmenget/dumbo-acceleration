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
-- optBCD: options B + C + D of rtl/ACCELERATION.md (see rtl/core_v2_r4_optBCD/OPT_BCD.md).
-- Four permutation slots (two units, each pipelined into two 4-round stages; see elephant_datapath.vhd),
-- all in lockstep. act(s) says which slots carry a real call.
--
-- The block filler ("loader") fills a BATCH of blocks into input buffers 0..batch_last, one block
-- after another, stopping early when no more blocks follow. When the batch is complete it sets the
-- registered flag batch_done; the main FSM consumes it.
--
-- Window w(i) = phi^(a-1+i), i = 0..6.
--  AD block 0 (N||AD0): tag <= block; LFSR loaded (a = -5) and stepped 4+2+1 to a = 2.
--  AD batch j..j+3 (a = j+1): slot s gets A_{j+s} xor w(s); tag ^= results xor w(s); step 4.
--  Message, LFSR reloaded and stepped 4+2 to a = 1:
--     round 0: KS(0..3) in the 4 slots; KS(0)/KS(1) -> ks0/ks1, KS(2)/KS(3) unmasked in B0/B1.
--     blocks 0,1 stream from ks0/ks1.
--     batch (k, k+1) full, more follows (a = k+1):
--        ks0/ks1 <= KS(k+2)/KS(k+3) from B0/B1; A0/A1: MAC(k), MAC(k+1); B0/B1: KS(k+4), KS(k+5);
--        blocks k+2, k+3 stream meanwhile; tag ^= MACs; B0/B1 unmask; step 2.
--     last batch: MAC(k) [and MAC(k+1)] only.
--  Final: A0: P(tag xor L) xor L, tag = low 64 bits.
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
    signal load_buf: std_logic_vector(1 downto 0);
    signal mode: std_logic_vector(2 downto 0);
    signal unmask: std_logic;
    signal ld: std_logic_vector(3 downto 0);
    signal te: std_logic_vector(3 downto 0);
    signal ks_en: std_logic;
    signal ks_from_b: std_logic;
    signal ks_buf_sel: std_logic;
    signal key_en: std_logic;
    signal npub_en: std_logic;
    signal tag_en: std_logic;
    signal tag_reset: std_logic;

    --Signals for permutation
    signal load_lfsr:std_logic;
    signal perm_en: std_logic;
    -- busy probes per slot (profile.txt)
    signal busy_a0, busy_a1, busy_b0, busy_b1: std_logic;

    --Signals for datapath lsfr
    signal datap_lfsr_load: std_logic;
    signal datap_lfsr_en: std_logic;
    signal datap_lfsr_step: std_logic_vector(1 downto 0);
    constant STEP1 : std_logic_vector(1 downto 0) := "00";
    constant STEP2 : std_logic_vector(1 downto 0) := "01";
    constant STEP4 : std_logic_vector(1 downto 0) := "10";

    --Signals for data counter
    signal n_data_cnt_int, data_cnt_int :integer range 0 to BLOCK_SIZE+1;
    signal perm_cnt_int, n_perm_cnt_int: integer range 0 to PERM_CYCLES;
    signal aux_cnt, n_aux_cnt: integer range 0 to 4;   -- LFSR init / reload sequencing

    type ctl_state is (IDLE, STORE_KEY, PERM_KEY, LOAD_KEY,
                       AD_INIT, AD_WAIT, MSG_LFSR, MSG_WAIT,
                       PERM, POST, FINAL_PRE, TAG_S);
    signal n_ctl_s, ctl_s: ctl_state;
    type job_t is (J_AD, J_KS0, J_MSG, J_FINAL);
    signal job, n_job: job_t;
    signal act, n_act: std_logic_vector(3 downto 0);   -- slots carrying a real call

    signal fill_active, n_fill_active: std_logic;  -- loader owns data_cnt_int / load_data
    signal fill_msg, n_fill_msg: std_logic;        -- '0' AD, '1' message
    signal fb, n_fb: integer range 0 to 3;         -- input buffer being filled
    signal batch_last, n_batch_last: integer range 0 to 3;
    signal batch_done, n_batch_done: std_logic;    -- registered: batch complete
    signal more: std_logic;                        -- another block follows the last filled one

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
            load_buf => load_buf,
            mode => mode,
            unmask => unmask,
            ld => ld,
            te => te,
            ks_en => ks_en,
            ks_from_b => ks_from_b,
            ks_buf_sel => ks_buf_sel,
            key_en => key_en,
            npub_en => npub_en,
            tag_en => tag_en,
            tag_reset => tag_reset,

            perm_en => perm_en,
            load_lfsr  => load_lfsr,

            datap_lfsr_load => datap_lfsr_load,
            datap_lfsr_en => datap_lfsr_en,
            datap_lfsr_step => datap_lfsr_step,

            bdo => bdo_s,
            bdo_sel => bdo_sel,
            saving_bdo => saving_bdo,
            data_count => data_cnt_int,
            perm_count => perm_cnt_int,
            clk        => clk
        );

    -- Round-constant LFSR inside elephant_perm (used only when PERM_ROUNDS_PER_CYCLE = 1)
    load_lfsr <= not perm_en;
    busy_a0 <= perm_en and act(0);
    busy_a1 <= perm_en and act(1);
    busy_b0 <= perm_en and act(2);
    busy_b1 <= perm_en and act(3);
    more <= '1' when done_state = '0' or append_one = '1' else '0';

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
    load_buf <= "00";
    mode <= MD_KEY;
    unmask <= '0';
    ld <= "0000";
    te <= "0000";
    ks_en <= '0';
    ks_from_b <= '0';
    ks_buf_sel <= '0';
    key_en <= '0';
    npub_en <= '0';
    tag_reset <= '0';
    tag_en <= '0';

    perm_en <= '0';
    datap_lfsr_load <= '0';
    datap_lfsr_en <= '0';
    datap_lfsr_step <= STEP1;

    n_ctl_s <= ctl_s;
    n_job <= job;
    n_act <= act;
    n_fill_active <= fill_active;
    n_fill_msg <= fill_msg;
    n_fb <= fb;
    n_batch_last <= batch_last;
    n_batch_done <= batch_done;
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
    -- is idle (fill_active = '0') or its batch is done (batch_done = '1').
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
        n_fb <= 0;
        n_batch_done <= '0';
        n_act <= "0001";
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
                    ld(0) <= '1';          -- A0 <= K || 0 (mode KEY)
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
            if perm_cnt_int = PERM_CYCLES-1 then
                key_en <= '1';             -- L straight from the permutation
                if data_cnt_int = ELE_NPUB_SIZE then
                    n_ctl_s <= AD_INIT;
                    n_fill_active <= '1';
                    n_fill_msg <= '0';
                    n_fb <= 0;
                    n_batch_last <= 0;
                    n_batch_done <= '0';
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
        elsif data_cnt_int = ELE_NPUB_SIZE then
            npub_en <= '1';
        end if;
    when LOAD_KEY =>
        if data_cnt_int < ELE_NPUB_SIZE then
            if bdi_valid = '1' then
                n_data_cnt_int <= data_cnt_int + 1;
                n_decrypt_op <= decrypt_in;
                bdi_ready <= '1';
                load_data_en <= '1';
                load_data_sel <= "01";
            end if;
        elsif data_cnt_int = ELE_NPUB_SIZE then
            npub_en <= '1';
            n_ctl_s <= AD_INIT;
            n_fill_active <= '1';   -- loader fills N||AD0 from word 3, batch of one
            n_fill_msg <= '0';
            n_fb <= 0;
            n_batch_last <= 0;
            n_batch_done <= '0';
            n_aux_cnt <= 0;
        end if;

    when AD_INIT =>
        -- LFSR: load (a = -5), then step 4, 2, 1 (a = 2) while N||AD0 fills
        if aux_cnt < 4 then
            datap_lfsr_en <= '1';
            case aux_cnt is
                when 0 => datap_lfsr_load <= '1';
                when 1 => datap_lfsr_step <= STEP4;
                when 2 => datap_lfsr_step <= STEP2;
                when others => datap_lfsr_step <= STEP1;
            end case;
            n_aux_cnt <= aux_cnt + 1;
        elsif batch_done = '1' then
            -- v2: N||AD0 is not permuted; it initializes the tag (tag is 0 here)
            tag_en <= '1';
            te <= "0001";
            mode <= MD_KEY;               -- x(0) = input buffer 0
            n_first_blk <= '0';
            n_batch_done <= '0';
            if more = '1' then
                n_data_cnt_int <= 0;        -- fill AD blocks 1..4
                n_fb <= 0;
                n_batch_last <= 3;
                n_ctl_s <= AD_WAIT;
            else
                n_fill_active <= '0';
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        end if;

    when AD_WAIT =>
        -- AD batch j..j+fb complete, window a = j+1
        if batch_done = '1' then
            mode <= MD_AD;
            ld(0) <= '1';
            if fb >= 1 then ld(1) <= '1'; end if;
            if fb >= 2 then ld(2) <= '1'; end if;
            if fb = 3  then ld(3) <= '1'; end if;
            case fb is
                when 0 => n_act <= "0001";
                when 1 => n_act <= "0011";
                when 2 => n_act <= "0111";
                when others => n_act <= "1111";
            end case;
            n_job <= J_AD;
            n_ctl_s <= PERM;
            n_batch_done <= '0';
            if more = '1' then
                n_data_cnt_int <= 0;        -- fill the next batch meanwhile
                n_fb <= 0;
            else
                n_fill_active <= '0';
            end if;
        end if;

    when MSG_LFSR =>
        -- LFSR: load (a = -5), step 4, step 2 (a = 1); then KS(0..3)
        n_done_state <= '0';
        n_append_one <= '0';
        if aux_cnt < 3 then
            datap_lfsr_en <= '1';
            case aux_cnt is
                when 0 => datap_lfsr_load <= '1';
                when 1 => datap_lfsr_step <= STEP4;
                when others => datap_lfsr_step <= STEP2;
            end case;
            n_aux_cnt <= aux_cnt + 1;
        else
            mode <= MD_KS0;
            ld <= "1111";
            n_act <= "1111";
            n_job <= J_KS0;
            n_ctl_s <= PERM;
        end if;

    when MSG_WAIT =>
        -- batch (k[, k+1]) complete, window a = k+1, B0/B1 hold KS(k+2)/KS(k+3)
        if batch_done = '1' then
            mode <= MD_MSG;
            n_job <= J_MSG;
            n_ctl_s <= PERM;
            n_batch_done <= '0';
            if more = '1' then
                -- blocks k+2, k+3 stream from KS(k+2)/KS(k+3) while A0/A1 MAC and B0/B1 make KS(k+4)/KS(k+5)
                ld <= "1111";
                ks_en <= '1';
                ks_from_b <= '1';
                n_act <= "1111";
                n_data_cnt_int <= 0;
                n_fb <= 0;
            else
                -- last batch: MACs only
                ld(0) <= '1';
                if fb = 1 then
                    ld(1) <= '1';
                    n_act <= "0011";
                else
                    n_act <= "0001";
                end if;
                n_fill_active <= '0';
            end if;
        end if;

    when FINAL_PRE =>
        mode <= MD_FIN;                     -- A0 <= S xor L
        ld(0) <= '1';
        n_act <= "0001";
        n_job <= J_FINAL;
        n_ctl_s <= PERM;

    when PERM =>
        if perm_cnt_int < PERM_CYCLES then
            perm_en <= '1';
            n_perm_cnt_int <= perm_cnt_int + 1;
            if perm_cnt_int = PERM_CYCLES-1 then
                n_ctl_s <= POST;
            end if;
        end if;

    when POST =>
        unmask <= '1';
        case job is
        when J_AD =>
            mode <= MD_AD;
            tag_en <= '1';
            te <= act;                      -- tag ^= sum of P(A xor phi) xor phi
            datap_lfsr_en <= '1';
            datap_lfsr_step <= STEP4;
            if fill_active = '1' then
                n_ctl_s <= AD_WAIT;
            else
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        when J_KS0 =>
            mode <= MD_KS0;
            ks_en <= '1';                   -- ks0/ks1 <= KS(0)/KS(1)
            ks_from_b <= '0';
            ld <= "1100";                   -- B0/B1 <= KS(2)/KS(3), unmasked in place
            n_fill_active <= '1';
            n_fill_msg <= '1';
            n_fb <= 0;
            n_batch_last <= 1;
            n_batch_done <= '0';
            n_data_cnt_int <= 0;
            if not (bdi_type = HDR_PT or bdi_type = HDR_CT) then
                -- empty PT/CT: only the padding block 0x01 00.. is MACed
                n_done_state <= '1';
                n_append_one <= '1';
            end if;
            n_ctl_s <= MSG_WAIT;
        when J_MSG =>
            mode <= MD_MSG;
            tag_en <= '1';
            te <= "00" & act(1 downto 0);   -- MACs
            ld <= act(3 downto 2) & "00";   -- unmask KS(k+4)/KS(k+5) in place
            datap_lfsr_en <= '1';
            datap_lfsr_step <= STEP2;
            if fill_active = '1' then
                n_ctl_s <= MSG_WAIT;
            else
                n_ctl_s <= FINAL_PRE;
            end if;
        when J_FINAL =>
            -- T = trunc64(P(S xor L) xor L), read from A0 in TAG_S
            mode <= MD_FIN;
            ld <= "0001";
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
    -- Loader: fills blocks into buffers fb = 0..batch_last, in any main state.
    ----------------------------------------------------------------------------
    if fill_active = '1' and batch_done = '0' then
        if data_cnt_int < BLOCK_SIZE then
            load_buf <= std_logic_vector(to_unsigned(fb, 2));
            if fb = 1 then
                ks_buf_sel <= '1';
            end if;
            if fill_msg = '0' then
                -- AD. Block 0 decides "no (more) AD" from bdi_type, as in core_v2; later blocks only
                -- end on the eot flags.
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
                -- Message: out word = in word xor keystream slice; the buffer keeps the ciphertext
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
        else
            -- block in buffer fb is complete: next buffer, or the batch is done
            if fb < batch_last and more = '1' then
                n_fb <= fb + 1;
                n_data_cnt_int <= 0;
            else
                n_batch_done <= '1';
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
        act <= n_act;
        fb <= n_fb;
        batch_last <= n_batch_last;
        if rst = '1' then
            ctl_s <= IDLE;
            done_state <= '0';
            decrypt_op <= '0';
            tag_verified <= '0';
            append_one <= '0';
            first_blk <= '1';
            fill_active <= '0';
            fill_msg <= '0';
            batch_done <= '0';
        else
            ctl_s <= n_ctl_s;
            done_state <= n_done_state;
            decrypt_op <= n_decrypt_op;
            tag_verified <= n_tag_verified;
            append_one <= n_append_one;
            first_blk <= n_first_blk;
            fill_active <= n_fill_active;
            fill_msg <= n_fill_msg;
            batch_done <= n_batch_done;
        end if;
    end if;
end process;
end behavioral;
