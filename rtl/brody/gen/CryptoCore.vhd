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
-- brody/gen controller (see rtl/brody/gen/README.md). G_N = G_U*G_S permutation slots in lockstep.
--
-- Loader: fills a BATCH of blocks into input buffers 0..batch_last (AD: up to N, message: max(M,1)),
-- one block after another, stopping early when no more blocks follow; sets the registered batch_done.
-- With G_FAST_LOADER the next-buffer decision is made in the cycle of a block's last word (5 cycles per
-- block); otherwise in a separate cycle after it (6 cycles per block).
--
-- Window w(j) = phi^(a-1+j).
--  AD block 0 (N||AD0): tag <= block; LFSR loaded and stepped to a = 2.
--  AD batch j..j+N-1 (a = j+1): slot i gets A_{j+i} ^ w(i); unmask; step N; tag ^= results.
--  Message: LFSR reloaded and stepped to a = 1.
--   N >= 2: round 0: KS(0..2M-1); KS(0..M-1) -> ks buffers; blocks 0..M-1 stream.
--           batch k..k+M-1 full, more follows (a = k+1): ks buffers <= KS(k+M..k+2M-1) from slots M..2M-1;
--           slots 0..M-1: MAC(k..k+M-1); slots M..2M-1: KS(k+2M..k+3M-1); next batch streams meanwhile;
--           unmask; step M; tag ^= MACs.   Last batch: MACs only.
--   N = 1:  KS(0) -> ks; block k full: if more data: KS(k+1) -> ks, then MAC(k) while block k+1 streams;
--           otherwise MAC(k) (filling the 0x01 padding block meanwhile if one follows). Step 1 per MAC.
--  Final: slot 0: P(tag ^ L) ^ L, tag = low 64 bits.
-- Every permutation: setup (load) -> PERM (PERM_CYCLES) -> POST1 (unmask in place, LFSR step)
--                    -> POST2 (tag / keystream-buffer update).
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
    signal load_buf: integer range 0 to G_N-1;
    signal ld: std_logic_vector(G_N-1 downto 0);
    signal te: std_logic_vector(G_N-1 downto 0);
    signal tag_from_buf: std_logic;
    signal ks_en: std_logic;
    signal ks_from_kslots: std_logic;
    signal ks_buf_sel: integer range 0 to G_NKS-1;
    signal tag_word: std_logic_vector(CCW - 1 downto 0);   -- expected tag word (decrypt), not via bdo
    signal key_en: std_logic;
    signal npub_en: std_logic;
    signal tag_en: std_logic;
    signal tag_reset: std_logic;
    signal perm_en: std_logic;

    -- slot-mux controls: decided one cycle early from the next state, registered, replicated by Vivado
    signal mode_q: std_logic_vector(2 downto 0);
    signal unmask_q: std_logic;
    attribute max_fanout : integer;
    attribute max_fanout of mode_q : signal is 64;
    attribute max_fanout of unmask_q : signal is 64;

    --Signals for datapath lsfr
    signal datap_lfsr_load: std_logic;
    signal datap_lfsr_en: std_logic;
    signal datap_lfsr_step: std_logic_vector(1 downto 0);

    --Signals for data counter
    signal n_data_cnt_int, data_cnt_int :integer range 0 to BLOCK_SIZE+1;
    signal perm_cnt_int, n_perm_cnt_int: integer range 0 to PERM_CYCLES;
    signal aux_cnt, n_aux_cnt: integer range 0 to 3;   -- LFSR init / reload sequencing

    type ctl_state is (IDLE, STORE_KEY, PERM_KEY, LOAD_KEY,
                       AD_INIT, AD_WAIT, MSG_LFSR, MSG_WAIT,
                       PERM, POST1, POST2, FINAL_PRE, TAG_S, TAG_AUTH);
    signal n_ctl_s, ctl_s: ctl_state;
    type job_t is (J_AD, J_KS0, J_MSG, J_KS1, J_FINAL);
    signal job, n_job: job_t;
    signal act, n_act: std_logic_vector(G_N-1 downto 0);   -- slots carrying a real call

    signal fill_active, n_fill_active: std_logic;  -- loader owns data_cnt_int / load_data
    signal fill_msg, n_fill_msg: std_logic;        -- '0' AD, '1' message
    signal fb, n_fb: integer range 0 to G_N-1;     -- input buffer being filled
    signal batch_last, n_batch_last: integer range 0 to G_N-1;
    signal batch_done, n_batch_done: std_logic;    -- registered: batch complete
    signal more: std_logic;                        -- another block follows the last filled one

    signal done_state, n_done_state: std_logic;
    signal append_one, n_append_one: std_logic;
    signal first_blk, n_first_blk: std_logic;  -- v2: first AD block (N||AD0) is not permuted
    signal decrypt_op, n_decrypt_op: std_logic;
    signal n_tag_verified, tag_verified :std_logic;

    -- slot masks (elaboration time)
    function upto(k: integer) return std_logic_vector is
        variable v: std_logic_vector(G_N-1 downto 0) := (others => '0');
    begin
        for i in 0 to G_N-1 loop
            if i <= k then v(i) := '1'; end if;
        end loop;
        return v;
    end function;
    constant SLOT0     : std_logic_vector(G_N-1 downto 0) := upto(0);
    constant MAC_SLOTS : std_logic_vector(G_N-1 downto 0) := upto(G_NKS - 1);
    constant KS0_SLOTS : std_logic_vector(G_N-1 downto 0) := upto(G_NKS0 - 1);
    constant MSG_SLOTS : std_logic_vector(G_N-1 downto 0) := upto(2*G_M - 1);

    function mode_for(st: ctl_state; jb: job_t; done: std_logic) return std_logic_vector is
    begin
        case st is
            when AD_WAIT   => return MD_AD;
            when MSG_LFSR  => return MD_KS0;
            when MSG_WAIT  =>
                if G_N = 1 and done = '0' then return MD_KS1; else return MD_MSG; end if;
            when FINAL_PRE => return MD_FIN;
            when POST1 =>
                case jb is
                    when J_AD    => return MD_AD;
                    when J_KS0   => return MD_KS0;
                    when J_MSG   => return MD_MSG;
                    when J_KS1   => return MD_KS1;
                    when J_FINAL => return MD_FIN;
                end case;
            when POST2 =>
                if jb = J_KS1 then return MD_MSG; else return MD_KEY; end if;   -- N = 1: MAC(k) setup
            when others    => return MD_KEY;
        end case;
    end function;

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
            mode => mode_q,
            unmask => unmask_q,
            ld => ld,
            te => te,
            tag_from_buf => tag_from_buf,
            ks_en => ks_en,
            ks_from_kslots => ks_from_kslots,
            ks_buf_sel => ks_buf_sel,
            tag_word => tag_word,
            key_en => key_en,
            npub_en => npub_en,
            tag_en => tag_en,
            tag_reset => tag_reset,

            perm_en => perm_en,

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

    more <= '1' when done_state = '0' or append_one = '1' else '0';
    -- buffer selects straight from the buffer-index register (writes are gated by load_data_en; the keystream
    -- select only matters while a message block streams), so no handshake/loader logic sits in front of them
    load_buf <= fb;
    ks_buf_sel <= fb mod G_NKS;

state_control: process(all)
    variable v_done, v_app: std_logic;
    variable v_adv: boolean;
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
    ld <= (others => '0');
    te <= (others => '0');
    tag_from_buf <= '0';
    ks_en <= '0';
    ks_from_kslots <= '0';
    key_en <= '0';
    npub_en <= '0';
    tag_reset <= '0';
    tag_en <= '0';

    perm_en <= '0';
    datap_lfsr_load <= '0';
    datap_lfsr_en <= '0';
    datap_lfsr_step <= ST_MSG;

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
        n_act <= SLOT0;
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
                    ld <= SLOT0;           -- slot 0 <= K || 0 (mode KEY)
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
        -- LFSR: load (a = 2 - NMASK), then NMASK steps (a = 2) while N||AD0 fills
        if aux_cnt < 2 then
            datap_lfsr_en <= '1';
            if aux_cnt = 0 then
                datap_lfsr_load <= '1';
            else
                datap_lfsr_step <= ST_ADINIT;
            end if;
            n_aux_cnt <= aux_cnt + 1;
        elsif batch_done = '1' then
            -- v2: N||AD0 is not permuted; it initializes the tag (tag is 0 here)
            tag_en <= '1';
            tag_from_buf <= '1';
            n_first_blk <= '0';
            n_batch_done <= '0';
            if more = '1' then
                n_data_cnt_int <= 0;        -- fill AD blocks 1..N
                n_fb <= 0;
                n_batch_last <= G_N - 1;
                n_ctl_s <= AD_WAIT;
            else
                n_fill_active <= '0';
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        end if;

    when AD_WAIT =>
        -- AD batch j..j+fb complete, window a = j+1 (mode AD)
        if batch_done = '1' then
            ld <= upto(fb);
            n_act <= upto(fb);
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
        -- LFSR: load, NMASK-1 steps (a = 1); then KS(0..2M-1) (mode KS0)
        n_done_state <= '0';
        n_append_one <= '0';
        if aux_cnt < 2 then
            datap_lfsr_en <= '1';
            if aux_cnt = 0 then
                datap_lfsr_load <= '1';
            else
                datap_lfsr_step <= ST_MSGINIT;
            end if;
            n_aux_cnt <= aux_cnt + 1;
        else
            ld <= KS0_SLOTS;
            n_act <= KS0_SLOTS;
            n_job <= J_KS0;
            n_ctl_s <= PERM;
        end if;

    when MSG_WAIT =>
        -- batch k..k+fb complete, window a = k+1 (mode MSG, or KS1 for N = 1 with more data)
        if batch_done = '1' then
            n_ctl_s <= PERM;
            if G_N = 1 then
                if done_state = '0' then
                    -- KS(k+1) first; the full block waits in buffer 0 (batch_done stays set)
                    ld <= SLOT0;
                    n_act <= SLOT0;
                    n_job <= J_KS1;
                else
                    ld <= SLOT0;            -- MAC(k)
                    n_act <= SLOT0;
                    n_job <= J_MSG;
                    n_batch_done <= '0';
                    if append_one = '1' then
                        n_data_cnt_int <= 0;    -- padding block fills meanwhile
                        n_fb <= 0;
                    else
                        n_fill_active <= '0';
                    end if;
                end if;
            else
                n_job <= J_MSG;
                n_batch_done <= '0';
                if more = '1' then
                    ld <= MSG_SLOTS;
                    n_act <= MSG_SLOTS;
                    ks_en <= '1';               -- ks buffers <= KS(k+M..k+2M-1)
                    ks_from_kslots <= '1';
                    n_data_cnt_int <= 0;
                    n_fb <= 0;
                else
                    ld <= upto(fb);             -- last batch: MACs only
                    n_act <= upto(fb);
                    n_fill_active <= '0';
                end if;
            end if;
        end if;

    when FINAL_PRE =>
        ld <= SLOT0;                        -- slot 0 <= S xor L (mode FIN)
        n_act <= SLOT0;
        n_job <= J_FINAL;
        n_ctl_s <= PERM;

    when PERM =>
        if perm_cnt_int < PERM_CYCLES then
            perm_en <= '1';
            n_perm_cnt_int <= perm_cnt_int + 1;
            if perm_cnt_int = PERM_CYCLES-1 then
                n_ctl_s <= POST1;
            end if;
        end if;

    when POST1 =>
        -- unmask every active slot in place (mode = job's mode), then step the window
        ld <= act;
        case job is
            when J_AD =>
                datap_lfsr_en <= '1';
                datap_lfsr_step <= ST_AD;
            when J_MSG =>
                datap_lfsr_en <= '1';
                datap_lfsr_step <= ST_MSG;
            when others =>
                null;
        end case;
        n_ctl_s <= POST2;

    when POST2 =>
        case job is
        when J_AD =>
            tag_en <= '1';
            te <= act;
            if fill_active = '1' then
                n_ctl_s <= AD_WAIT;
            else
                n_aux_cnt <= 0;
                n_ctl_s <= MSG_LFSR;
            end if;
        when J_KS0 =>
            ks_en <= '1';                   -- ks buffers <= KS(0..max(M,1)-1)
            ks_from_kslots <= '0';
            n_fill_active <= '1';
            n_fill_msg <= '1';
            n_fb <= 0;
            n_batch_last <= G_NKS - 1;
            n_batch_done <= '0';
            n_data_cnt_int <= 0;
            if not (bdi_type = HDR_PT or bdi_type = HDR_CT) then
                -- empty PT/CT: only the padding block 0x01 00.. is MACed
                n_done_state <= '1';
                n_append_one <= '1';
            end if;
            n_ctl_s <= MSG_WAIT;
        when J_MSG =>
            tag_en <= '1';
            te <= act and MAC_SLOTS;
            if fill_active = '1' then
                n_ctl_s <= MSG_WAIT;
            else
                n_ctl_s <= FINAL_PRE;
            end if;
        when J_KS1 =>
            -- N = 1: ks <= KS(k+1); start MAC(k) on the waiting block (mode MSG) and stream block k+1
            ks_en <= '1';
            ks_from_kslots <= '0';
            ld <= SLOT0;
            n_act <= SLOT0;
            n_job <= J_MSG;
            n_batch_done <= '0';
            n_data_cnt_int <= 0;
            n_fb <= 0;
            n_ctl_s <= PERM;
        when J_FINAL =>
            -- T = trunc64(P(S xor L) xor L), read from slot 0's result register in TAG_S
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
            -- decrypt: compare each received tag word with the expected one (a dedicated tag word, not the
            -- bdo mux); the verdict is registered and reported from TAG_AUTH, so no comparison logic drives
            -- the PostProcessor directly
            if bdi_valid = '1' and msg_auth_ready = '1' then
                bdi_ready <= '1';
                n_data_cnt_int <= data_cnt_int + 1;
                if bdi /= tag_word then
                    n_tag_verified <= '0';
                end if;
                if data_cnt_int = ELE_TAG_SIZE-1 then
                    n_ctl_s <= TAG_AUTH;
                end if;
            end if;
        end if;
    when TAG_AUTH =>
        msg_auth_valid <= '1';
        msg_auth <= tag_verified;
        if msg_auth_ready = '1' then
            n_ctl_s <= IDLE;
        end if;
    end case;

    ----------------------------------------------------------------------------
    -- Loader: fills blocks into buffers fb = 0..batch_last, in any main state.
    ----------------------------------------------------------------------------
    if fill_active = '1' and batch_done = '0' then
        if data_cnt_int < BLOCK_SIZE then
            v_done := done_state;
            v_app := append_one;
            v_adv := false;
            if fill_msg = '0' then
                -- AD. Block 0 decides "no (more) AD" from bdi_type, as in brody/base; later blocks only
                -- end on the eot flags.
                if done_state /= '1' and append_one /= '1' and (first_blk = '0' or bdi_type = HDR_AD) then
                    if bdi_valid = '1' and bdi_type = HDR_AD then
                        bdi_ready <= '1';
                        n_data_cnt_int <= data_cnt_int + 1;
                        v_adv := true;
                        load_data_en <= '1';
                        if bdi_valid_bytes = "1111" then
                            load_data_sel <= "01";
                        else
                            load_data_sel <= "10";
                        end if;
                        if bdi_eot = '1' then
                            if (data_cnt_int = BLOCK_SIZE-1 and bdi_valid_bytes = "1111") = False then
                                v_done := '1';
                            end if;
                            if bdi_valid_bytes = "1111" then
                                v_app := '1';
                            end if;
                        end if;
                    end if;
                else
                    n_data_cnt_int <= data_cnt_int + 1;
                    v_adv := true;
                    load_data_en <= '1';
                    if append_one = '1' or done_state = '0' then
                        load_data_sel <= "10";      -- 0x01 padding byte
                        bdi_size_intern <= "00";
                        v_app := '0';
                        v_done := '1';
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
                        v_adv := true;
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
                            v_done := '1';
                            if bdi_valid_bytes = "1111" then
                                v_app := '1';
                            end if;
                        end if;
                    end if;
                else
                    n_data_cnt_int <= data_cnt_int + 1;
                    v_adv := true;
                    load_data_en <= '1';
                    if append_one = '1' then
                        load_data_sel <= "10";      -- 0x01 padding byte
                        bdi_size_intern <= "00";
                        v_app := '0';
                        v_done := '1';
                    else
                        load_data_sel <= "00";      -- zero pad
                    end if;
                end if;
            end if;
            n_done_state <= v_done;
            n_append_one <= v_app;
            -- fast loader: the block completes this cycle, decide right away
            if G_FAST_LOADER and v_adv and data_cnt_int = BLOCK_SIZE-1 then
                if fb < batch_last and (v_done = '0' or v_app = '1') then
                    n_fb <= fb + 1;
                    n_data_cnt_int <= 0;
                else
                    n_batch_done <= '1';
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
        mode_q <= mode_for(n_ctl_s, n_job, n_done_state);
        if n_ctl_s = POST1 then
            unmask_q <= '1';
        else
            unmask_q <= '0';
        end if;
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
