/*
 * Lightning Receiver - no-OS platform layer over the JTAG-AXI TCP bridge
 * (tools/hw/lr_jtag_bridge.tcl).  The FPGA has no CPU: every SPI and AXI
 * access of the ADI no-OS AD9361 driver is forwarded to the bridge.
 */
#ifndef LR_PLATFORM_H
#define LR_PLATFORM_H

#include <stdint.h>
#include "no_os_spi.h"
#include "no_os_gpio.h"

/* jtag_axi_0 address map (assign_bd_address in lr_bd_s2.tcl) */
#define LR_AD9361_RX_BASE   0x44A00000u
#define LR_AD9361_TX_BASE   0x44A04000u
#define LR_REG_BASE         0x44A20000u

extern const struct no_os_spi_platform_ops lr_spi_ops;
extern const struct no_os_gpio_platform_ops lr_gpio_ops;
extern unsigned long lr_spi_count;
extern unsigned long lr_axi_count;

int lr_link_open(const char *host, int port);
void lr_link_close(void);
int lr_reg_read(uint32_t addr, uint32_t *val);
int lr_reg_write(uint32_t addr, uint32_t val);
int lr_spi_xfer(uint32_t tx24, uint32_t *rx24);

#endif
