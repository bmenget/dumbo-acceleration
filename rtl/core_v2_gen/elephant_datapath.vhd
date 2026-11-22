--------------------------------------------------------------------------------
-- core_v2_gen datapath. Derived from GMU's elephant_datapath.vhd (GPL v3).
--
-- G_U units, each a ring of G_S stage registers with G_RPS rounds between consecutive registers.
-- Slot q = u*G_S + p is unit u's stage register p. During PERM every register takes the output of the
-- stage behind it in the ring, so a call moves one register forward per cycle; all calls are loaded
-- together and every stage computes the same rounds each cycle (pass = perm_count).
-- After PERM_CYCLES cycles the call loaded into slot i sits in slot res(i) (offset G_ROT within its unit).
-- In the last pass a stage uses its tap (G_TAIL rounds) when G_RPS does not divide 80.
--
-- Logical slot i (where a call was loaded) chooses source and mask by mode; window w(j) = phi^(a-1+j):
--   mode  slot i                             condition
--   KEY   buf(0)                             i = 0
--   AD    buf(i) ^ w(i)                      all slots (AD blocks j..j+N-1, a = j+1)
--   KS0   N ^ w(i) ^ w(i+1)                  i < 2M (N = 1: i = 0)     (KS(i), a = 1)
--   MSG   buf(i) ^ w(i) ^ w(i+2)             i < max(M,1)              (MAC(k+i), a = k+1)
--         N ^ w(M+i) ^ w(M+i+1)              M <= i < 2M               (KS(k+M+i), a = k+1)
--   KS1   N ^ w(1) ^ w(2)                    N = 1, i = 0              (KS(k+1), a = k+1)
--   FIN   tag ^ L                            i = 0
-- With unmask = '1' a slot's result is xored with the same mask in place (source = its own register).
-- The tag then accumulates the selected (already unmasked) results in a separate cycle, so the mux
-- network and the wide XOR are never in one path.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.elephant_constants.all;
use work.Design_pkg.all;

entity elephant_datapath is
    port(
        key: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi: in std_logic_vector(CCW_SIZE-1 downto 0);
        bdi_size: in std_logic_vector(1 downto 0);
        data_type_sel: std_logic;

        load_data_en: in std_logic;
        load_data_sel: in std_logic_vector(1 downto 0);
        load_buf: in integer range 0 to G_N-1;           -- input buffer the loader writes

        mode: in std_logic_vector(2 downto 0);
        unmask: in std_logic;
        ld: in std_logic_vector(G_N-1 downto 0);         -- per logical slot: load (or unmask in place)
        te: in std_logic_vector(G_N-1 downto 0);         -- per logical slot: xor its result into the tag
        tag_from_buf: in std_logic;                      -- xor input buffer 0 into the tag (AD block 0)
        ks_en: in std_logic;
        ks_from_kslots: in std_logic;                    -- '1': ks(j) <= slot M+j, '0': ks(j) <= slot j
        ks_buf_sel: in integer range 0 to G_NKS-1;       -- keystream buffer the message words use
        tag_word: out std_logic_vector(CCW_SIZE-1 downto 0);  -- expected tag word for the decrypt check

        key_en: in std_logic;
        npub_en: in std_logic;
        tag_en: in std_logic;
        tag_reset: in std_logic;

        perm_en: in std_logic;

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
    subtype st_t is std_logic_vector(STATE_SIZE-1 downto 0);
    type slot_arr is array (0 to G_N-1) of st_t;
    type ks_arr is array (0 to G_NKS-1) of st_t;
    type win_arr is array (0 to G_NMASK-1) of st_t;
    constant ZERO: st_t := (others => '0');

    -- slot index helpers (elaboration time)
    function res_of(i: integer) return integer is      -- where logical slot i's result ends
    begin
        return (i / G_S) * G_S + ((i mod G_S) + G_ROT) mod G_S;
    end function;
    function lg_of(q: integer) return integer is       -- which logical slot's result sits in q
    begin
        return (q / G_S) * G_S + ((q mod G_S) - G_ROT + G_S) mod G_S;
    end function;
    function prv_of(q: integer) return integer is      -- the register feeding q's stage input
    begin
        return (q / G_S) * G_S + ((q mod G_S) - 1 + G_S) mod G_S;
    end function;

    signal r, rn, sout, stap, srcv, maskv, ib: slot_arr;
    signal ks: ks_arr;
    signal w: win_arr;
    signal datap_lfsr_out: std_logic_vector(LFSR_W-1 downto 0);
    signal pass: integer range 0 to PERM_CYCLES-1;
    signal last_pass: std_logic;

    signal nonce_blk: st_t;
    signal ks_cur: st_t;

    signal bdi_or_key: std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_key_rev : std_logic_vector(CCW_SIZE-1 downto 0);
    signal bdi_or_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal padding_bdi: std_logic_vector(CCW_SIZE-1 downto 0);
    signal load_data_input_mux: std_logic_vector(CCW_SIZE-1 downto 0);

    signal key_out: st_t;
    signal npub_out: std_logic_vector(NPUB_SIZE_BITS-1 downto 0);
    signal tag_out: st_t;
    signal tag_input: st_t;

    signal ms_out_mux2: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_out_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    signal data_bdo: std_logic_vector(CCW_SIZE-1 downto 0);
    signal tag_mux: std_logic_vector(CCW_SIZE-1 downto 0);
    signal tag_reg: st_t;

begin
    assert G_R mod G_S = 0
        report "core_v2_gen: G_S must divide G_R (equal pipeline stages)" severity failure;

    pass <= perm_count when perm_count < PERM_CYCLES else PERM_CYCLES - 1;
    last_pass <= '1' when perm_count = PERM_CYCLES - 1 else '0';

    ----------------------------------------------------------------------------
    -- stages and slot registers
    ----------------------------------------------------------------------------
    gen_stage: for q in 0 to G_N-1 generate
        ST: entity work.elephant_stage
            generic map(NR => G_RPS, TAILR => G_TAIL, NPASS => PERM_CYCLES)
            port map(din => r(q), pass => pass, dout => sout(q), dtap => stap(q));
    end generate;

    gen_next: for q in 0 to G_N-1 generate
        g_full: if G_TAIL = G_RPS generate
            rn(q) <= sout(prv_of(q));
        end generate;
        g_tap: if G_TAIL /= G_RPS generate
            rn(q) <= stap(prv_of(q)) when last_pass = '1' else sout(prv_of(q));
        end generate;
    end generate;

    gen_reg: for q in 0 to G_N-1 generate
        constant LQ: integer := lg_of(q);
        signal en_q: std_logic;
        signal d_q: st_t;
    begin
        -- loads go to the slot's own register; unmasking acts on the register holding its result
        en_q <= ld(LQ) when unmask = '1' else ld(q);
        d_q  <= (r(q) xor maskv(LQ)) when unmask = '1' else (srcv(q) xor maskv(q));
        p_slot: process(clk)
        begin
            if rising_edge(clk) then
                if perm_en = '1' then
                    r(q) <= rn(q);
                elsif en_q = '1' then
                    r(q) <= d_q;
                end if;
            end if;
        end process;
    end generate;

    ----------------------------------------------------------------------------
    -- per-slot source and mask (table at the top); index ranges are guarded by generates
    ----------------------------------------------------------------------------
    nonce_blk <= x"0000000000000000" & npub_out;

    gen_mux: for i in 0 to G_N-1 generate
        signal m_ks0, m_msg, m_ks1, m_fin: st_t;
        signal s_ad, s_ks, s_msg: st_t;
    begin
        -- masks
        g_ks0: if i < 2*G_M or (G_N = 1 and i = 0) generate
            m_ks0 <= w(i) xor w(i+1);
        end generate;
        g_ks0n: if not (i < 2*G_M or (G_N = 1 and i = 0)) generate
            m_ks0 <= ZERO;
        end generate;
        g_mac: if i < G_NKS generate
            m_msg <= w(i) xor w(i+2);
            s_msg <= ib(i);
        end generate;
        g_kss: if i >= G_NKS and i < 2*G_M generate
            m_msg <= w(G_M+i) xor w(G_M+i+1);
            s_msg <= nonce_blk;
        end generate;
        g_none: if i >= G_NKS and i >= 2*G_M generate
            m_msg <= ZERO;
            s_msg <= nonce_blk;
        end generate;
        g_s0: if i = 0 generate
            m_ks1 <= w(1) xor w(2);
            m_fin <= key_out;
        end generate;
        g_sn: if i /= 0 generate
            m_ks1 <= ZERO;
            m_fin <= ZERO;
        end generate;

        with mode select
            maskv(i) <= w(i)   when MD_AD,
                        m_ks0  when MD_KS0,
                        m_msg  when MD_MSG,
                        m_ks1  when MD_KS1,
                        m_fin  when MD_FIN,
                        ZERO   when others;

        -- sources
        g_src0: if i = 0 generate
            with mode select
                srcv(i) <= tag_out   when MD_FIN,
                           nonce_blk when MD_KS0 | MD_KS1,
                           ib(0)     when others;     -- KEY, AD, MSG (MAC)
        end generate;
        g_srcn: if i /= 0 generate
            with mode select
                srcv(i) <= ib(i)     when MD_AD,
                           s_msg     when MD_MSG,
                           nonce_blk when others;
        end generate;
    end generate;

    ----------------------------------------------------------------------------
    -- mask LFSR window
    ----------------------------------------------------------------------------
    DATAP_LFSR: entity work.elephant_datapath_lfsr
        port map(
            load_key    => datap_lfsr_load,
            clk         => clk,
            key_in      => key_out,
            en          => datap_lfsr_en,
            step        => datap_lfsr_step,
            ele_lfsr_output => datap_lfsr_out
        );
    gen_win: for j in 0 to G_NMASK-1 generate
        w(j) <= datap_lfsr_out(8*j + STATE_SIZE-1 downto 8*j);
    end generate;

    ----------------------------------------------------------------------------
    -- key, nonce, tag, keystream buffers
    ----------------------------------------------------------------------------
    -- L = P(K||0) runs in slot 0; taken straight from the permutation in its last cycle
    p_key_reg: process(clk)
    begin
        if rising_edge(clk) then
            if key_en = '1' then
                key_out <= rn(res_of(0));
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

    p_tag_in: process(all)
        variable acc: st_t;
    begin
        acc := tag_out;
        if tag_from_buf = '1' then
            acc := acc xor ib(0);
        end if;
        for i in 0 to G_N-1 loop
            if te(i) = '1' then
                acc := acc xor r(res_of(i));
            end if;
        end loop;
        if tag_reset = '1' then
            tag_input <= (others => '0');
        else
            tag_input <= acc;
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

    p_ks: process(clk)
    begin
        if rising_edge(clk) then
            if ks_en = '1' then
                for j in 0 to G_NKS-1 loop
                    -- j < max(M,1), so M+j < N (N = 1: M+j = 0)
                    if ks_from_kslots = '1' then
                        ks(j) <= r(res_of(G_M + j));
                    else
                        ks(j) <= r(res_of(j));
                    end if;
                end loop;
            end if;
        end if;
    end process;
    ks_cur <= ks(ks_buf_sel);

    ----------------------------------------------------------------------------
    -- input block buffers (word shift registers)
    ----------------------------------------------------------------------------
    p_load_data: process(clk)
    begin
        if rising_edge(clk) then
            if load_data_en = '1' then
                if load_buf = 0 and load_data_sel = "11" then
                    ib(0) <= x"0000000000000000" & npub_out;
                else
                    for b in 0 to G_N-1 loop
                        if load_buf = b then
                            ib(b) <= load_data_input_mux & ib(b)(STATE_SIZE-1 downto CCW_SIZE);
                        end if;
                    end loop;
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
        ms_out_mux2 <= ks_cur(CCW-1 downto 0) when 0,
                       ks_cur((2*CCW)-1 downto CCW) when 1,
                       ks_cur((3*CCW)-1 downto 2*CCW) when 2,
                       ks_cur((4*CCW)-1 downto 3*CCW) when 3,
                       ks_cur((5*CCW)-1 downto 4*CCW) when others;
    data_bdo <= bdi_or_key_rev xor ms_out_mux2;
    bdo <= reverse_byte(data_out_mux);
    -- v2: the tag is trunc64 of the final result, held in slot 0's result register
    tag_reg <= r(res_of(0));
    tag_mux <= tag_reg(63 downto 32) when data_count = 1 else tag_reg(31 downto 0);
    data_out_mux <= data_bdo when bdo_sel ='0' else tag_mux;
    tag_word <= reverse_byte(tag_mux);

end behavioral;
