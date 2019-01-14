----------------------------------------------------------------------------------
-- Company			: Research Institute of Precision Instruments
-- Engineer			: Kosinov Alexey
-- Create Date		: 16:35:00 21/05/2018
-- Target Devices	: Virtex-6 (XC6VSX315T-2FF1759)
-- Tool versions	: ISE Design 14.7
-- Description		: Aeroflex UT8QNF8M8 64Mbit NOR Flash Memory Controller
--					: This wrapper configurate two flashes (in BYTE mode) for
--					: downloading full Xilinx raw bitstream file (binary format)
--					: WARNING! bin file must be "Swapped" Bits On, Compression On.
--					: Start address: 0x000000;
--					: Master Clock : 90 MHz;
----------------------------------------------------------------------------------
--	RDY	| WR | RD | ERASE | OPERATION    |
--	----|----|----|-------|--------------|
--	 0  | X  | X  |  XX   | IDLE	     |
--	 1  | 1  | 0  |  00   | WRITE        |
--	 1	| 0  | 1  |  00   | READ         |
--	 1	| 0  | 0  |  01   | CHIP ERASE 	 |
--	 1	| 0  | 0  |  10   | SECTOR ERASE |
----------------------------------------------------------------------------------

library IEEE;
	use IEEE.std_logic_1164.all;

entity ut8qnf8m8 is
	port(
		CLK_IN      : in  std_logic;
		RST_IN      : in  std_logic;
		ERASE_IN    : in  std_logic_vector(1 downto 0);
		RD_IN       : in  std_logic;
		WR_IN       : in  std_logic; 
		RDY_IN      : in  std_logic;
		ADDR_IN     : in  std_logic_vector(22 downto 0);
		DATA_IN     : in  std_logic_vector(15 downto 0);
		DATA_OUT    : out std_logic_vector(15 downto 0);
		BUSY_OUT    : out std_logic; -- Low when controller ready for a new operation
		VALID_OUT	: out std_logic; -- High when controller writed bytes / erased without errors
		ERROR_OUT	: out std_logic; -- High when error, system need to reset chip and repeat operation

		CE_n 	    : out std_logic;
		OE_n        : out std_logic;
		WE_n        : out std_logic;
        A	        : out std_logic_vector(22 downto 0);
        DQ          : inout std_logic_vector(15 downto 0)
	);
end entity;

architecture rtl of ut8qnf8m8 is

    type fsm_main is (ST_IDLE, ST_READ, ST_WRITE, ST_CHIP_ERASE, ST_SECTOR_ERASE, ST_DATA_POLLING);
    signal st_main : fsm_main;	

	-- Write Mode
    type fsm_write is (W_SEQ0, W_SEQ1, W_SEQ2, W_SEQ3, W_WAIT);
    signal st_writing : fsm_write;	

	-- Chip Erase
    type fsm_erase is (E0_SEQ0, E0_SEQ1, E0_SEQ2, E0_SEQ3, E0_SEQ4, E0_SEQ5, E0_WAIT);
    signal st_chip_erasing : fsm_erase;	

	-- Sector Erase
    type fsm_s_erase is (E1_SEQ0, E1_SEQ1, E1_SEQ2, E1_SEQ3, E1_SEQ4, E1_SEQ5, E1_WAIT);
    signal st_sector_erasing : fsm_s_erase;	

	-- Data# Polling Algoritm
    type fsm_check is (DP_START, DP_CHECK0_DQ7, DP_CHECK1_DQ7, DP_READ_BYTES0, DP_READ_BYTES1, DP_FAIL, DP_PASS);
    signal st_check : fsm_check;	


	-- All timings for a clock 
	signal t_RD		: integer range 0 to 15 := 0; -- Read counter	
	signal t_WR		: integer range 0 to 23 := 0; -- Write counter
	signal t_CE		: integer range 0 to 23 := 0; -- Chip Erase counter
	signal t_SE		: integer range 0 to 23 := 0; -- Sector Erase counter
	signal t_RB		: integer range 0 to 23 := 0; -- Read back (Embedded Algorithm) counter

	signal t_WHWH1	: integer range 0 to 63 := 0; -- Write wait counter
	signal t_WHWH2	: integer range 0 to 63 := 0; -- Chip Erase counter
	signal t_WHWH3	: integer range 0 to 63 := 0; -- Sector erase counter

	-- Flash commands (Byte mode)
	constant write_data_reset	: std_logic_vector(15 downto 0) := x"F0F0";

	constant write_data_first  	: std_logic_vector(15 downto 0) := x"AAAA";
	constant write_data_second	: std_logic_vector(15 downto 0) := x"5555";	
	constant write_data_third  	: std_logic_vector(15 downto 0) := x"A0A0";	

	constant write_addr_first  	: std_logic_vector(22 downto 0) := "00000000000101010101010"; -- AAA
	constant write_addr_second	: std_logic_vector(22 downto 0) := "00000000000010101010101"; -- 555	
	constant write_addr_third  	: std_logic_vector(22 downto 0) := "00000000000101010101010"; -- AAA	

	constant erase_data_first  	: std_logic_vector(15 downto 0) := x"AAAA";
	constant erase_data_second	: std_logic_vector(15 downto 0) := x"5555";	
	constant erase_data_third  	: std_logic_vector(15 downto 0) := x"8080";	
	constant erase_data_fouth  	: std_logic_vector(15 downto 0) := x"AAAA";	
	constant erase_data_fifth  	: std_logic_vector(15 downto 0) := x"5555";
	constant erase_data_sixth  	: std_logic_vector(15 downto 0) := x"1010";
	constant erase_data_sector 	: std_logic_vector(15 downto 0) := x"3030";

	constant erase_addr_first  	: std_logic_vector(22 downto 0) := "00000000000101010101010"; -- AAA
	constant erase_addr_second	: std_logic_vector(22 downto 0) := "00000000000010101010101"; -- 555	
	constant erase_addr_third  	: std_logic_vector(22 downto 0) := "00000000000101010101010"; -- AAA
	constant erase_addr_fouth	: std_logic_vector(22 downto 0) := "00000000000101010101010"; -- AAA	
	constant erase_addr_fifth  	: std_logic_vector(22 downto 0) := "00000000000010101010101"; -- 555
	constant erase_addr_sixth  	: std_logic_vector(22 downto 0) := "00000000000101010101010"; -- AAA

	signal chip_enable			: std_logic;
	signal write_enable			: std_logic;
	signal open_enable			: std_logic;
	signal dq_data_out_r		: std_logic_vector(15 downto 0);
	signal dq_data_in_r			: std_logic_vector(15 downto 0);
	signal address_wr_r			: std_logic_vector(22 downto 0);
	signal busy_i 				: std_logic;
	signal dq_data_poll_r		: std_logic_vector(15 downto 0);
	signal prorgamming_complete	: std_logic; 
	signal prorgamming_error	: std_logic;
	signal toggle_bits			: std_logic_vector(1 downto 0);	

	attribute KEEP : string;
	attribute KEEP of dq_data_poll_r : signal is "TRUE";


begin

	CE_n 		<= not(chip_enable);
	OE_n 		<= not(open_enable);
	WE_n 		<= not(write_enable);

	ERROR_OUT 	<= prorgamming_error;
	VALID_OUT	<= prorgamming_complete;
	BUSY_OUT	<= busy_i;

	DQ 			<= dq_data_out_r when (open_enable = '0' and st_main /= ST_READ and st_check /= DP_READ_BYTES0 and st_check /= DP_READ_BYTES1) else (others => 'Z');
	DATA_OUT 	<= dq_data_in_r;


	process(CLK_IN, RST_IN)
	begin
		if (RST_IN = '1') then
			chip_enable				<= '0';
			open_enable				<= '0';
			write_enable 			<= '0';
			st_main 				<= ST_IDLE;
			st_writing 				<= W_SEQ0;
			st_chip_erasing			<= E0_SEQ0;
			st_sector_erasing		<= E1_SEQ0;
			st_check				<= DP_START;
			address_wr_r 			<= (others => '0');
			dq_data_in_r 			<= (others => '0');
			dq_data_out_r 			<= (others => '0');
			busy_i					<= '0';
			t_WHWH1					<= 0;
			t_WHWH2					<= 0;
			t_WHWH3					<= 0;		
			t_RD					<= 0;
			t_WR					<= 0;
			t_CE					<= 0;
			t_SE					<= 0;
			t_RB					<= 0;
			dq_data_poll_r			<= (others => '0');					
			prorgamming_complete 	<= '0';
			prorgamming_error		<= '0';
			toggle_bits				<= (others => '0');	

		elsif (rising_edge(CLK_IN)) then

			case (st_main) is

				when ST_IDLE =>
					chip_enable			<= '0';
					open_enable			<= '0';
					write_enable		<= '0';
					busy_i				<= '0';
					t_WHWH1				<= 0;
					t_WHWH2				<= 0;
					t_WHWH3				<= 0;		
					t_WR				<= 0;
					t_RD				<= 0;	
					t_CE				<= 0;
					t_SE				<= 0;		
					t_RB				<= 0;
					dq_data_poll_r		<= (others => '0');	
					toggle_bits			<= (others => '0');									
					st_writing			<= W_SEQ0;
					st_chip_erasing		<= E0_SEQ0;
					st_sector_erasing	<= E1_SEQ0;	
					st_check			<= DP_START;	

					if (busy_i = '0' and RDY_IN = '1' and RD_IN = '1' and WR_IN = '0' and ERASE_IN = "00") then -- Read Mode
						st_main 		<= ST_READ;
						address_wr_r 	<= ADDR_IN;
						chip_enable		<= '0';
						open_enable		<= '0';
						write_enable 	<= '0';
						dq_data_in_r	<= (others => '0');
						busy_i			<= '1';
					elsif (busy_i = '0' and RDY_IN = '1' and RD_IN = '0' and WR_IN = '1' and ERASE_IN = "00") then -- Write Mode
						st_main 		<= ST_WRITE;
						address_wr_r 	<= ADDR_IN;
						chip_enable		<= '0';
						open_enable		<= '0';
						write_enable 	<= '0';
						busy_i			<= '1';
					elsif (busy_i = '0' and RDY_IN = '1' and RD_IN = '0' and WR_IN = '0' and ERASE_IN = "01") then -- Chip Erase
						st_main 		<= ST_CHIP_ERASE;
						chip_enable		<= '0';
						open_enable		<= '0';
						write_enable 	<= '0';
						busy_i			<= '1';
					elsif (busy_i = '0' and RDY_IN = '1' and RD_IN = '0' and WR_IN = '0' and ERASE_IN = "10") then -- Sector Erase
						st_main 		<= ST_SECTOR_ERASE;
						address_wr_r 	<= ADDR_IN;
						chip_enable		<= '0';
						open_enable		<= '0';
						write_enable 	<= '0';
						busy_i			<= '1';
					else
						st_main 		<= ST_IDLE;
					end if;

				when ST_READ => 

					dq_data_in_r		<= DQ;
					A					<= address_wr_r;

					if (t_RD = 15) then -- Read cycle time
						t_RD <= 0;
					else
						t_RD <= t_RD + 1;
					end if;

					case t_RD is
						when 0 =>
							write_enable 	<= '0';
							open_enable 	<= '0';	
							chip_enable 	<= '1';
						when 3 =>
							write_enable 	<= '0';
							open_enable 	<= '1';	
							chip_enable 	<= '1';	
						when 12 =>
							write_enable 	<= '0';
							open_enable 	<= '0';	
							chip_enable 	<= '0';	
						when 15 =>
							st_main			<= ST_IDLE;
						when others => null;
					end case;

				when ST_WRITE => 

					if (t_WR = 23) then
						t_WR <= 0;
					elsif (st_writing = W_WAIT) then
						t_WR <= 0;
					else
						t_WR <= t_WR + 1;
					end if;

					case (st_writing) is
						when W_SEQ0 =>
							case t_WR is
								when 0 =>
									A				<= write_addr_first;
									dq_data_out_r	<= write_data_first;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_writing 		<= W_SEQ1;
								when others => null;	
							end case;

						when W_SEQ1=>
							case t_WR is
								when 0 =>
									A				<= write_addr_second;
									dq_data_out_r	<= write_data_second;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_writing 		<= W_SEQ2;		
								when others => null;
							end case;

						when W_SEQ2 =>
							case t_WR is
								when 0 =>
									A				<= write_addr_third;
									dq_data_out_r	<= write_data_third;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_writing 		<= W_SEQ3;	
								when others => null;

							end case;

						when W_SEQ3 =>
							case t_WR is
								when 0 =>
									A				<= address_wr_r;
									dq_data_out_r	<= DATA_IN;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_writing 		<= W_WAIT;	
								when others => null;

							end case;

						when W_WAIT =>
							busy_i	<= '1';
							if (t_WHWH1 = 63) then -- Time Out counter
								t_WHWH1	<= 0;
								st_main	<= ST_DATA_POLLING;											
							else
								t_WHWH1	<= t_WHWH1 + 1;
							end if;
					end case;

				when ST_CHIP_ERASE => 
					
					if (t_CE = 23) then
						t_CE <= 0;
					elsif (st_chip_erasing = E0_WAIT) then
						t_CE <= 0;
					else
						t_CE <= t_CE + 1;
					end if;					

					case (st_chip_erasing) is
						when E0_SEQ0 =>
							case t_CE is
								when 0 =>
									A				<= erase_addr_first;
									dq_data_out_r	<= erase_data_first;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_chip_erasing	<= E0_SEQ1;
								when others => null;
							end case;

						when E0_SEQ1 =>
							case t_CE is
								when 0 =>
									A				<= erase_addr_second;
									dq_data_out_r	<= erase_data_second;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_chip_erasing	<= E0_SEQ2;
								when others => null;
							end case;		

						when E0_SEQ2 =>
							case t_CE is
								when 0 =>
									A				<= erase_addr_third;
									dq_data_out_r	<= erase_data_third;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_chip_erasing	<= E0_SEQ3;
								when others => null;
							end case;

						when E0_SEQ3 =>
							case t_CE is
								when 0 =>
									A				<= erase_addr_fouth;
									dq_data_out_r	<= erase_data_fouth;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_chip_erasing	<= E0_SEQ4;
								when others => null;
							end case;			

						when E0_SEQ4 =>
							case t_CE is
								when 0 =>
									A				<= erase_addr_fifth;
									dq_data_out_r	<= erase_data_fifth;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_chip_erasing	<= E0_SEQ5;
								when others => null;
							end case;	

						when E0_SEQ5 =>
							case t_CE is
								when 0 =>
									A				<= erase_addr_sixth;
									dq_data_out_r	<= erase_data_sixth;
									write_enable	<= '0';	
									open_enable 	<= '0';
									chip_enable 	<= '0';	
								when 7 =>
									write_enable	<= '1';	
									open_enable 	<= '0';
									chip_enable 	<= '1';	
								when 17 =>
									write_enable	<= '0';
									open_enable 	<= '0';
									chip_enable 	<= '0';
									st_chip_erasing	<= E0_WAIT;
								when others => null;
							end case;	

						when E0_WAIT =>
							busy_i	<= '1';
							if (t_WHWH2 = 63) then -- Time Out counter
								t_WHWH2	<= 0;
								st_main	<= ST_DATA_POLLING;											
							else
								t_WHWH2	<= t_WHWH2 + 1;
							end if;
					end case;

				when ST_SECTOR_ERASE => 

					if (t_SE = 23) then
						t_SE <= 0;
					elsif (st_sector_erasing = E1_WAIT) then
						t_CE <= 0;
					else
						t_SE <= t_SE + 1;
					end if;

					case (st_sector_erasing) is
						when E1_SEQ0 =>
							case t_SE is
								when 0 =>
									A					<= erase_addr_first;
									dq_data_out_r		<= erase_data_first;
									write_enable		<= '0';	
									open_enable 		<= '0';
									chip_enable 		<= '0';	
								when 7 =>
									write_enable		<= '1';	
									open_enable 		<= '0';
									chip_enable 		<= '1';	
								when 17 =>
									write_enable		<= '0';
									open_enable 		<= '0';
									chip_enable 		<= '0';
									st_sector_erasing	<= E1_SEQ1;
								when others => null;
							end case;	

						when E1_SEQ1 =>
							case t_SE is
								when 0 =>
									A					<= erase_addr_second;
									dq_data_out_r		<= erase_data_second;
									write_enable		<= '0';	
									open_enable 		<= '0';
									chip_enable 		<= '0';	
								when 7 =>
									write_enable		<= '1';	
									open_enable 		<= '0';
									chip_enable 		<= '1';	
								when 17 =>
									write_enable		<= '0';
									open_enable 		<= '0';
									chip_enable 		<= '0';
									st_sector_erasing	<= E1_SEQ2;
								when others => null;
							end case;		

						when E1_SEQ2 =>
							case t_SE is
								when 0 =>
									A					<= erase_addr_third;
									dq_data_out_r		<= erase_data_third;
									write_enable		<= '0';	
									open_enable 		<= '0';
									chip_enable 		<= '0';	
								when 7 =>	
									write_enable		<= '1';	
									open_enable 		<= '0';
									chip_enable 		<= '1';	
								when 17 =>	
									write_enable		<= '0';
									open_enable 		<= '0';
									chip_enable 		<= '0';
									st_sector_erasing	<= E1_SEQ3;
								when others => null;
							end case;	

						when E1_SEQ3 =>
							case t_SE is
								when 0 =>
									A					<= erase_addr_fouth;
									dq_data_out_r		<= erase_data_fouth;
									write_enable		<= '0';	
									open_enable 		<= '0';
									chip_enable 		<= '0';	
								when 7 =>	
									write_enable		<= '1';	
									open_enable 		<= '0';
									chip_enable 		<= '1';	
								when 17 =>	
									write_enable		<= '0';
									open_enable 		<= '0';
									chip_enable 		<= '0';
									st_sector_erasing	<= E1_SEQ4;
								when others => null;
							end case;					

						when E1_SEQ4 =>
							case t_SE is
								when 0 =>
									A					<= erase_addr_fifth;
									dq_data_out_r		<= erase_data_fifth;
									write_enable		<= '0';	
									open_enable 		<= '0';
									chip_enable 		<= '0';	
								when 7 =>	
									write_enable		<= '1';	
									open_enable 		<= '0';
									chip_enable 		<= '1';	
								when 17 =>	
									write_enable		<= '0';
									open_enable 		<= '0';
									chip_enable 		<= '0';
									st_sector_erasing	<= E1_SEQ5;
								when others => null;
							end case;			

						when E1_SEQ5 =>
							case t_SE is
								when 0 =>
									A					<= address_wr_r;
									dq_data_out_r		<= erase_data_sector;
									write_enable		<= '0';	
									open_enable 		<= '0';
									chip_enable 		<= '0';	
								when 7 =>	
									write_enable		<= '1';	
									open_enable 		<= '0';
									chip_enable 		<= '1';	
								when 17 =>	
									write_enable		<= '0';
									open_enable 		<= '0';
									chip_enable 		<= '0';
									st_sector_erasing	<= E1_WAIT;
								when others => null;
							end case;	
	
						when E1_WAIT => -- 0.5 sec min
							busy_i	<= '1';
							if (t_WHWH3 = 63) then -- Time Out counter
								t_WHWH3	<= 0;
								st_main	<= ST_DATA_POLLING;											
							else
								t_WHWH3	<= t_WHWH3 + 1;
							end if;

					end case;

				when ST_DATA_POLLING =>
					busy_i	<= '1';
					if (t_RB = 15) then
						t_RB <= 0;
					elsif (st_check = DP_START or st_check = DP_CHECK0_DQ7 or st_check = DP_CHECK1_DQ7) then
						t_RB <= 0;	
					else
						t_RB <= t_RB + 1;
					end if;

					case (st_check) is
						when DP_START => -- Default
							prorgamming_complete	<= '0';
							prorgamming_error		<= '0';		
							st_check				<= DP_READ_BYTES0;

						when DP_READ_BYTES0 =>
							prorgamming_complete	<= '0';
							prorgamming_error		<= '0';	

							dq_data_poll_r			<= DQ;

							case t_RB is
								when 0 =>
									dq_data_poll_r	<= (others => '0');							
									write_enable 	<= '0';
									open_enable 	<= '0';	
									chip_enable 	<= '1';
								when 3 =>
									write_enable 	<= '0';
									open_enable 	<= '1';	
									chip_enable 	<= '1';	
								when 12 =>
									write_enable 	<= '0';
									open_enable 	<= '0';	
									chip_enable 	<= '0';	
								when 15 =>
									st_check		<= DP_CHECK0_DQ7;
								when others => null;
							end case;

						when DP_CHECK0_DQ7 =>
							prorgamming_complete	<= '0';
							prorgamming_error		<= '0';	
							if (st_writing = W_WAIT) then -- Write Mode
								if (dq_data_poll_r(15) = dq_data_out_r(15) and dq_data_poll_r(7) = dq_data_out_r(7)) then
									st_check <= DP_PASS;
								else
									if (dq_data_poll_r(5) = '1' and dq_data_poll_r(13) = '1') then
										st_check <= DP_READ_BYTES1;
									else
										st_check <= DP_READ_BYTES0;
									end if;
								end if;
							elsif (st_chip_erasing = E0_WAIT or st_sector_erasing = E1_WAIT) then -- Erase Mode

								-- if (dq_data_poll_r = x"FFFF") then
								-- 	st_check <= DP_PASS;
								-- else
								-- 	st_check <= DP_READ_BYTES0;
								-- end if;
								toggle_bits <= dq_data_poll_r(14) & dq_data_poll_r(6);
								st_check 	<= DP_READ_BYTES1;


							end if;

						when DP_READ_BYTES1 =>
							prorgamming_complete	<= '0';
							prorgamming_error		<= '0';	

							dq_data_poll_r			<= DQ;

							case t_RB is
								when 0 =>
									dq_data_poll_r	<= (others => '0');							
									write_enable 	<= '0';
									open_enable 	<= '0';	
									chip_enable 	<= '1';
								when 3 =>
									write_enable 	<= '0';
									open_enable 	<= '1';
									chip_enable 	<= '1';
								when 12 =>
									write_enable 	<= '0';
									open_enable 	<= '0';	
									chip_enable 	<= '0';	
								when 15 =>
									st_check		<= DP_CHECK1_DQ7;
								when others => null;
							end case;

						when DP_CHECK1_DQ7 =>
							prorgamming_complete	<= '0';
							prorgamming_error		<= '0';	
							if (st_writing = W_WAIT) then -- Write Mode
								if (dq_data_poll_r(15) = dq_data_out_r(15) and dq_data_poll_r(7) = dq_data_out_r(7)) then
									st_check <= DP_PASS;
								else
									st_check <= DP_FAIL;
								end if;
							elsif (st_chip_erasing = E0_WAIT or st_sector_erasing = E1_WAIT) then -- Erase Mode
								if (toggle_bits(0) = dq_data_poll_r(6) and toggle_bits(1) = dq_data_poll_r(14)) then
									st_check <= DP_PASS;
								else
									st_check <= DP_READ_BYTES0;
								end if;
							end if;

						when DP_PASS =>
							prorgamming_complete	<= '1';
							prorgamming_error		<= '0';	
							st_main					<= ST_IDLE;

						when DP_FAIL =>
							-- case t_RB is
							-- 	when 0 =>
							-- 		dq_data_out_r			<= write_data_reset;
							-- 		write_enable			<= '0';	
							-- 		open_enable 			<= '0';
							-- 		chip_enable 			<= '0';	
							-- 	when 7 =>
							-- 		write_enable			<= '1';	
							-- 		open_enable 			<= '0';
							-- 		chip_enable 			<= '1';	
							-- 	when 17 =>
							-- 		write_enable			<= '0';
							-- 		open_enable 			<= '0';
							-- 		chip_enable 			<= '0';
									prorgamming_complete	<= '0';
									prorgamming_error		<= '1';										
									st_main					<= ST_IDLE;
								-- when others => null;	
							-- end case;					

					end case;	
			
			end case;

		end if;

	end process;

end architecture;
