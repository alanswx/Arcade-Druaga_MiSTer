//============================================================================
//  Arcade: The Tower of Druaga
//
//  Original implimentation and port to MiSTer by MiSTer-X 2019
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [45:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output [11:0] VIDEO_ARX,
	output [11:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler

	// Use framebuffer from DDRAM (USE_FB=1 in qsf)
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of 16 bytes.
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,    // 1 - signed audio samples, 0 - unsigned

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT
);

assign VGA_F1    = 0;
assign VGA_SCALER= 0;
assign USER_OUT  = '1;
assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign {FB_PAL_CLK, FB_FORCE_BLANK, FB_PAL_ADDR, FB_PAL_DOUT, FB_PAL_WR} = '0;

wire [1:0] ar = status[20:19];

assign VIDEO_ARX = (!ar) ? ((status[2] ) ? 8'd4 : 8'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? ((status[2] ) ? 8'd3 : 8'd4) : 12'd0;



`include "build_id.v" 

localparam CONF_STR = {
	"A.Druaga;;",
	"H0OJK,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H0O2,Orientation,Vert,Horz;",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Trig1,Trig2,Start 1P,Start 2P,Coin;",
	"V,v",`BUILD_DATE
};

// Status Bitmap:
// 0          1          2          3 
// 01234567890123456789012345678901
// 0123456789ABCDEFGHIJKLMNOPQRSTUV
// RAOfffmxttmmmmmmmmmddddooooo FSC

// (common)
wire	 	  dcCabinet  = 1'b0;				// (upright only)


reg mod_druaga = 0;
reg mod_digdug = 0;
reg mod_mappy  = 0;
reg mod_motos  = 0;
reg mod_pac   = 0;

reg [7:0] mod = 0;
always @(posedge clk_sys) begin
	if (ioctl_wr & (ioctl_index==1)) mod <= ioctl_dout;
	
	mod_druaga <= (mod == 1);
	mod_mappy <= (mod == 2);
	mod_digdug <= (mod == 3);
	mod_motos <= (mod == 4);
	mod_pac <= (mod == 5);
	
end

// DIP SWITCHES
reg [7:0] sw[8];
always @(posedge clk_sys) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;


////////////////////   CLOCKS   ///////////////////

wire clk_48M;
wire clk_hdmi = clk_48M;
wire clock_48 = clk_48M;
wire clk_sys = clk_48M;
wire clock_6;
pll pll
(
	.rst(0),
	.refclk(CLK_50M),
	.outclk_0(clk_48M),
	.outclk_1(clock_6)
);

///////////////////////////////////////////////////

wire [31:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;

wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;

wire [10:0] ps2_key;
wire [15:0] joystk1, joystk2;

wire [21:0] gamma_bus;

hps_io #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.conf_str(CONF_STR),

	.buttons(buttons),

	.status(status),
	.status_menumask({direct_video}),

	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	
	.joystick_0(joystk1),
	.joystick_1(joystk2),
	.ps2_key(ps2_key)
);




wire bCabinet  = dcCabinet;

wire m_up2     = joystk2[3];
wire m_down2   = joystk2[2];
wire m_left2   = joystk2[1];
wire m_right2  = joystk2[0];
wire m_trig21  = joystk2[4];
wire m_trig22  = joystk2[5];

wire m_start1  = joystk1[6] | joystk2[6];
wire m_start2  = joystk1[7] | joystk2[7];

wire m_up1     = joystk1[3] | (bCabinet ? 1'b0 : m_up2);
wire m_down1   = joystk1[2] | (bCabinet ? 1'b0 : m_down2);
wire m_left1   = joystk1[1] | (bCabinet ? 1'b0 : m_left2);
wire m_right1  = joystk1[0] | (bCabinet ? 1'b0 : m_right2);
wire m_trig11  = joystk1[4] | (bCabinet ? 1'b0 : m_trig21);
wire m_trig12  = joystk1[5] | (bCabinet ? 1'b0 : m_trig22);

wire m_coin1   = joystk1[8];
wire m_coin2   = joystk2[8];


///////////////////////////////////////////////////

wire hblank, vblank;
wire ce_vid;
wire hs, vs;
wire [3:0] r,g,b;

reg ce_pix;
always @(posedge clk_hdmi) begin
	reg old_clk;
	old_clk <= ce_vid;
	ce_pix  <= old_clk & ~ce_vid;
end

wire no_rotate = status[2] | direct_video;
wire rotate_ccw = 0;
screen_rotate screen_rotate (.*);

arcade_video #(288,12) arcade_video
(
	.*,

	.clk_video(clk_hdmi),

	.RGB_in(POUT),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(~hs),
	.VSync(~vs),

	.fx(status[5:3])
);

wire			PCLK;
wire			PCLK_EN;
wire  [8:0] HPOS,VPOS;
wire [11:0] POUT;
hvgen hvgen(
	.MCLK(clock_48),
	.HPOS(HPOS),
	.VPOS(VPOS),
	.PCLK(PCLK),
	.PCLK_EN(PCLK_EN),
	.HBLK(hblank),
	.VBLK(vblank),
	.HSYN(hs),
	.VSYN(vs)
);
assign ce_vid = PCLK;


wire [15:0] AOUT;
assign AUDIO_L = AOUT;
assign AUDIO_R = AUDIO_L;
assign AUDIO_S = 0; // unsigned PCM


///////////////////////////////////////////////////

wire	iRST = RESET | status[0] | buttons[1] | ioctl_download;

wire  [5:0]	INP0 = { m_trig12, m_trig11, m_left1, m_down1, m_right1, m_up1 };
wire  [5:0]	INP1 = { m_trig22, m_trig21, m_left2, m_down2, m_right2, m_up2 };
wire	[2:0]	INP2 = { (m_coin1|m_coin2), m_start2, m_start1 };

wire  [7:0] oPIX;
wire  [7:0] oSND;

wire [14:0] rom_addr;
wire [7:0] rom_do;
wire [12:0] snd_addr;
wire [7:0] snd_do;
/*
ROM map
00000-07FFF   cpu0     32k 3.1d+1.1b (+2.1c in Mappy)
08000-0BFFF   spchip0  16k 6.3m
0C000-0FFFF   spchip1  16k 7.3m
10000-11FFF   cpu1      8k 4.1k
12000-12FFF   bgchip    4k 5.3b
13000-133FF   spclut    1k 7.5k
13400-134FF   bgclut  256b 6.4c
13500-135FF   wave    256b 3.3m
13600-1361F   palet    32b 5.5b
*/wire rom_dl = ioctl_addr < 'h08000;
dpram  #(.dwidth(8),.awidth(15)) rom
(
		.clk_a(clk_sys),
		.we_a(ioctl_wr & ioctl_index==0 && rom_dl),
		.addr_a(ioctl_addr[14:0]),
		.d_a(ioctl_dout),

		.clk_b(clk_sys),
		.we_b(1'b0),
		.addr_b(rom_addr),
		.q_b(rom_do)
	);
wire snd_dl = ioctl_addr >= 'h08000 && ioctl_addr <'h10000;
dpram  #(.dwidth(8),.awidth(15)) snd_rom
(
		.clk_a(clk_sys),
		.we_a(ioctl_wr & ioctl_index==0 && snd_dl),
		.addr_a(ioctl_addr[14:0]),
		.d_a(ioctl_dout),

		.clk_b(clk_sys),
		.we_b(1'b0),
		.addr_b(snd_addr),
		.q_b(snd_do)
	);
	
	
wire [1:0] dtLives	 = status[9:8];

wire [7:0] tDSW0 = {2'd0,dtLives,4'd0};
wire [7:0] tDSW1 = {1'b0,6'd0,1'b0};
wire [7:0] tDSW2 = {tDSW1[3:0],1'b0,3'd0};
	
fpga_druaga GameCore ( 
	.RESET(iRST),
	.CLKCPUx2(clock_6),
	.MCLK(clk_48M),
	.PH(HPOS),.PV(VPOS),.PCLK(PCLK),.POUT(oPIX),
	.PCLK_EN(PCLK_EN),
	.SOUT(oSND),

	.INP0(INP0),
	.INP1(INP1),
	.INP2(INP2),
	.DSW0(sw[0]),
	.DSW1(sw[1]),
	.DSW2(sw[2]),



	.rom_addr(rom_addr),
	.rom_data(rom_do),
	.snd_addr(snd_addr),
	.snd_data(snd_do),

	
	//.ROMCL(clk_sys),
	.ROMAD(ioctl_addr),.ROMDT(ioctl_dout),.ROMEN(ioctl_wr & (ioctl_index == 0)),
	
	.MODEL(mod[2:0])

	
);



assign POUT = {oPIX[7:6],2'b00,oPIX[5:3],1'b0,oPIX[2:0],1'b0};
assign AOUT = {oSND,8'h0};

endmodule



