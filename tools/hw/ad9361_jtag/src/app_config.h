/*
 * Lightning Receiver - no-OS AD9361 build configuration (host, JTAG bridge).
 * No XILINX/ALTERA/LINUX platform: all hardware access goes through
 * lr_platform.c.  The AXI ADC core is present (axi_ad9361 at 0x44A00000).
 */
#ifndef CONFIG_H_
#define CONFIG_H_

#define HAVE_SPLIT_GAIN_TABLE	1
#define HAVE_TDD_SYNTH_TABLE	1

#define AD9361_DEVICE			1
#define AD9364_DEVICE			0
#define AD9363A_DEVICE			0

#define HAVE_VERBOSE_MESSAGES	/* driver errors and warnings to stdout */

#endif
