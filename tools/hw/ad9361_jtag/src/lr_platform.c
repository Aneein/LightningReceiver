/*
 * Lightning Receiver - no-OS platform layer over the JTAG-AXI TCP bridge.
 *
 * SPI: the FPGA SPI master (rtl/control/ad9361_spi_master.v) moves exactly
 * one 24-bit AD9361 transaction (16-bit instruction + 1 data byte).  The
 * driver issues multi-byte transfers {cmd_hi, cmd_lo, data...}; AD9361
 * multi-byte access in MSB-first mode walks the register address downwards,
 * so an N-byte transfer at address A is split into N single-byte
 * transactions at A, A-1, ..., A-N+1.
 */
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "lr_platform.h"
#include "no_os_delay.h"
#include "no_os_axi_io.h"

unsigned long lr_spi_count;
unsigned long lr_axi_count;

static SOCKET lr_sock = INVALID_SOCKET;
static char lr_rxbuf[512];
static int lr_rxlen;

/* ------------------------------------------------------------------ link */
int lr_link_open(const char *host, int port)
{
	WSADATA wsa;
	struct sockaddr_in sa;

	if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
		return -1;
	lr_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (lr_sock == INVALID_SOCKET)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((u_short)port);
	sa.sin_addr.s_addr = inet_addr(host);
	if (connect(lr_sock, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
		closesocket(lr_sock);
		lr_sock = INVALID_SOCKET;
		return -1;
	}
	return 0;
}

void lr_link_close(void)
{
	if (lr_sock != INVALID_SOCKET) {
		send(lr_sock, "Q\n", 2, 0);
		closesocket(lr_sock);
		lr_sock = INVALID_SOCKET;
	}
	WSACleanup();
}

/* Send one command line, receive one reply line ("OK ..." / "ERR ..."). */
static int lr_cmd(const char *cmd, char *reply, int reply_len)
{
	int n = (int)strlen(cmd);
	char *nl;

	if (lr_sock == INVALID_SOCKET)
		return -1;
	if (send(lr_sock, cmd, n, 0) != n || send(lr_sock, "\n", 1, 0) != 1)
		return -1;
	for (;;) {
		nl = memchr(lr_rxbuf, '\n', lr_rxlen);
		if (nl) {
			int len = (int)(nl - lr_rxbuf);
			if (len > 0 && lr_rxbuf[len - 1] == '\r')
				len--;
			if (len >= reply_len)
				len = reply_len - 1;
			memcpy(reply, lr_rxbuf, len);
			reply[len] = '\0';
			lr_rxlen -= (int)(nl - lr_rxbuf) + 1;
			memmove(lr_rxbuf, nl + 1, lr_rxlen);
			break;
		}
		if (lr_rxlen >= (int)sizeof(lr_rxbuf))
			return -1;
		n = recv(lr_sock, lr_rxbuf + lr_rxlen, (int)sizeof(lr_rxbuf) - lr_rxlen, 0);
		if (n <= 0)
			return -1;
		lr_rxlen += n;
	}
	if (strncmp(reply, "OK", 2) != 0) {
		fprintf(stderr, "bridge: '%s' -> %s\n", cmd, reply);
		return -1;
	}
	return 0;
}

int lr_reg_read(uint32_t addr, uint32_t *val)
{
	char cmd[32], rep[128];

	snprintf(cmd, sizeof(cmd), "R %08X", (unsigned)addr);
	if (lr_cmd(cmd, rep, sizeof(rep)))
		return -1;
	*val = (uint32_t)strtoul(rep + 3, NULL, 16);
	lr_axi_count++;
	return 0;
}

int lr_reg_write(uint32_t addr, uint32_t val)
{
	char cmd[48], rep[128];

	snprintf(cmd, sizeof(cmd), "W %08X %08X", (unsigned)addr, (unsigned)val);
	lr_axi_count++;
	return lr_cmd(cmd, rep, sizeof(rep));
}

int lr_spi_xfer(uint32_t tx24, uint32_t *rx24)
{
	char cmd[32], rep[128];

	snprintf(cmd, sizeof(cmd), "S %06X", (unsigned)(tx24 & 0xFFFFFF));
	if (lr_cmd(cmd, rep, sizeof(rep)))
		return -1;
	if (rx24)
		*rx24 = (uint32_t)strtoul(rep + 3, NULL, 16);
	lr_spi_count++;
	return 0;
}

/* ------------------------------------------------------------------- SPI */
static int32_t lr_spi_init(struct no_os_spi_desc **desc,
			   const struct no_os_spi_init_param *param)
{
	struct no_os_spi_desc *d = calloc(1, sizeof(*d));

	if (!d)
		return -ENOMEM;
	d->device_id = param->device_id;
	d->max_speed_hz = param->max_speed_hz;
	d->chip_select = param->chip_select;
	d->mode = param->mode;
	*desc = d;
	return 0;
}

static int32_t lr_spi_remove(struct no_os_spi_desc *desc)
{
	free(desc);
	return 0;
}

static int32_t lr_spi_write_and_read(struct no_os_spi_desc *desc,
				     uint8_t *data, uint16_t bytes_number)
{
	uint16_t cmd, addr;
	int write, i, n;
	uint32_t rx;

	(void)desc;
	if (bytes_number < 3)
		return -EINVAL;
	cmd = (uint16_t)((data[0] << 8) | data[1]);
	write = (cmd >> 15) & 1;
	n = bytes_number - 2;
	addr = cmd & 0x3FF;
	for (i = 0; i < n; i++) {
		uint16_t c = (uint16_t)((write << 15) | ((addr - i) & 0x3FF)); /* count=1 */
		uint32_t tx = ((uint32_t)c << 8) | (write ? data[2 + i] : 0);
		if (lr_spi_xfer(tx, &rx))
			return -EIO;
		if (!write)
			data[2 + i] = (uint8_t)(rx & 0xFF);
	}
	return 0;
}

const struct no_os_spi_platform_ops lr_spi_ops = {
	.init = lr_spi_init,
	.write_and_read = lr_spi_write_and_read,
	.transfer = NULL,
	.remove = lr_spi_remove,
};

/* ------------------------------------------------------------------ GPIO */
/* RESETB/SYNC/CAL_SW are not routed to the FPGA on this carrier; all GPIO
 * numbers are -1 and the driver falls back to an SPI soft reset.  These ops
 * exist only to satisfy the init-param structure. */
static int32_t lr_gpio_get(struct no_os_gpio_desc **d,
			   const struct no_os_gpio_init_param *p)
{
	(void)d; (void)p;
	return -1;
}
static int32_t lr_gpio_remove(struct no_os_gpio_desc *d) { (void)d; return 0; }
static int32_t lr_gpio_noarg(struct no_os_gpio_desc *d) { (void)d; return 0; }
static int32_t lr_gpio_set(struct no_os_gpio_desc *d, uint8_t v) { (void)d; (void)v; return 0; }
static int32_t lr_gpio_getv(struct no_os_gpio_desc *d, uint8_t *v) { (void)d; *v = 0; return 0; }

const struct no_os_gpio_platform_ops lr_gpio_ops = {
	.gpio_ops_get = lr_gpio_get,
	.gpio_ops_get_optional = lr_gpio_get,
	.gpio_ops_remove = lr_gpio_remove,
	.gpio_ops_direction_input = lr_gpio_noarg,
	.gpio_ops_direction_output = lr_gpio_set,
	.gpio_ops_get_direction = lr_gpio_getv,
	.gpio_ops_set_value = lr_gpio_set,
	.gpio_ops_get_value = lr_gpio_getv,
};

/* ---------------------------------------------------------------- compat */
char *strsep(char **stringp, const char *delim)
{
	char *s = *stringp, *p;

	if (!s)
		return NULL;
	p = s + strcspn(s, delim);
	if (*p) {
		*p = '\0';
		*stringp = p + 1;
	} else {
		*stringp = NULL;
	}
	return s;
}

/* ---------------------------------------------------------- AXI / delays */
int32_t no_os_axi_io_read(uint32_t base, uint32_t offset, uint32_t *data)
{
	return lr_reg_read(base + offset, data) ? -EIO : 0;
}

int32_t no_os_axi_io_write(uint32_t base, uint32_t offset, uint32_t data)
{
	return lr_reg_write(base + offset, data) ? -EIO : 0;
}

/* One bridge round trip already takes ~1.5 ms, so microsecond waits are
 * satisfied by the access latency; still honour long ones exactly. */
void no_os_udelay(uint32_t usecs)
{
	if (usecs >= 1000)
		Sleep((usecs + 999) / 1000);
}

void no_os_mdelay(uint32_t msecs)
{
	Sleep(msecs);
}
