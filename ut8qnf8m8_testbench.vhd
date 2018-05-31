LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

entity testbench is
end entity;
 
architecture simulation of testbench is 
 
    component ut8qnf8m8
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
            BUSY_OUT    : out std_logic;
            ERROR_OUT	: out std_logic;
            CE_n 	    : out std_logic;
            OE_n        : out std_logic; 
            WE_n        : out std_logic;	
            A	        : out std_logic_vector(22 downto 0); 
            DQ          : inout std_logic_vector(15 downto 0)
        );
    end component;

    component ct_mem
        port(
            CLK     : in  std_logic;
            START   : in  std_logic;
            ADDR    : out std_logic_vector(22 downto 0);
            DATA    : out std_logic_vector(15 downto 0)
        );
    end component;
    
    signal rst          : std_logic := '0';
    signal clk          : std_logic := '0';
    signal erase        : std_logic := '0';
    signal read         : std_logic := '0';
    signal write        : std_logic := '0';
    signal rdy          : std_logic := '0';
    signal busy_out     : std_logic := '0';   
    signal addr         : std_logic_vector(22 downto 0) := (others => '0');
    signal flash_dq     : std_logic_vector(15 downto 0) := (others => '0');
    signal err          : std_logic;
    signal din          : std_logic_vector(15 downto 0) := (others => '0');  
    signal dout         : std_logic_vector(15 downto 0);
    signal flash_addr   : std_logic_vector(22 downto 0);
    signal flash_ce_n   : std_logic;
    signal flash_oe_n   : std_logic;
    signal flash_we_n   : std_logic;

    signal ct_addr      : std_logic_vector(22 downto 0) := (others => '0');
    signal ct_data      : std_logic_vector(15 downto 0) := (others => '0');

    constant clk_period : time := 40 ns;  
 
begin

  uut: ut8qnf8m8 
    port map(
		CLK_IN      => CLK,
		RST_IN      => RST,
		ERASE_IN    => ERASE,
		RD_IN       => READ,
		WR_IN       => WRITE,
		RDY_IN      => RDY,
		ADDR_IN     => ADDR,
		DATA_IN     => DIN,
		DATA_OUT    => DOUT, 
		BUSY_OUT    => BUSY_OUT,
		ERROR_OUT	=> err,
		CE_n 	    => flash_ce_n,
		OE_n        => flash_oe_n, 
		WE_n        => flash_we_n,	
        A	        => flash_addr,
        DQ          => flash_dq
    );

    ct_mem_i : ct_mem
        port map(
            CLK     => CLK,
            START   => WRITE,
            ADDR    => ct_addr,
            DATA    => ct_data
        );

    process
    begin
        CLK <= '0';
        wait for clk_period/2;
        CLK <= '1';
        wait for clk_period/2;
    end process;

    process
    begin
        RST <= '1';
        wait for 100 ns;
        RST <= '0';
        wait;
    end process;

    process
    begin		
        wait for 100 ns;
        wait until RST = '0';
        wait until rising_edge(clk);       	
        RDY <= '1';
        wait until rising_edge(clk);
        ERASE <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk); 
        ERASE <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);         
        RDY <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk); 

        wait until BUSY_OUT = '0';
        ADDR    <= ct_addr;
        DIN     <= ct_data;
        wait until rising_edge(clk);       	
        RDY <= '1';
        wait until rising_edge(clk);
        WRITE <= '1';

        wait for 10 us;
        WRITE <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);         
        RDY <= '0';





        -- wait until rising_edge(clk);
        -- wait until rising_edge(clk); 

        -- wait until BUSY_OUT = '0';
        -- ADDR <= ct_addr;
        -- wait until rising_edge(clk);       	
        -- RDY <= '1';
        -- wait until rising_edge(clk);
        -- READ <= '1';
        -- wait until rising_edge(clk);
        -- wait until rising_edge(clk); 
        -- READ <= '0';
        -- wait until rising_edge(clk);
        -- wait until rising_edge(clk);         
        -- RDY <= '0';

    wait;
    end process;

end;