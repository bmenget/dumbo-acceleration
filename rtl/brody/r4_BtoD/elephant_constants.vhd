--------------------------------------------------------------------------------
--! @file       elephant_constants.vhd
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

package elephant_constants is
    constant STATE_SIZE: integer := 160;
    constant CCW_SIZE: integer := 32;
    constant ADDR_BITs: integer := 3;
    constant MASK_ADDR_BITs: integer := 2;
    
    constant KEY_SIZE: integer := 4; --16 Bytes
    constant KEY_SIZE_BITS: integer := KEY_SIZE * CCW_SIZE;
    constant ELE_NPUB_SIZE: integer := 3; --12 Bytes
    constant NPUB_SIZE_BITS : integer := ELE_NPUB_SIZE * CCW_SIZE;
    constant ELE_TAG_SIZE: integer := 2; -- 8 Bytes
    constant TAG_SIZE_BITS: integer := ELE_TAG_SIZE * CCW_SIZE;
    constant BLOCK_SIZE: integer := 5; --20 Bytes --Message full 5
    
    constant PERM_ROUNDS_PER_CYCLE: integer := 4;
    constant PERM_CYCLES: integer := 80/PERM_ROUNDS_PER_CYCLE;
    constant PERM_CYCLES_BITS: integer := 7;
    --16 ~2500 LUTs
    --8  ~1800 LUTs ROM

    -- BtoD: mask LFSR window holds LFSR_MASKS consecutive masks phi^(a-1) .. phi^(a+5)
    constant LFSR_MASKS: integer := 7;
    constant LFSR_W: integer := STATE_SIZE + 8*(LFSR_MASKS-1);   -- 208 bits

    -- BtoD: slot-mux mode (selects every slot's source and mask; see elephant_datapath.vhd)
    constant MD_KEY : std_logic_vector(2 downto 0) := "000";  -- A0: input buffer 0, no mask
    constant MD_AD  : std_logic_vector(2 downto 0) := "001";  -- AD blocks j..j+3
    constant MD_KS0 : std_logic_vector(2 downto 0) := "010";  -- message start: KS(0..3)
    constant MD_MSG : std_logic_vector(2 downto 0) := "011";  -- MAC(k), MAC(k+1), KS(k+4), KS(k+5)
    constant MD_FIN : std_logic_vector(2 downto 0) := "100";  -- final: tag xor L
end package elephant_constants;
