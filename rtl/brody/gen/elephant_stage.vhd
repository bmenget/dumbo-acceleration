--------------------------------------------------------------------------------
-- brody/gen: one pipeline stage of a Spongent-pi[160] unit: NR rounds, combinational.
-- Replaces GMU's elephant_perm.vhd (whose round-constant tables only covered 1, 4, 5, 8, 10, 16 rounds
-- per cycle): the round constants are computed at elaboration from the 7-bit Spongent LFSR, so any NR works.
--
-- All calls in a unit advance in lockstep, so in pass p (0 .. NPASS-1) every stage computes rounds
-- p*NR .. p*NR+NR-1. dout is the state after NR rounds; dtap is the state after TAILR rounds, used in the
-- last pass when NR does not divide 80.
-- Round: XOR the round constant into the low 7 bits and its bit-reversal into the high 7 bits,
-- 40 4-bit S-boxes, bit permutation (bit j -> 40*j mod 159, bit 159 fixed).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.elephant_constants.all;

entity elephant_stage is
    generic(
        NR    : positive;   -- rounds in this stage
        TAILR : positive;   -- rounds that count in the last pass
        NPASS : positive    -- passes per call
    );
    port(
        din  : in  std_logic_vector(STATE_SIZE-1 downto 0);
        pass : in  integer range 0 to NPASS-1;
        dout : out std_logic_vector(STATE_SIZE-1 downto 0);
        dtap : out std_logic_vector(STATE_SIZE-1 downto 0)
    );
end elephant_stage;

architecture behavioral of elephant_stage is
    type rc_arr is array (0 to NPASS*NR-1) of std_logic_vector(6 downto 0);

    function rc_table return rc_arr is
        variable t: rc_arr;
        variable l: std_logic_vector(6 downto 0) := "1110101";
    begin
        for i in 0 to NPASS*NR-1 loop
            if i < 80 then
                t(i) := l;
            else
                t(i) := (others => '0');   -- rounds past 80 are never used (tap)
            end if;
            l := l(5 downto 0) & (l(6) xor l(5));
        end loop;
        return t;
    end function;
    constant RC: rc_arr := rc_table;

    type sbox_t is array (0 to 15) of std_logic_vector(3 downto 0);
    constant SBOX: sbox_t := (x"e", x"d", x"b", x"0", x"2", x"1", x"4", x"f",
                              x"7", x"a", x"8", x"5", x"9", x"c", x"3", x"6");

    function spongent_round(s: std_logic_vector(STATE_SIZE-1 downto 0); rc: std_logic_vector(6 downto 0))
        return std_logic_vector is
        variable a, b, p: std_logic_vector(STATE_SIZE-1 downto 0);
        variable rrc: std_logic_vector(6 downto 0);
    begin
        for k in 0 to 6 loop
            rrc(k) := rc(6-k);
        end loop;
        a := s;
        a(6 downto 0) := s(6 downto 0) xor rc;
        a(STATE_SIZE-1 downto STATE_SIZE-7) := s(STATE_SIZE-1 downto STATE_SIZE-7) xor rrc;
        for i in 0 to 39 loop
            b(4*i+3 downto 4*i) := SBOX(to_integer(unsigned(a(4*i+3 downto 4*i))));
        end loop;
        for j in 0 to STATE_SIZE-2 loop
            p((40*j) mod (STATE_SIZE-1)) := b(j);
        end loop;
        p(STATE_SIZE-1) := b(STATE_SIZE-1);
        return p;
    end function;

    type st_arr is array (0 to NR) of std_logic_vector(STATE_SIZE-1 downto 0);
    signal st: st_arr;
begin
    st(0) <= din;
    gen_rounds: for j in 0 to NR-1 generate
        st(j+1) <= spongent_round(st(j), RC(pass*NR + j));
    end generate;
    dout <= st(NR);
    dtap <= st(TAILR);
end behavioral;
