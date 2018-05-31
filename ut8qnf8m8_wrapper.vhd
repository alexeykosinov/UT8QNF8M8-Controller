----------------------------------------------------------------------------------
-- Company			: Research Institute of Precision Instruments
-- Engineer			: Kosinov Alexey
-- Create Date		: 16:35:00 21/05/2018
-- Target Devices	: Virtex-6 (XC6VSX315T-2FF1759)
-- Tool versions	: ISE Design 14.7
-- Description		: Aeroflex UT8QNF8M8 64Mbit NOR Flash Memory Controller
--					: This wrapper configurate two flashes (in BYTE mode) for downloading
--					: full Xilinx raw bitstream file
--					: WARNING! bin file must be Swapped Bits ON
--					: Start: 0x000000; End: 0xC740BB
--					: Master Clock : 25 MHz
----------------------------------------------------------------------------------

--	RDY	| WR | RD | ERASE | OPERATION |
--	 0  | 0  | 0  |   0   | - IDLE    |
--	 1  | 1  | 0  |   0   | - WRITE   |
--	 1	| 0  | 1  |   0   | - READ    |
--	 1	| 0  | 0  |   1   | - ERASE   |

library IEEE;
	use IEEE.std_logic_1164.all;
	use IEEE.std_logic_unsigned.all;

entity ut8qnf8m8 is
	port(
		CLK_IN      : in  std_logic;
		RST_IN      : in  std_logic;
		ERASE_IN    : in  std_logic; 
		RD_IN       : in  std_logic;
		WR_IN       : in  std_logic; 
		RDY_IN      : in  std_logic;
		ADDR_IN     : in  std_logic_vector(22 downto 0);
		DATA_IN     : in  std_logic_vector(15 downto 0);
		DATA_OUT    : out std_logic_vector(15 downto 0);
		BUSY_OUT    : out std_logic; -- If low when controller ready for a new operation
		VALID_OUT	: out std_logic; -- If high when controller writed byte without errors
		ERROR_OUT	: out std_logic; -- If high when error, system need to reset chip

		CE_n 	    : out std_logic;
		OE_n        : out std_logic;
		WE_n        : out std_logic;
        A	        : out std_logic_vector(22 downto 0);
        DQ          : inout std_logic_vector(15 downto 0)
	);
end entity;

architecture rtl of ut8qnf8m8 is

    type fsm_main is (ST_IDLE, ST_READ, ST_WRITE, ST_ERASE);
    signal st_main : fsm_main;	

    type fsm_write is (W_SEQ0, W_SEQ1, W_SEQ2, W_SEQ3, W_VERIFY, W_LAST, W_WAIT);
    signal st_writing : fsm_write;	

    type fsm_erase is (E_SEQ0, E_SEQ1, E_SEQ2, E_SEQ3, E_SEQ4, E_SEQ5, E_WAIT);
    signal st_erasing : fsm_erase;	

    type fsm_verify is (V_START, V_RD_1BYTE, V_RD_2BYTE, V_TOGGLE, V_DQ5_CHECK, 
						V_RD_1BYTE_AGAIN, V_RD_2BYTE_AGAIN, TOGGLE_AGAIN, V_STOP, V_ERROR);
    signal st_verify : fsm_verify;	

	-- All timings for a clock 25 MHz
	signal t_CS  				: integer range 0 to 5 := 0;
	signal t_WHWH1  			: integer range 0 to 10 := 0;
	signal t_WHWH2  			: integer range 0 to 1000000 := 0; -- Must be 0.5 s min	

	-- Flash commands (byte mode)
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

	-- Toggle Bit Verification
	signal dq_data_check_a		: std_logic_vector(15 downto 0);
	signal dq_data_check_b		: std_logic_vector(15 downto 0);
	signal prorgamming_complete	: std_logic; 
	signal prorgamming_error	: std_logic;	

begin

	CE_n 	<= not(chip_enable);
	OE_n 	<= not(open_enable);
	WE_n 	<= not(write_enable);

	ERROR_OUT 	<= prorgamming_error;
	VALID_OUT	<= prorgamming_complete;
	
	DQ <= dq_data_out_r 		when open_enable = '0' else (others => 'Z');

	DATA_OUT <= dq_data_in_r 	when (st_writing = W_VERIFY or st_main = ST_READ) else (others => '0');


	process(CLK_IN, RST_IN)
	begin
		if (RST_IN = '1') then
			chip_enable		<= '0';
			open_enable		<= '0';
			write_enable 	<= '0';
			st_main 		<= ST_IDLE;
			st_writing 		<= W_SEQ0;
			st_erasing		<= E_SEQ0;
			address_wr_r 	<= (others => '0');
			dq_data_in_r 	<= (others => '0');
			dq_data_out_r 	<= (others => '0');
			BUSY_OUT		<= '0';
			t_WHWH1			<= 0;
			t_WHWH2			<= 0;
			t_CS			<= 0;
			dq_data_check_a 		<= (others => '0');
			dq_data_check_b 		<= (others => '0');
			prorgamming_complete 	<= '0';
			prorgamming_error		<= '0';

		elsif (rising_edge(CLK_IN)) then

			case (st_main) is

				when ST_IDLE =>
					chip_enable		<= '0';
					open_enable		<= '0';
					write_enable 	<= '0';
					BUSY_OUT 		<= '0';

					if (RDY_IN = '1' and RD_IN = '1' and WR_IN = '0' and ERASE_IN = '0') then
						st_main 		<= ST_READ;
						address_wr_r 	<= ADDR_IN;
						chip_enable		<= '0';
						open_enable		<= '0';
						write_enable 	<= '0';
						BUSY_OUT		<= '1';
					elsif (RDY_IN = '1' and RD_IN = '0' and WR_IN = '1' and ERASE_IN = '0') then
						st_main 		<= ST_WRITE;
						address_wr_r 	<= ADDR_IN;
						chip_enable		<= '0';
						open_enable		<= '0';
						write_enable 	<= '0';
						BUSY_OUT		<= '1';
					elsif (RDY_IN = '1' and RD_IN = '0' and WR_IN = '0' and ERASE_IN = '1') then
						st_main 		<= ST_ERASE;
						chip_enable		<= '0';
						open_enable		<= '0';
						write_enable 	<= '0';
						BUSY_OUT		<= '1';
					else
						st_main 		<= ST_IDLE;
					end if;

				when ST_READ => -- Read cycle time
					write_enable 	<= '0';
					A				<= address_wr_r;						
					case t_CS is
						when 0 =>
							open_enable 	<= '0';	
							chip_enable 	<= '1';								
						when 1 =>
							open_enable 	<= '1';	
							chip_enable 	<= '1';	
						when 2 =>
							open_enable 	<= '1';	
							chip_enable 	<= '1';	
							dq_data_in_r 	<= DQ;	
						when 3 =>
							open_enable 	<= '1';	
							chip_enable 	<= '1';	
							dq_data_in_r 	<= DQ;	
						when 4 =>
							open_enable 	<= '0';	
							chip_enable 	<= '0';	
						when 5 =>
							st_main 		<= ST_IDLE;
							BUSY_OUT		<= '0';							
					end case;

					if (t_CS = 5) then
						t_CS <= 0;
					else
						t_CS <= t_CS + 1;
					end if;

				when ST_WRITE => 
					case (st_writing) is
						when W_SEQ0 =>
							chip_enable 	<= '1';
							A				<= write_addr_first;
							BUSY_OUT		<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= write_data_first;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_writing 		<= W_SEQ1;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;

						when W_SEQ1=>
							chip_enable 	<= '1';
							A				<= write_addr_second;
							BUSY_OUT		<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= write_data_second;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_writing 		<= W_SEQ2;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;

						when W_SEQ2 =>
							chip_enable 	<= '1';						
							A				<= write_addr_third;
							BUSY_OUT		<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= write_data_third;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_writing 		<= W_SEQ3;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;

						when W_SEQ3 =>
							chip_enable 	<= '1';						
							A				<= address_wr_r;
							BUSY_OUT		<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= DATA_IN;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_writing 		<= W_WAIT;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;

						when W_WAIT => -- wait for 8 us
							BUSY_OUT	<= '1';
							if (t_WHWH1 = 10) then
								t_WHWH1		<= 0;
								st_writing	<= W_VERIFY;
								st_verify 	<= V_START;
							else
								t_WHWH1 <= t_WHWH1 + 1;
							end if;

						when W_VERIFY => 
							write_enable	<= '0';
							A				<= address_wr_r;
							BUSY_OUT		<= '1';				
							case (st_verify) is

								when V_START =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';				
									if (st_writing = W_VERIFY) 	then
										st_verify 		<= V_RD_1BYTE;
										open_enable 	<= '0';	
										chip_enable 	<= '0';							
									else
										st_verify <= V_START;
									end if;

								when V_RD_1BYTE =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';
									case t_CS is
										when 0 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';								
										when 1 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
										when 2 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
											dq_data_check_a	<= DQ;
										when 3 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';
										when 4 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';	
										when 5 =>
											st_verify <= V_RD_2BYTE;
									end case;

									if (t_CS = 5) then
										t_CS <= 0;
									else
										t_CS <= t_CS + 1;
									end if;

								when V_RD_2BYTE =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';				
									case t_CS is
										when 0 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';								
										when 1 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
										when 2 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
											dq_data_check_b <= DQ;
										when 3 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';
										when 4 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';	
										when 5 =>
											st_verify <= V_TOGGLE;
									end case;

									if (t_CS = 5) then
										t_CS <= 0;
									else
										t_CS <= t_CS + 1;
									end if;

								when V_TOGGLE =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';				
									if (dq_data_check_a(6) = not(dq_data_check_b(6)) and dq_data_check_a(14) = not(dq_data_check_b(14))) then
										st_verify <= V_DQ5_CHECK;
									else
										st_verify <= V_STOP;
									end if;

								when V_DQ5_CHECK =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';
									if (dq_data_check_a(5) = '1' and dq_data_check_a(13) = '1') then
										st_verify 		<= V_RD_1BYTE_AGAIN;
										dq_data_check_a <= (others => '0');
										dq_data_check_b <= (others => '0');
									else
										st_verify <= V_STOP;
									end if;

								when V_RD_1BYTE_AGAIN =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';				
									case t_CS is
										when 0 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';								
										when 1 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
										when 2 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
											dq_data_check_a	<= DQ;
										when 3 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';
										when 4 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';	
										when 5 =>
											st_verify <= V_RD_2BYTE_AGAIN;
									end case;

									if (t_CS = 5) then
										t_CS <= 0;
									else
										t_CS <= t_CS + 1;
									end if;

								when V_RD_2BYTE_AGAIN =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';
									case t_CS is
										when 0 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';								
										when 1 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
										when 2 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';	
											dq_data_check_b	<= DQ;
										when 3 =>
											open_enable 	<= '1';	
											chip_enable 	<= '1';
										when 4 =>
											open_enable 	<= '0';	
											chip_enable 	<= '1';	
										when 5 =>
											st_verify <= TOGGLE_AGAIN;
									end case;

									if (t_CS = 5) then
										t_CS <= 0;
									else
										t_CS <= t_CS + 1;
									end if;

								when TOGGLE_AGAIN => 
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '0';				
									if (dq_data_check_a(6) = not(dq_data_check_b(6)) and dq_data_check_a(14) = not(dq_data_check_b(14))) then
										st_verify <= V_ERROR;
									else
										st_verify <= V_STOP;
									end if;

								when V_STOP =>
									prorgamming_complete 	<= '1';
									prorgamming_error		<= '0';
									st_writing 				<= W_LAST;

								when V_ERROR =>
									prorgamming_complete 	<= '0';
									prorgamming_error		<= '1';
									chip_enable 			<= '1';
									case t_CS is
										when 0 =>
											write_enable	<= '0';								
										when 1 =>
											write_enable	<= '1';	
											dq_data_out_r	<= write_data_reset;						
										when 2 =>
											write_enable	<= '1';						
										when 3 =>
											write_enable	<= '0';
										when 4 =>
											chip_enable 	<= '0';
										when 5 =>
											chip_enable 	<= '0';
											BUSY_OUT 		<= '1';
											st_main			<= ST_IDLE;			
									end case;

									if (t_CS = 5) then
										t_CS <= 0;
									else
										t_CS <= t_CS + 1;
									end if;
								end case;

						when W_LAST =>
							BUSY_OUT <= '0';
							if (WR_IN = '1') then
								st_writing 	<= W_SEQ0;
							else
								st_main		<= ST_IDLE;
							end if;
					end case;

				when ST_ERASE => 
					case (st_erasing) is
						when E_SEQ0 =>
							chip_enable	<= '1';
							A			<= erase_addr_first;
							BUSY_OUT	<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= erase_data_first;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_erasing 		<= E_SEQ1;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;

						when E_SEQ1 =>
							chip_enable	<= '1';
							A			<= erase_addr_second;
							BUSY_OUT	<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= erase_data_second;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_erasing 		<= E_SEQ2;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;					

						when E_SEQ2 =>
							chip_enable	<= '1';
							A			<= erase_addr_third;
							BUSY_OUT	<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= erase_data_third;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_erasing 		<= E_SEQ3;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;

						when E_SEQ3 =>
							chip_enable	<= '1';
							A			<= erase_addr_fouth;
							BUSY_OUT	<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= erase_data_fouth;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_erasing 		<= E_SEQ4;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;							

						when E_SEQ4 =>
							chip_enable	<= '1';
							A			<= erase_addr_fifth;
							BUSY_OUT	<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= erase_data_fifth;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_erasing 		<= E_SEQ5;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;	

						when E_SEQ5 =>
							chip_enable	<= '1';
							A			<= erase_addr_sixth;
							BUSY_OUT	<= '1';
							case t_CS is
								when 0 =>
									write_enable	<= '0';								
								when 1 =>
									write_enable	<= '1';	
									dq_data_out_r	<= erase_data_sixth;						
								when 2 =>
									write_enable	<= '1';						
								when 3 =>
									write_enable	<= '0';
								when 4 =>
									chip_enable 	<= '0';
								when 5 =>
									chip_enable 	<= '0';
									st_erasing 		<= E_WAIT;								
							end case;

							if (t_CS = 5) then
								t_CS <= 0;
							else
								t_CS <= t_CS + 1;
							end if;	

						when E_WAIT => -- 0.5 sec min
							if (t_WHWH2 = 1000000) then
								t_WHWH2		<= 0;
								BUSY_OUT	<= '0';
								st_main		<= ST_IDLE;	
							else
								t_WHWH2 <= t_WHWH2 + 1;
							end if;

					end case;

			end case;

		end if;

	end process;

end architecture;
