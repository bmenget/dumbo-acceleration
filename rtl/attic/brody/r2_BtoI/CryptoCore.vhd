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
-- BtoI: BtoH with the wrapper handshakes cut off the core's paths (see
-- rtl/brody/r4_BtoI/README.md). A 2-entry register slice on bdi and one on bdo, so
-- bdi_ready / bdo_valid are flip-flops and the loader decides on registered words; the keystream head's
-- next value is selected by the word accept in one last mux (elephant_datapath.vhd).
--
-- BtoH: BtoG for less area (see rtl/brody/r4_BtoH/README.md). New calls go into
-- stage 0 of a ring only. With PERM_CYCLES a multiple of NSTAGE every call finishes in the ring's last
-- stage, which hands its slot back to stage 0 at the same edge, so a slot is still reusable at once.
-- The datapath then needs no load mux in stages 1.., a result mux over the rings only, and a delay line
-- instead of a mask store (calls finish in load order after PERM_CYCLES). No ring phase is tracked.
--
-- BtoG: BtoF with NUNIT rings of NSTAGE stage registers (NSLOT calls in flight, 4 x 2 = 8
-- here) and the three critical paths of BtoF shortened (see rtl/brody/r4_BtoG/README.md):
--  * Issue is two cycles ahead: a decision (stage A) prepares x = src xor mask into a register; the next
--    cycle (stage B) loads that register into the chosen stage register and its mask into the mask store.
--  * Each stage register's round constants are registered here (rc), next to its round counter.
--  * The finishing register and its mask entry go to the datapath as binary indices (res_i, res_mi).
--  * The keystream head shifts one word per message word (ks_adv); bdo no longer muxes by data_count.
-- Ring geometry: a call moves p -> nxt(p) every cycle; vslot(p, ph) is its mask store entry.
--
-- BtoF: BtoE (staggered calls) plus a fast loader (option F, see rtl/brody/r4_BtoF/README.md):
-- a block's completion and the switch to the next buffer happen in the cycle of its last word, so a
-- block takes 5 cycles instead of 6. The tag initialization from block 0 (N||AD0) is delayed one
-- cycle (tag_init_d), since buffer 0 takes its last word in that cycle. Otherwise as BtoE:
--
-- BtoE: BtoD (two 2-stage rings of 4-round stages, 4 calls in flight) with staggered calls
-- (option E, see rtl/brody/r4_BtoE/README.md). Three loosely coupled parts:
--
--  * Main FSM: key, nonce, then RUN until the final call is done, then the tag.
--  * Loader: fills blocks into two input buffers, one after the other. A finished AD or message block
--    marks its buffer full (bst); the next block goes into the other buffer as soon as it is empty.
--    Message words stream out as they arrive, xored with the keystream FIFO head (KS(k) for block k).
--  * Issue engine (p_issue): each register's call is tracked (v, pc, kd move with the ring). One cycle
--    ahead it picks a register that will be free and one request, in this order:
--      KEY > FIN > the next full buffer (AD or MAC, in block order) > a keystream call (up to NKS ahead).
--    A call finishes 20 cycles after it is loaded; one cycle later its unmasked result goes to the key,
--    the tag or the keystream FIFO. Loads are one per cycle, so results are too.
--
-- Masks: AD block j: phi^j; MAC(k): phi^k xor phi^(k+2); KS(k): phi^k xor phi^(k+1). Two mask windows
-- (elephant_mask_lfsr): MAC (load + 3 steps -> phi^1 for AD; reloaded + 2 steps -> phi^0 for the
-- message; one step per AD / MAC call) and KS (load + 1 step -> phi^0; one step per keystream call).
-- Keystream calls start once the nonce and L are known, i.e. during AD.
--
-- Segment types: the first block of AD and of the message waits until bdi_type shows the segment
-- (AD / PT, CT). Any other type, or SEG_WAIT cycles of none, means the segment is empty.
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
    signal load_buf: std_logic;
    signal npub_en: std_logic;

    --Signals for data counter
    signal n_data_cnt_int, data_cnt_int :integer range 0 to BLOCK_SIZE+1;
    signal wait_cnt, n_wait_cnt: integer range 0 to SEG_WAIT;

    type ctl_state is (IDLE, STORE_KEY, KEY_ISS, LOAD_NONCE, RUN, TAG_S);
    signal n_ctl_s, ctl_s: ctl_state;

    signal fill_active, n_fill_active: std_logic;  -- loader owns data_cnt_int / load_data
    signal fill_msg, n_fill_msg: std_logic;        -- '0' AD, '1' message
    signal fb, n_fb: integer range 0 to 1;         -- input buffer being filled
    signal seg_chk, n_seg_chk: std_logic;          -- first block of a segment: is the segment there?
    signal ks_used, n_ks_used: std_logic;          -- this message block used the keystream head
    signal more: std_logic;                        -- another block follows the current one

    signal done_state, n_done_state: std_logic;
    signal append_one, n_append_one: std_logic;
    signal first_blk, n_first_blk: std_logic;  -- v2: first AD block (N||AD0) is not permuted
    signal decrypt_op, n_decrypt_op: std_logic;
    signal n_tag_verified, tag_verified :std_logic;

    -- FSM / loader -> issue engine (pulses)
    signal key_req_set, key_clr, blk_full, ks_pop, ad_end, msg_end, op_clr: std_logic;
    signal fsm_tag_reset, fsm_tag_init: std_logic;
    signal tag_init_d, n_tag_init_d: std_logic;    -- block 0 completed last cycle

    -- issue engine state
    type kind_arr is array (0 to NSLOT-1) of std_logic_vector(2 downto 0);
    signal v: std_logic_vector(NSLOT-1 downto 0);  -- register p holds a live call
    signal pc: pc_arr;                             -- its round group
    signal rc: rc_arr;                             -- its round constants (RC_TAB(pc))
    signal kd: kind_arr;                           -- its kind
    signal iss_v: std_logic;                       -- stage A: a new call's x is prepared this cycle
    signal iss_p: integer range 0 to NSLOT-1;
    signal iss_kind: std_logic_vector(2 downto 0);
    signal iss_buf: integer range 0 to 1;
    signal b_v: std_logic;                         -- stage B: it is loaded into b_p this cycle
    signal b_p: integer range 0 to NSLOT-1;
    signal b_kind: std_logic_vector(2 downto 0);
    signal res_en: std_logic;                      -- a call finishes this cycle
    signal res_i: integer range 0 to NSLOT-1;      -- in this (last-stage) register
    signal res_u: integer range 0 to NUNIT-1;      -- of this ring
    signal res_v: std_logic;                       -- a result is unmasked this cycle
    signal res_kind: std_logic_vector(2 downto 0);
    signal bst: std_logic_vector(0 to 1);          -- input buffer full (waiting for its call)
    signal bkd: std_logic_vector(0 to 1);          -- '0' AD block, '1' message block
    signal ip: integer range 0 to 1;               -- next buffer to issue (block order)
    signal key_req, key_rdy, fin_issued, fin_done, msg_phase, msg_done: std_logic;
    signal ks_cred: integer range 0 to NKS;        -- keystream calls issued, not yet consumed
    signal ks_cnt: integer range 0 to NKS;         -- keystreams in the FIFO
    signal tag_infl: integer range 0 to 31;        -- AD / MAC calls issued, not yet in the tag
    signal mac_st: integer range 0 to 9;           -- MAC window: 0..4 AD setup, 5 AD, 6..8 msg setup, 9 msg
    signal ks_st: integer range 0 to 3;            -- KS window: 0..2 setup, 3 ready

    -- issue engine -> datapath
    signal b_ld: std_logic_vector(NUNIT-1 downto 0);
    signal iss_buf_s: std_logic;
    signal key_en, tag_en, ks_push, ks_adv: std_logic;
    signal tag_sel: std_logic_vector(1 downto 0);
    signal mac_load, mac_step, ks_load, ks_step: std_logic;

    -- input register slice (2-entry skid buffer) between the PreProcessor and the loader
    constant IW: integer := CCW + CCWdiv8 + 3 + 1 + 4 + 1;
    signal in_w, ih, is_w: std_logic_vector(IW-1 downto 0);   -- wrapper word, head, skid entry
    signal ih_v, is_v: std_logic;
    signal bdi_i: std_logic_vector(CCW-1 downto 0);
    signal bdi_vb_i: std_logic_vector(CCWdiv8-1 downto 0);
    signal bdi_size_i: std_logic_vector(2 downto 0);
    signal bdi_type_i: std_logic_vector(3 downto 0);
    signal bdi_eot_i, decrypt_i, bdi_valid_i, bdi_ready_c: std_logic;

    -- output register slice (2-entry skid buffer) between the core and the PostProcessor
    constant OW: integer := CCW + CCWdiv8 + 4 + 1;
    signal out_w, oh, os_w: std_logic_vector(OW-1 downto 0);
    signal oh_v, os_v: std_logic;
    signal bdo_valid_c, bdo_ready_c, eob_c: std_logic;
    signal bdo_vb_c: std_logic_vector(CCWdiv8-1 downto 0);
    signal bdo_type_c: std_logic_vector(3 downto 0);
begin
    ----------------------------------------------------------------------------
    -- Register slices (BtoI). Both handshakes with the frozen wrapper end in registers here:
    -- bdi_ready and bdo_valid are flip-flop outputs, and the loader sees a registered word (data, type,
    -- size, eot, decrypt flag) and a registered "output has room". One cycle of latency each way, full
    -- rate (one word per cycle) in steady state.
    ----------------------------------------------------------------------------
    in_w <= bdi & bdi_valid_bytes & bdi_size & bdi_eot & bdi_type & decrypt_in;
    bdi_ready <= not is_v;
    bdi_valid_i <= ih_v;
    bdi_i       <= ih(IW-1 downto IW-CCW);
    bdi_vb_i    <= ih(IW-CCW-1 downto IW-CCW-CCWdiv8);
    bdi_size_i  <= ih(8 downto 6);
    bdi_eot_i   <= ih(5);
    bdi_type_i  <= ih(4 downto 1);
    decrypt_i   <= ih(0);

    p_in_slice: process(clk)
    begin
        if rising_edge(clk) then
            if ih_v = '0' or bdi_ready_c = '1' then
                if is_v = '1' then
                    ih <= is_w;
                    ih_v <= '1';
                    is_v <= '0';
                elsif bdi_valid = '1' then
                    ih <= in_w;
                    ih_v <= '1';
                else
                    ih_v <= '0';
                end if;
            elsif bdi_valid = '1' and is_v = '0' then
                is_w <= in_w;
                is_v <= '1';
            end if;
            if rst = '1' then
                ih_v <= '0';
                is_v <= '0';
            end if;
        end if;
    end process;

    out_w <= bdo_s & bdo_vb_c & bdo_type_c & eob_c;
    bdo_ready_c <= not os_v;
    bdo_valid <= oh_v;
    bdo <= oh(OW-1 downto OW-CCW);
    bdo_valid_bytes <= oh(OW-CCW-1 downto OW-CCW-CCWdiv8);
    bdo_type <= oh(4 downto 1);
    end_of_block <= oh(0);

    p_out_slice: process(clk)
    begin
        if rising_edge(clk) then
            if oh_v = '0' or bdo_ready = '1' then
                if os_v = '1' then
                    oh <= os_w;
                    oh_v <= '1';
                    os_v <= '0';
                elsif bdo_valid_c = '1' then
                    oh <= out_w;
                    oh_v <= '1';
                else
                    oh_v <= '0';
                end if;
            elsif bdo_valid_c = '1' and os_v = '0' then
                os_w <= out_w;
                os_v <= '1';
            end if;
            if rst = '1' then
                oh_v <= '0';
                os_v <= '0';
            end if;
        end if;
    end process;

    ELEPHANT_DATAP: entity work.elephant_datapath
        port map(
            key        => key,
            bdi        => bdi_i,
            bdi_size => bdi_size_intern,
            data_type_sel => data_type_sel,

            load_data_en  => load_data_en,
            load_data_sel => load_data_sel,
            load_buf => load_buf,

            iss_kind => iss_kind,
            iss_buf => iss_buf_s,
            b_ld => b_ld,
            rc => rc,
            res_en => res_en,
            res_u => res_u,

            key_en => key_en,
            tag_en => tag_en,
            tag_sel => tag_sel,
            ks_push => ks_push,
            ks_pop => ks_pop,
            ks_adv => ks_adv,
            ks_cnt => ks_cnt,
            ks_clr => op_clr,
            npub_en => npub_en,

            mac_load => mac_load,
            mac_step => mac_step,
            ks_load => ks_load,
            ks_step => ks_step,

            bdo => bdo_s,
            bdo_sel => bdo_sel,
            saving_bdo => saving_bdo,
            data_count => data_cnt_int,
            clk        => clk
        );

    more <= '1' when done_state = '0' or append_one = '1' else '0';

    -- busy probes per register (profile.txt): g_busy(p)/busy = register p holds a live call
    g_busy: for p in 0 to NSLOT-1 generate
        signal busy: std_logic;
    begin
        busy <= v(p);
    end generate;

    gen_ld: for u in 0 to NUNIT-1 generate
        b_ld(u) <= '1' when b_v = '1' and b_p = u * NSTAGE else '0';
    end generate;
    iss_buf_s <= '1' when iss_buf = 1 else '0';
    key_en <= '1' when res_v = '1' and res_kind = K_KEY else '0';
    ks_push <= '1' when res_v = '1' and res_kind = K_KS and op_clr = '0' else '0';
    mac_load <= '1' when mac_st = 1 or mac_st = 6 else '0';
    mac_step <= '1' when mac_st = 2 or mac_st = 3 or mac_st = 4 or mac_st = 7 or mac_st = 8 or
                         (iss_v = '1' and (iss_kind = K_AD or iss_kind = K_MAC)) else '0';
    ks_load <= '1' when ks_st = 1 else '0';
    ks_step <= '1' when ks_st = 2 or (iss_v = '1' and iss_kind = K_KS) else '0';

    tag_ctl: process(all)
    begin
        tag_en <= '0';
        tag_sel <= "00";
        if fsm_tag_reset = '1' then
            tag_en <= '1';
        elsif fsm_tag_init = '1' then
            tag_en <= '1';
            tag_sel <= "01";
        elsif res_v = '1' and (res_kind = K_AD or res_kind = K_MAC) then
            tag_en <= '1';
            tag_sel <= "10";
        elsif res_v = '1' and res_kind = K_FIN then
            tag_en <= '1';
            tag_sel <= "11";
        end if;
    end process;

state_control: process(all)
    variable seg_ok: boolean;              -- the slice's head word is of the expected segment
    variable pk_ok: boolean;               -- the wrapper shows the expected segment (slice empty)
    variable adv: boolean;                 -- a word went into the buffer this cycle
    variable used: boolean;                -- this message block used the keystream head
    variable nd, na: std_logic;            -- done_state / append_one after this cycle
    variable nmore: std_logic;
begin
    bdo_valid_c <= '0';
    bdo_vb_c <= bdi_vb_i;
    bdo_type_c <=(others => '0');
    bdo_sel <= '0';
    saving_bdo <= '0';
    msg_auth <= '0';
    msg_auth_valid <= '0';
    eob_c <= '0';

    key_ready <= '0';
    bdi_ready_c <= '0';
    bdi_size_intern <= bdi_size_i(1 downto 0);
    data_type_sel <= '0';

    load_data_en <= '0';
    load_data_sel <= "00";
    load_buf <= '0';
    npub_en <= '0';

    key_req_set <= '0';
    key_clr <= '0';
    blk_full <= '0';
    ks_pop <= '0';
    ks_adv <= '0';
    ad_end <= '0';
    msg_end <= '0';
    op_clr <= '0';
    fsm_tag_reset <= '0';
    fsm_tag_init <= tag_init_d;            -- v2: N||AD0 initializes the tag
    n_tag_init_d <= '0';

    n_ctl_s <= ctl_s;
    n_fill_active <= fill_active;
    n_fill_msg <= fill_msg;
    n_fb <= fb;
    n_seg_chk <= seg_chk;
    n_ks_used <= ks_used;
    n_wait_cnt <= wait_cnt;
    n_done_state <= done_state;
    n_append_one <= append_one;
    n_first_blk <= first_blk;
    n_decrypt_op <= decrypt_op;
    n_tag_verified <= tag_verified;
    n_data_cnt_int <= data_cnt_int;

    ----------------------------------------------------------------------------
    -- Main FSM. It touches data_cnt_int / load_data / bdi_i only while the loader is idle.
    ----------------------------------------------------------------------------
    case ctl_s is
    when IDLE =>
        op_clr <= '1';
        n_tag_verified <= '1';
        fsm_tag_reset <= '1';
        n_data_cnt_int <= 0;
        n_done_state <= '0';
        n_append_one <= '0';
        n_first_blk <= '1';
        n_fill_active <= '0';
        n_fill_msg <= '0';
        n_fb <= 0;
        n_seg_chk <= '0';
        n_ks_used <= '0';
        n_wait_cnt <= 0;
        if bdi_valid_i = '1' or key_valid = '1' then
            if key_update = '1' then
                n_ctl_s <= STORE_KEY;
            else
                n_ctl_s <= LOAD_NONCE;
            end if;
        end if;
    when STORE_KEY =>
        -- K || 0 into input buffer 0, then the key call
        key_clr <= '1';
        if data_cnt_int < KEY_SIZE then
            if key_valid = '1' then
                n_data_cnt_int <= data_cnt_int + 1;
                key_ready <= '1';
                load_data_en <= '1';
                data_type_sel <= '1'; --select key type
                load_data_sel <= "01";
            end if;
        elsif data_cnt_int < BLOCK_SIZE then
            n_data_cnt_int <= data_cnt_int + 1;
            load_data_sel <= "00"; --zero pad
            load_data_en <= '1';
        else
            key_req_set <= '1';
            n_ctl_s <= KEY_ISS;
        end if;
    when KEY_ISS =>
        -- buffer 0 is read when the key call is loaded; the nonce goes there afterwards
        if key_req = '0' and iss_v = '0' then
            n_data_cnt_int <= 0;
            n_ctl_s <= LOAD_NONCE;
        end if;
    when LOAD_NONCE =>
        if data_cnt_int < ELE_NPUB_SIZE then
            if bdi_valid_i = '1' then
                n_data_cnt_int <= data_cnt_int + 1;
                n_decrypt_op <= decrypt_i;
                bdi_ready_c <= '1';
                load_data_en <= '1';
                load_data_sel <= "01";
            end if;
        else
            npub_en <= '1';
            n_ctl_s <= RUN;
            n_fill_active <= '1';   -- loader fills N||AD0 from word 3
            n_fill_msg <= '0';
            n_fb <= 0;
            n_seg_chk <= '1';
            n_wait_cnt <= 0;
        end if;
    when RUN =>
        if fin_done = '1' then
            n_data_cnt_int <= 0;
            n_ctl_s <= TAG_S;
        end if;
    when TAG_S =>
        bdo_sel <= '1';
        if decrypt_op /= '1' then
            bdo_vb_c <= (others => '1');
            bdo_type_c <= HDR_TAG;
            if bdo_ready_c = '1' then
                bdo_valid_c <= '1';
                n_data_cnt_int <= data_cnt_int + 1;
                if data_cnt_int = ELE_TAG_SIZE-1 then
                    eob_c <= '1';
                    n_ctl_s <= IDLE;
                end if;
            end if;
        else
            if bdi_valid_i = '1' and msg_auth_ready = '1' then
                bdi_ready_c <= '1';
                n_data_cnt_int <= data_cnt_int + 1;
                if data_cnt_int = ELE_TAG_SIZE-1 then
                    n_ctl_s <= IDLE;
                    msg_auth_valid <= '1';
                    if (bdi_i /= bdo_s) then
                        msg_auth <= '0';
                    else
                        msg_auth <= tag_verified;
                    end if;
                else
                    if bdi_i /= bdo_s then
                        n_tag_verified <= '0';
                    end if;
                end if;
            end if;
        end if;
    end case;

    ----------------------------------------------------------------------------
    -- Loader: fills blocks into buffer fb, then the other buffer. Fast: the block is complete in the
    -- cycle its last word goes in (data_cnt = BLOCK_SIZE-1); BLOCK_SIZE+1 = waiting for a free buffer.
    ----------------------------------------------------------------------------
    if fill_active = '1' then
        adv := false;
        used := ks_used = '1';
        nd := done_state;
        na := append_one;
        if data_cnt_int < BLOCK_SIZE then
            if fb = 1 then
                load_buf <= '1';
            end if;
            seg_ok := bdi_valid_i = '1' and ((fill_msg = '0' and bdi_type_i = HDR_AD) or
                      (fill_msg = '1' and (bdi_type_i = HDR_PT or bdi_type_i = HDR_CT)));
            pk_ok := (fill_msg = '0' and bdi_type = HDR_AD) or
                     (fill_msg = '1' and (bdi_type = HDR_PT or bdi_type = HDR_CT));
            if seg_chk = '1' and not seg_ok then
                -- first block of a segment: wait for the segment, or decide it is empty. A word of
                -- another type at the head of the slice, or (slice empty) another type shown by the
                -- wrapper, or SEG_WAIT cycles of none, means the segment is empty. The peek at the
                -- wrapper's bdi_type only reaches these state bits, never the word accept below.
                if bdi_valid_i = '1' or (bdi_type /= "0000" and not pk_ok) or wait_cnt = SEG_WAIT then
                    n_seg_chk <= '0';
                    nd := '1';
                    na := '1';
                elsif bdi_type = "0000" then
                    n_wait_cnt <= wait_cnt + 1;
                end if;
            elsif fill_msg = '0' then
                n_seg_chk <= '0';
                -- AD (block 0 = N||AD0 continues from word 3)
                if done_state /= '1' and append_one /= '1' and (first_blk = '0' or bdi_valid_i = '0' or bdi_type_i = HDR_AD) then
                    if bdi_valid_i = '1' and bdi_type_i = HDR_AD then
                        bdi_ready_c <= '1';
                        adv := true;
                        load_data_en <= '1';
                        if bdi_vb_i = "1111" then
                            load_data_sel <= "01";
                        else
                            load_data_sel <= "10";
                        end if;
                        if bdi_eot_i = '1' then
                            if (data_cnt_int = BLOCK_SIZE-1 and bdi_vb_i = "1111") = False then
                                nd := '1';
                            end if;
                            if bdi_vb_i = "1111" then
                                na := '1';
                            end if;
                        end if;
                    end if;
                else
                    adv := true;
                    load_data_en <= '1';
                    if append_one = '1' or done_state = '0' then
                        load_data_sel <= "10";      -- 0x01 padding byte
                        bdi_size_intern <= "00";
                        na := '0';
                        nd := '1';
                    else
                        load_data_sel <= "00";      -- zero pad
                    end if;
                end if;
            else
                n_seg_chk <= '0';
                -- Message: out word = in word xor keystream head; the buffer keeps the ciphertext
                if done_state /= '1' and append_one /= '1' then
                    if bdi_valid_i = '1' and bdo_ready_c = '1' and (bdi_type_i = HDR_PT or bdi_type_i = HDR_CT)
                       and ks_cnt /= 0 then
                        used := true;
                        ks_adv <= '1';              -- the keystream head moves to its next word
                        bdi_ready_c <= '1';
                        bdo_vb_c <= bdi_vb_i;
                        bdo_valid_c <= '1';
                        adv := true;
                        load_data_en <= '1';
                        if bdi_vb_i = "1111" then
                            load_data_sel <= "01";
                        else
                            load_data_sel <= "10";
                        end if;
                        if bdi_type_i = HDR_PT then
                            bdo_type_c <= HDR_CT;
                            saving_bdo <= '1';
                        else
                            bdo_type_c <= HDR_PT;
                        end if;
                        if bdi_eot_i = '1' then
                            nd := '1';
                            if bdi_vb_i = "1111" then
                                na := '1';
                            end if;
                        end if;
                    end if;
                else
                    adv := true;
                    load_data_en <= '1';
                    if append_one = '1' then
                        load_data_sel <= "10";      -- 0x01 padding byte
                        bdi_size_intern <= "00";
                        na := '0';
                        nd := '1';
                    else
                        load_data_sel <= "00";      -- zero pad
                    end if;
                end if;
            end if;

            if adv then
                n_data_cnt_int <= data_cnt_int + 1;
            end if;
            if used then
                n_ks_used <= '1';
            end if;
            n_done_state <= nd;
            n_append_one <= na;

            if adv and data_cnt_int = BLOCK_SIZE-1 then
                -- the block in buffer fb is complete at the end of this cycle
                if nd = '0' or na = '1' then nmore := '1'; else nmore := '0'; end if;
                if first_blk = '1' then
                    n_tag_init_d <= '1';
                    n_first_blk <= '0';
                else
                    blk_full <= '1';
                end if;
                if used then
                    ks_pop <= '1';
                    n_ks_used <= '0';
                end if;
                if nmore = '0' and fill_msg = '0' then
                    ad_end <= '1';                  -- AD done: the message follows
                    n_fill_msg <= '1';
                    n_done_state <= '0';
                    n_append_one <= '0';
                    n_seg_chk <= '1';
                    n_wait_cnt <= 0;
                end if;
                if nmore = '0' and fill_msg = '1' then
                    msg_end <= '1';                 -- last message block
                    n_fill_active <= '0';
                elsif bst(1-fb) = '0' then
                    n_fb <= 1 - fb;
                    n_data_cnt_int <= 0;
                else
                    n_data_cnt_int <= BLOCK_SIZE + 1;
                end if;
            end if;
        else
            -- waiting for the other buffer
            if bst(1-fb) = '0' then
                n_fb <= 1 - fb;
                n_data_cnt_int <= 0;
            end if;
        end if;
    end if;
end process;

p_reg: process(clk)
begin
    if rising_edge(clk) then
        data_cnt_int <= n_data_cnt_int;
        wait_cnt <= n_wait_cnt;
        fb <= n_fb;
        tag_init_d <= n_tag_init_d;
        if rst = '1' then
            ctl_s <= IDLE;
            done_state <= '0';
            decrypt_op <= '0';
            tag_verified <= '0';
            append_one <= '0';
            first_blk <= '1';
            fill_active <= '0';
            fill_msg <= '0';
            seg_chk <= '0';
            ks_used <= '0';
        else
            ctl_s <= n_ctl_s;
            done_state <= n_done_state;
            decrypt_op <= n_decrypt_op;
            tag_verified <= n_tag_verified;
            append_one <= n_append_one;
            first_blk <= n_first_blk;
            fill_active <= n_fill_active;
            fill_msg <= n_fill_msg;
            seg_chk <= n_seg_chk;
            ks_used <= n_ks_used;
        end if;
    end if;
end process;

--------------------------------------------------------------------------------
-- Issue engine. A call decided in cycle t is prepared in t+1 (stage A: iss_*, x -> xr), loaded at the
-- end of t+2 (stage B: b_*) and sits in register b_p from t+3 with pc = 0. It finishes PERM_CYCLES
-- cycles later; its result is captured at the end of that cycle and used one cycle after.
--------------------------------------------------------------------------------
p_issue: process(clk)
    variable fp: integer range 0 to NSLOT;
    variable q, src: integer range 0 to NSLOT-1;
    variable k: std_logic_vector(2 downto 0);
    variable go: boolean;
    variable rn: std_logic;
    variable ri: integer range 0 to NSLOT-1;
    variable tinc, tdec, kinc, kdec, cinc, cdec: integer range 0 to 1;
    variable ad_pend, fin_ok, buf_ok, ks_ok: boolean;
begin
    if rising_edge(clk) then
        -- registers: load the stage-B call, or take the call from the previous stage of the ring
        for p in 0 to NSLOT-1 loop
            if b_v = '1' and b_p = p then
                v(p) <= '1';
                pc(p) <= 0;
                rc(p) <= RC_TAB(0);
                kd(p) <= b_kind;
            else
                if v(prv(p)) = '1' and pc(prv(p)) /= PERM_CYCLES-1 then
                    v(p) <= '1';
                    pc(p) <= pc(prv(p)) + 1;
                else
                    v(p) <= '0';
                    pc(p) <= 0;
                end if;
                rc(p) <= RC_TAB(pc(prv(p)) + 1);
                kd(p) <= kd(prv(p));
            end if;
        end loop;

        -- a call finishing now is unmasked next cycle
        res_v <= res_en;
        res_kind <= kd(res_i);

        -- a call finishing next cycle (always in a last stage, from stage NSTAGE-2 or, with one stage,
        -- staying in place)
        rn := '0';
        ri := NSTAGE - 1;
        for p in 0 to NSLOT-1 loop
            if p mod NSTAGE = NSTAGE-1 and not (b_v = '1' and b_p = p) and
               v(prv(p)) = '1' and pc(prv(p)) = PERM_CYCLES-2 then
                rn := '1';
                ri := p;
            end if;
        end loop;
        res_en <= rn;
        res_i <= ri;
        res_u <= ri / NSTAGE;

        -- stage A -> stage B; the call sits in b_p two cycles from now
        b_v <= iss_v;
        b_p <= iss_p;
        b_kind <= iss_kind;

        -- results
        tdec := 0;
        kinc := 0;
        if res_v = '1' then
            if res_kind = K_KEY then
                key_rdy <= '1';
            elsif res_kind = K_AD or res_kind = K_MAC then
                tdec := 1;
            elsif res_kind = K_KS then
                kinc := 1;
            elsif res_kind = K_FIN then
                fin_done <= '1';
            end if;
        end if;

        -- loader events
        if blk_full = '1' then
            bst(fb) <= '1';
            bkd(fb) <= fill_msg;
        end if;
        if key_req_set = '1' then
            key_req <= '1';
        end if;
        if key_clr = '1' then
            key_rdy <= '0';
        end if;
        if ad_end = '1' then
            msg_phase <= '1';
        end if;
        if msg_end = '1' then
            msg_done <= '1';
        end if;
        kdec := 0;
        cdec := 0;
        if ks_pop = '1' then
            kdec := 1;
            cdec := 1;
        end if;

        -- mask windows (masks are read in stage A)
        ad_pend := (bst(0) = '1' and bkd(0) = '0') or (bst(1) = '1' and bkd(1) = '0');
        case mac_st is
            when 0 =>
                if ctl_s = RUN and key_rdy = '1' then mac_st <= 1; end if;
            when 1 | 2 | 3 | 6 | 7 =>
                mac_st <= mac_st + 1;
            when 4 =>
                mac_st <= 5;
            when 5 =>
                if msg_phase = '1' and not ad_pend and not (iss_v = '1' and iss_kind = K_AD) then
                    mac_st <= 6;
                end if;
            when 8 =>
                mac_st <= 9;
            when others =>
                null;
        end case;
        case ks_st is
            when 0 =>
                if ctl_s = RUN and key_rdy = '1' then ks_st <= 1; end if;
            when 1 | 2 =>
                ks_st <= ks_st + 1;
            when others =>
                null;
        end case;

        -- decide one call, to be loaded into register fp at the end of t+2. It replaces whatever reaches
        -- fp then, i.e. the call in q = prv(fp) during t+2, which is now in src = prv(prv(q)) unless the
        -- stage-A call (loaded into q at the end of t+1) or the stage-B call (into prv(q) at the end of
        -- t, then in q) is there. It must be absent or in its last round group by then.
        fp := NSLOT;
        for p in NSLOT-1 downto 0 loop
            next when p mod NSTAGE /= 0;            -- stage 0 only
            q := prv(p);
            src := prv(prv(q));
            if not (iss_v = '1' and iss_p = q) and not (b_v = '1' and b_p = prv(q)) and
               (v(src) = '0' or pc(src) >= PERM_CYCLES-3) then
                fp := p;
            end if;
        end loop;
        fin_ok := msg_done = '1' and bst = "00" and tag_infl = 0 and fin_issued = '0';
        buf_ok := bst(ip) = '1' and key_rdy = '1' and
                  ((bkd(ip) = '0' and mac_st = 5) or (bkd(ip) = '1' and mac_st = 9));
        ks_ok := ks_st = 3 and ks_cred < NKS and ctl_s = RUN and msg_done = '0';
        go := false;
        tinc := 0;
        cinc := 0;
        k := K_KEY;
        iss_v <= '0';
        if fp < NSLOT then
            if key_req = '1' then
                k := K_KEY;
                iss_buf <= 0;
                key_req <= '0';
                go := true;
            elsif fin_ok then
                k := K_FIN;
                fin_issued <= '1';
                go := true;
            elsif buf_ok then
                if bkd(ip) = '1' then k := K_MAC; else k := K_AD; end if;
                iss_buf <= ip;
                bst(ip) <= '0';
                ip <= 1 - ip;
                tinc := 1;
                go := true;
            elsif ks_ok then
                k := K_KS;
                cinc := 1;
                go := true;
            end if;
            if go then
                iss_v <= '1';
                iss_p <= fp;
                iss_kind <= k;
            end if;
        end if;

        tag_infl <= tag_infl + tinc - tdec;
        ks_cred <= ks_cred + cinc - cdec;
        ks_cnt <= ks_cnt + kinc - kdec;

        if rst = '1' or op_clr = '1' then
            v <= (others => '0');
            iss_v <= '0';
            b_v <= '0';
            res_en <= '0';
            res_v <= '0';
            bst <= "00";
            ip <= 1;
            key_req <= '0';
            fin_issued <= '0';
            fin_done <= '0';
            msg_phase <= '0';
            msg_done <= '0';
            ks_cred <= 0;
            ks_cnt <= 0;
            tag_infl <= 0;
            mac_st <= 0;
            ks_st <= 0;
        end if;
        if rst = '1' then
            key_rdy <= '0';
        end if;
    end if;
end process;
end behavioral;
