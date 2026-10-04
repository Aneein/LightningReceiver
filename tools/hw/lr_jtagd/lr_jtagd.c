/*
 * Lightning Receiver - lr_jtagd: FT2232H MPSSE JTAG daemon (no Vivado).
 *
 * Talks to the FPGA's open JTAG-to-AXI bridge (rtl/control/lr_jtag_axi_core.v,
 * BSCANE2 USER4) through the on-board FT2232H (channel A, MPSSE) using the
 * FTDI D2XX driver (ftd2xx.dll, loaded at run time), and serves the same TCP
 * line protocol as tools/hw/lr_jtag_bridge.tcl on 127.0.0.1:<port>:
 *
 *   R <addr>        -> OK <data>          W <addr> <data> -> OK
 *   B <addr> <n>    -> OK <w0> ...        S <tx24>        -> OK <rx24>
 *   I               -> OK <info>          P -> OK pong    Q -> OK bye
 *
 *   lr_jtagd [--port 5555] [--tck-khz 15000] [--serial S] [--probe]
 *
 * --probe checks the link stage by stage and prints "LR_PROBE <key>=<value>"
 * lines (used by the desktop app's start-up self test), then exits:
 *   0 all good, 2 FTDI driver missing, 3 no cable, 4 cable busy,
 *   5 JTAG chain dead, 6 bridge absent (old bitstream), 7 AXI no response,
 *   8 not an LR FM design.
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ D2XX */
typedef PVOID FT_HANDLE;
typedef ULONG FT_STATUS;
#define FT_OK 0
typedef FT_STATUS (WINAPI *pCreateList)(LPDWORD);
typedef FT_STATUS (WINAPI *pGetDetail)(DWORD, LPDWORD, LPDWORD, LPDWORD, LPDWORD,
                                       LPVOID, LPVOID, FT_HANDLE *);
typedef FT_STATUS (WINAPI *pOpen)(int, FT_HANDLE *);
typedef FT_STATUS (WINAPI *pClose)(FT_HANDLE);
typedef FT_STATUS (WINAPI *pReset)(FT_HANDLE);
typedef FT_STATUS (WINAPI *pPurge)(FT_HANDLE, ULONG);
typedef FT_STATUS (WINAPI *pUsbParams)(FT_HANDLE, ULONG, ULONG);
typedef FT_STATUS (WINAPI *pChars)(FT_HANDLE, UCHAR, UCHAR, UCHAR, UCHAR);
typedef FT_STATUS (WINAPI *pTimeouts)(FT_HANDLE, ULONG, ULONG);
typedef FT_STATUS (WINAPI *pLatency)(FT_HANDLE, UCHAR);
typedef FT_STATUS (WINAPI *pBitMode)(FT_HANDLE, UCHAR, UCHAR);
typedef FT_STATUS (WINAPI *pWrite)(FT_HANDLE, LPVOID, DWORD, LPDWORD);
typedef FT_STATUS (WINAPI *pRead)(FT_HANDLE, LPVOID, DWORD, LPDWORD);
typedef FT_STATUS (WINAPI *pQueue)(FT_HANDLE, DWORD *);

static struct {
	HMODULE dll;
	pCreateList CreateDeviceInfoList;
	pGetDetail GetDeviceInfoDetail;
	pOpen Open;
	pClose Close;
	pReset ResetDevice;
	pPurge Purge;
	pUsbParams SetUSBParameters;
	pChars SetChars;
	pTimeouts SetTimeouts;
	pLatency SetLatencyTimer;
	pBitMode SetBitMode;
	pWrite Write;
	pRead Read;
	pQueue GetQueueStatus;
} ft;

static FT_HANDLE g_ft;
static uint32_t g_idcode;
static int g_tck_khz = 15000;
static char g_serial[32];
static char g_last_err[256];

#define LR_BASE 0x44A20000u

static int ft_load(void)
{
	ft.dll = LoadLibraryA("ftd2xx.dll");
	if (!ft.dll)
		return -1;
#define LOAD(f, n) if (!(ft.f = (void *)GetProcAddress(ft.dll, n))) return -1
	LOAD(CreateDeviceInfoList, "FT_CreateDeviceInfoList");
	LOAD(GetDeviceInfoDetail, "FT_GetDeviceInfoDetail");
	LOAD(Open, "FT_Open");
	LOAD(Close, "FT_Close");
	LOAD(ResetDevice, "FT_ResetDevice");
	LOAD(Purge, "FT_Purge");
	LOAD(SetUSBParameters, "FT_SetUSBParameters");
	LOAD(SetChars, "FT_SetChars");
	LOAD(SetTimeouts, "FT_SetTimeouts");
	LOAD(SetLatencyTimer, "FT_SetLatencyTimer");
	LOAD(SetBitMode, "FT_SetBitMode");
	LOAD(Write, "FT_Write");
	LOAD(Read, "FT_Read");
	LOAD(GetQueueStatus, "FT_GetQueueStatus");
#undef LOAD
	return 0;
}

/* --------------------------------------------------------- MPSSE buffer */
static uint8_t g_out[1 << 17];
static int g_nout;
static int g_nexp; /* bytes the MPSSE will return for the queued commands */

static void q(uint8_t b) { g_out[g_nout++] = b; }

/* TMS sequence, up to 7 bits, LSB first; TDI held at 'tdi'. */
static void q_tms(uint8_t bits, int n, int tdi)
{
	q(0x4B); q((uint8_t)(n - 1)); q((uint8_t)((bits & 0x7F) | (tdi ? 0x80 : 0)));
}

/* Run-Test/Idle clocks (TMS = 0). */
static void q_idle(int n)
{
	while (n > 0) {
		int k = n > 7 ? 7 : n;
		q_tms(0, k, 0);
		n -= k;
	}
}

/* Shift nbits from tdi[] (LSB first) while reading TDO; the last bit is
 * clocked with TMS=1 (Shift -> Exit1).  Returns via g_nexp bookkeeping. */
static void q_shift(const uint8_t *tdi, int nbits)
{
	int nbytes = (nbits - 1) / 8;
	int rem = (nbits - 1) % 8;
	int i;
	if (nbytes) {
		q(0x39); q((uint8_t)((nbytes - 1) & 0xFF)); q((uint8_t)((nbytes - 1) >> 8));
		for (i = 0; i < nbytes; i++)
			q(tdi[i]);
		g_nexp += nbytes;
	}
	if (rem) {
		q(0x3B); q((uint8_t)(rem - 1)); q(tdi[nbytes]);
		g_nexp += 1;
	}
	{
		int last = (tdi[(nbits - 1) / 8] >> ((nbits - 1) % 8)) & 1;
		q(0x6B); q(0x00); q((uint8_t)(0x01 | (last ? 0x80 : 0)));
		g_nexp += 1;
	}
}

/* Unpack the bytes returned for one q_shift() into out[] (LSB first). */
static int unpack_shift(const uint8_t *in, int nbits, uint8_t *out)
{
	int nbytes = (nbits - 1) / 8;
	int rem = (nbits - 1) % 8;
	int pos = 0, i;
	memset(out, 0, (nbits + 7) / 8);
	for (i = 0; i < nbytes; i++)
		out[i] = in[pos++];
	if (rem)
		out[nbytes] = (uint8_t)(in[pos++] >> (8 - rem));
	if (in[pos++] & 0x80)
		out[(nbits - 1) / 8] |= (uint8_t)(1 << ((nbits - 1) % 8));
	return pos;
}

static int mpsse_flush(uint8_t *in)
{
	DWORD n = 0, got = 0, t0;
	int want = g_nexp;
	q(0x87); /* send immediate */
	if (ft.Write(g_ft, g_out, (DWORD)g_nout, &n) != FT_OK || (int)n != g_nout) {
		snprintf(g_last_err, sizeof g_last_err, "USB write failed (cable unplugged?)");
		g_nout = g_nexp = 0;
		return -1;
	}
	g_nout = 0;
	g_nexp = 0;
	t0 = GetTickCount();
	while ((int)got < want) {
		DWORD r = 0;
		if (ft.Read(g_ft, in + got, (DWORD)(want - got), &r) != FT_OK) {
			snprintf(g_last_err, sizeof g_last_err, "USB read failed (cable unplugged?)");
			return -1;
		}
		got += r;
		if ((int)got < want && GetTickCount() - t0 > 2000) {
			snprintf(g_last_err, sizeof g_last_err, "USB read timeout");
			return -1;
		}
	}
	return 0;
}

/* -------------------------------------------------------------- JTAG/TAP */
/* From any state: Test-Logic-Reset, then Run-Test/Idle. */
static void q_reset(void) { q_tms(0x1F, 6, 0); }

/* Idle -> Shift-IR, shift ir (len bits), -> Update-IR -> Idle */
static void q_ir(uint32_t ir, int len)
{
	uint8_t b[4] = {(uint8_t)ir, (uint8_t)(ir >> 8), 0, 0};
	q_tms(0x03, 4, 0);          /* 1,1,0,0 */
	q_shift(b, len);
	q_tms(0x01, 2, 0);          /* 1,0 : Exit1 -> Update -> Idle */
}

/* Idle -> Shift-DR, shift, -> Update-DR -> Idle (+ idle clocks) */
static void q_dr(const uint8_t *din, int nbits, int idle)
{
	q_tms(0x01, 3, 0);          /* 1,0,0 */
	q_shift(din, nbits);
	q_tms(0x01, 2, 0);
	q_idle(idle);
}

static int mpsse_open(void)
{
	DWORD n = 0, i, flags, type, id, loc;
	char serial[16], desc[64];
	FT_HANDLE h;
	int index = -1;
	uint8_t in[8];
	DWORD w;
	int div;

	if (ft.CreateDeviceInfoList(&n) != FT_OK || n == 0)
		return 3;
	{
		int opened_hidden = 0, sibling_b = 0;
		for (i = 0; i < n; i++) {
			memset(serial, 0, sizeof serial);
			memset(desc, 0, sizeof desc);
			if (ft.GetDeviceInfoDetail(i, &flags, &type, &id, &loc, serial, desc, &h) != FT_OK)
				continue;
			/* An interface opened by another process (e.g. Vivado hw_server)
			 * is listed with FT_FLAGS_OPENED and no serial/description. */
			if ((flags & 1) && !serial[0])
				opened_hidden = 1;
			if (type == 6 && serial[0] && serial[strlen(serial) - 1] == 'B')
				sibling_b = 1;
			if (g_serial[0] ? !strcmp(serial, g_serial)
			                : (type == 6 /* FT2232H */ && serial[0] &&
			                   serial[strlen(serial) - 1] == 'A')) {
				index = (int)i;
				snprintf(g_serial, sizeof g_serial, "%s", serial);
				if (flags & 1) /* FT_FLAGS_OPENED */
					return 4;
				break;
			}
		}
		if (index < 0)
			/* channel A not visible but its UART sibling is and something
			 * holds a hidden interface: the JTAG channel is in use */
			return (opened_hidden && sibling_b) ? 4 : 3;
	}
	if (ft.Open(index, &g_ft) != FT_OK)
		return 4;
	ft.ResetDevice(g_ft);
	ft.SetUSBParameters(g_ft, 65536, 65536);
	ft.SetChars(g_ft, 0, 0, 0, 0);
	ft.SetTimeouts(g_ft, 1000, 1000);
	ft.SetLatencyTimer(g_ft, 2);
	ft.SetBitMode(g_ft, 0, 0);
	ft.SetBitMode(g_ft, 0, 2); /* MPSSE */
	Sleep(50);
	ft.Purge(g_ft, 3);
	/* synchronise: a bad opcode is echoed as 0xFA 0xAA */
	{
		uint8_t bad = 0xAA;
		DWORD r = 0, t0 = GetTickCount();
		int got = 0;
		ft.Write(g_ft, &bad, 1, &w);
		while (got < 2 && GetTickCount() - t0 < 500) {
			ft.Read(g_ft, in + got, 2 - got, &r);
			got += (int)r;
		}
		if (got < 2 || in[0] != 0xFA || in[1] != 0xAA) {
			snprintf(g_last_err, sizeof g_last_err, "MPSSE did not synchronise");
			return 3;
		}
	}
	div = 60000 / (2 * g_tck_khz) - 1;
	if (div < 0) div = 0;
	g_tck_khz = 60000 / (2 * (div + 1));
	q(0x8A); q(0x97); q(0x8D);                 /* 60 MHz, no adaptive, no 3-phase */
	q(0x86); q((uint8_t)div); q((uint8_t)(div >> 8));
	q(0x80); q(0x08); q(0x0B);                 /* TCK/TDI/TMS out, TMS=1 */
	q(0x82); q(0x00); q(0x00);
	q(0x85);                                   /* loopback off */
	q_reset();
	ft.Write(g_ft, g_out, (DWORD)g_nout, &w);
	g_nout = 0;
	return 0;
}

static int read_idcode(uint32_t *idc)
{
	uint8_t zero[4] = {0}, in[16], out[4];
	q_reset();                 /* IDCODE is the default DR after reset */
	q_dr(zero, 32, 0);
	if (mpsse_flush(in))
		return -1;
	unpack_shift(in, 32, out);
	*idc = out[0] | (out[1] << 8) | (out[2] << 16) | ((uint32_t)out[3] << 24);
	return 0;
}

/* -------------------------------------------------------------- bridge */
#define DR_W 72
#define IR_USER4 0x23
#define IR_LEN 6
#define IDLE_TCK 24
#define MAX_BATCH 512

typedef struct { int op; uint32_t addr, wdata; uint32_t rdata; int resp; } cmd_t;

static void frame(uint8_t *b, int op, uint32_t addr, uint32_t wd, int tag)
{
	/* [1:0] op, [35:4] addr, [67:36] wdata, [71:68] tag */
	uint64_t lo = (uint64_t)(op & 3) | ((uint64_t)addr << 4) | ((uint64_t)(wd & 0x0FFFFFFF) << 36);
	int i;
	for (i = 0; i < 8; i++)
		b[i] = (uint8_t)(lo >> (8 * i));
	b[8] = (uint8_t)(((wd >> 28) & 0xF) | ((tag & 0xF) << 4));
}

typedef struct { int valid, busy, overrun, resp, tag; uint32_t rdata, magic, version; } status_t;

static void parse_status(const uint8_t *b, status_t *s)
{
	uint64_t lo = 0;
	int i;
	for (i = 0; i < 8; i++)
		lo |= (uint64_t)b[i] << (8 * i);
	s->valid = (int)(lo & 1);
	s->busy = (int)((lo >> 1) & 1);
	s->overrun = (int)((lo >> 2) & 1);
	s->resp = (int)((lo >> 3) & 3);
	s->rdata = (uint32_t)(lo >> 5);
	s->tag = (int)((lo >> 37) & 0xF);
	s->version = (uint32_t)((lo >> 44) & 0xF);
	s->magic = (uint32_t)(lo >> 48) | ((uint32_t)b[8] << 16);
}

static int g_ir_user4;
static int g_tag;

/* Poll with NOP scans until the bridge is idle; returns the final status. */
static int wait_idle(status_t *st)
{
	static uint8_t in[64];
	uint8_t nop[9], o[9];
	int tries;
	frame(nop, 0, 0, 0, 0);
	for (tries = 0; tries < 2000; tries++) {
		q_dr(nop, DR_W, 64);
		if (mpsse_flush(in))
			return -1;
		unpack_shift(in, DR_W, o);
		parse_status(o, st);
		if (st->magic != 0x4C524A) {
			snprintf(g_last_err, sizeof g_last_err, "LR JTAG bridge disappeared (FPGA reconfigured?)");
			g_ir_user4 = 0;
			return -2;
		}
		if (!st->busy)
			return 0;
	}
	snprintf(g_last_err, sizeof g_last_err, "AXI access did not complete (bus hung?)");
	return -3;
}

static int send_clear(void)
{
	static uint8_t in[64];
	uint8_t b[9];
	frame(b, 3, 0, 0, 0);
	q_dr(b, DR_W, 4);
	return mpsse_flush(in);
}

/*
 * Execute cmds[] in order.  Each batch issues k command scans plus one NOP
 * scan; S[s] is the status captured by scan s, so S[j+1] carries the result
 * of command j.  Because overrun is sticky in the FPGA, the accepted
 * commands form a prefix: the first j with S[j+1].overrun is the first
 * dropped command, everything before it executed exactly once.  Reads whose
 * result was overwritten (bridge busy at that capture) are simply re-read.
 */
static int bridge_exec(cmd_t *c, int n)
{
	static uint8_t in[(MAX_BATCH + 1) * 12 + 64];
	static status_t S[MAX_BATCH + 1];
	static int lost[MAX_BATCH];
	int done = 0;

	while (done < n) {
		int k = n - done > MAX_BATCH ? MAX_BATCH : n - done;
		int i, pos = 0, d, anomaly = 0, ir_now = !g_ir_user4, tag0 = g_tag;
		uint8_t b[9], o[9];

		if (ir_now) {
			q_ir(IR_USER4, IR_LEN);
			g_ir_user4 = 1;
		}
		for (i = 0; i <= k; i++) {
			if (i < k)
				frame(b, c[done + i].op, c[done + i].addr, c[done + i].wdata, (tag0 + i) & 0xF);
			else
				frame(b, 0, 0, 0, 0);
			q_dr(b, DR_W, IDLE_TCK);
		}
		if (mpsse_flush(in))
			return -1;
		if (ir_now)
			pos += 2;                      /* IR shift read-back bytes */
		for (i = 0; i <= k; i++) {
			pos += unpack_shift(in + pos, DR_W, o);
			parse_status(o, &S[i]);
			if (S[i].magic != 0x4C524A) {
				snprintf(g_last_err, sizeof g_last_err,
				         "LR JTAG bridge not found in FPGA (USER4 magic 0x%06X)", S[i].magic);
				g_ir_user4 = 0;
				return -2;
			}
		}
		g_tag = (tag0 + k) & 0xF;
		if (S[0].overrun) {
			/* left over from an earlier anomaly: nothing accepted */
			d = 0;
		} else {
			for (d = 0; d < k && !S[d + 1].overrun; d++)
				;
		}
		for (i = 0; i < d; i++) {
			const status_t *r = &S[i + 1];
			lost[i] = 0;
			if (r->valid && !r->busy && r->tag == ((tag0 + i) & 0xF)) {
				c[done + i].rdata = r->rdata;
				c[done + i].resp = r->resp;
			} else {
				lost[i] = 1;          /* executed, result not captured */
				c[done + i].resp = 0;
				anomaly = 1;
			}
		}
		if (d < k || S[0].overrun)
			anomaly = 1;
		if (anomaly) {
			status_t f;
			int r = wait_idle(&f);
			if (r)
				return r;
			/* the last accepted command's result may still be here */
			if (d > 0 && lost[d - 1] && f.valid && f.tag == ((tag0 + d - 1) & 0xF)) {
				c[done + d - 1].rdata = f.rdata;
				c[done + d - 1].resp = f.resp;
				lost[d - 1] = 0;
			}
			if (f.overrun && send_clear())
				return -1;
			for (i = 0; i < d; i++) {
				if (lost[i] && c[done + i].op == 2) {
					cmd_t one = c[done + i];
					if (bridge_exec(&one, 1))
						return -1;
					c[done + i] = one;
				}
			}
		}
		done += d;
	}
	return 0;
}

static int lr_read(uint32_t addr, uint32_t *v)
{
	cmd_t c = {2, addr, 0, 0, 0};
	int r = bridge_exec(&c, 1);
	if (r) return r;
	if (c.resp) { snprintf(g_last_err, sizeof g_last_err, "AXI read error resp %d at %08X", c.resp, addr); return -4; }
	*v = c.rdata;
	return 0;
}

static int lr_write(uint32_t addr, uint32_t v)
{
	cmd_t c = {1, addr, v, 0, 0};
	int r = bridge_exec(&c, 1);
	if (r) return r;
	if (c.resp) { snprintf(g_last_err, sizeof g_last_err, "AXI write error resp %d at %08X", c.resp, addr); return -4; }
	return 0;
}

static int lr_spi(uint32_t tx, uint32_t *rx)
{
	cmd_t c[4] = {
		{1, LR_BASE + 0x050, tx & 0xFFFFFF, 0, 0},
		{1, LR_BASE + 0x05C, 1, 0, 0},
		{2, LR_BASE + 0x058, 0, 0, 0},
		{2, LR_BASE + 0x054, 0, 0, 0},
	};
	int tries;
	if (bridge_exec(c, 4)) return -1;
	for (tries = 0; (c[2].rdata & 1) && tries < 100; tries++) {
		cmd_t s[2] = {{2, LR_BASE + 0x058, 0, 0, 0}, {2, LR_BASE + 0x054, 0, 0, 0}};
		if (bridge_exec(s, 2)) return -1;
		c[2] = s[0];
		c[3] = s[1];
	}
	if (c[2].rdata & 1) { snprintf(g_last_err, sizeof g_last_err, "SPI busy timeout"); return -5; }
	*rx = c[3].rdata & 0xFFFFFF;
	return 0;
}

/* ------------------------------------------------------------- probe/IO */
static int probe(int verbose)
{
	uint32_t id;
	int r;
	if (ft_load()) {
		printf("LR_PROBE ftdi=missing_dll\n");
		return 2;
	}
	r = mpsse_open();
	if (r == 3) { printf("LR_PROBE ftdi=no_device%s%s\n", g_last_err[0] ? " msg=" : "", g_last_err); return 3; }
	if (r == 4) { printf("LR_PROBE ftdi=busy serial=%s\n", g_serial); return 4; }
	printf("LR_PROBE ftdi=ok serial=%s tck_khz=%d\n", g_serial, g_tck_khz);
	if (read_idcode(&g_idcode) || g_idcode == 0 || g_idcode == 0xFFFFFFFF || !(g_idcode & 1)) {
		printf("LR_PROBE chain=dead idcode=0x%08X\n", g_idcode);
		return 5;
	}
	printf("LR_PROBE chain=ok idcode=0x%08X\n", g_idcode);
	r = lr_read(LR_BASE + 0x000, &id);
	if (r == -2) { printf("LR_PROBE bridge=absent\n"); return 6; }
	if (r) { printf("LR_PROBE bridge=ok axi=no_response msg=%s\n", g_last_err); return 7; }
	printf("LR_PROBE bridge=ok version=1\n");
	printf("LR_PROBE design_id=0x%08X\n", id);
	if ((id & 0xFFFFFF00u) != 0x4C520000u || (id & 0xFF) < 2)
		return 8;
	(void)verbose;
	return 0;
}

static void reply(SOCKET s, const char *txt)
{
	send(s, txt, (int)strlen(txt), 0);
	send(s, "\n", 1, 0);
}

static void handle_line(SOCKET s, char *line)
{
	char cmd = 0, out[256 * 9 + 16];
	unsigned a = 0, b = 0;
	uint32_t v;
	int r = 0;
	while (*line == ' ') line++;
	cmd = (char)toupper((unsigned char)line[0]);
	switch (cmd) {
	case 'P': reply(s, "OK pong"); return;
	case 'Q': reply(s, "OK bye"); return;
	case 'I':
		snprintf(out, sizeof out, "OK idcode=0x%08X serial=%s tck_khz=%d bridge=LRJ1",
		         g_idcode, g_serial, g_tck_khz);
		reply(s, out);
		return;
	case 'R':
		if (sscanf(line + 1, "%x", &a) != 1) break;
		r = lr_read(a, &v);
		if (!r) { snprintf(out, sizeof out, "OK %08X", v); reply(s, out); return; }
		break;
	case 'W':
		if (sscanf(line + 1, "%x %x", &a, &b) != 2) break;
		r = lr_write(a, b);
		if (!r) { reply(s, "OK"); return; }
		break;
	case 'S':
		if (sscanf(line + 1, "%x", &a) != 1) break;
		r = lr_spi(a, &v);
		if (!r) { snprintf(out, sizeof out, "OK %06X", v); reply(s, out); return; }
		break;
	case 'B': {
		static cmd_t c[256];
		int n, i, len;
		if (sscanf(line + 1, "%x %u", &a, &b) != 2 || b < 1 || b > 256) break;
		n = (int)b;
		for (i = 0; i < n; i++) {
			c[i].op = 2; c[i].addr = a + 4u * i; c[i].wdata = 0;
		}
		r = bridge_exec(c, n);
		if (r) break;
		len = snprintf(out, sizeof out, "OK");
		for (i = 0; i < n; i++)
			len += snprintf(out + len, sizeof out - len, " %08X", c[i].rdata);
		reply(s, out);
		return;
	}
	default:
		break;
	}
	snprintf(out, sizeof out, "ERR %s", r ? g_last_err : "bad command");
	reply(s, out);
}

int main(int argc, char **argv)
{
	int port = 5555, do_probe = 0, i, r;
	WSADATA wsa;
	SOCKET ls;
	struct sockaddr_in sa;
	SOCKET cl[16];
	char buf[16][1024];
	int blen[16];
	int ncl = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--tck-khz") && i + 1 < argc) g_tck_khz = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--serial") && i + 1 < argc) snprintf(g_serial, sizeof g_serial, "%s", argv[++i]);
		else if (!strcmp(argv[i], "--probe")) do_probe = 1;
		else if (!strcmp(argv[i], "--list")) {
			DWORD n = 0, j, fl, ty, id, loc;
			char sn[16], de[64];
			FT_HANDLE h;
			if (ft_load()) { printf("ftd2xx.dll not available\n"); return 2; }
			ft.CreateDeviceInfoList(&n);
			printf("%lu FTDI device(s)\n", (unsigned long)n);
			for (j = 0; j < n; j++) {
				memset(sn, 0, sizeof sn); memset(de, 0, sizeof de);
				ft.GetDeviceInfoDetail(j, &fl, &ty, &id, &loc, sn, de, &h);
				printf("  #%lu type=%lu flags=0x%lx id=0x%08lx loc=0x%lx serial='%s' desc='%s'\n",
				       (unsigned long)j, (unsigned long)ty, (unsigned long)fl,
				       (unsigned long)id, (unsigned long)loc, sn, de);
			}
			return 0;
		}
		else { fprintf(stderr, "usage: lr_jtagd [--port N] [--tck-khz K] [--serial S] [--probe]\n"); return 1; }
	}
	r = probe(0);
	if (do_probe) {
		if (g_ft) ft.Close(g_ft);
		return r;
	}
	if (r && r != 8) {
		printf("LR_JTAGD_FAIL code=%d %s\n", r, g_last_err);
		if (g_ft) ft.Close(g_ft);
		return r;
	}

	WSAStartup(MAKEWORD(2, 2), &wsa);
	ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	memset(&sa, 0, sizeof sa);
	sa.sin_family = AF_INET;
	sa.sin_port = htons((u_short)port);
	sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(ls, (struct sockaddr *)&sa, sizeof sa) || listen(ls, 4)) {
		printf("LR_JTAGD_FAIL code=9 port %d already in use\n", port);
		ft.Close(g_ft);
		return 9;
	}
	printf("LR_JTAGD_READY port=%d idcode=0x%08X serial=%s tck_khz=%d\n",
	       port, g_idcode, g_serial, g_tck_khz);

	for (;;) {
		fd_set rd;
		FD_ZERO(&rd);
		FD_SET(ls, &rd);
		for (i = 0; i < ncl; i++)
			FD_SET(cl[i], &rd);
		if (select(0, &rd, NULL, NULL, NULL) == SOCKET_ERROR)
			break;
		if (FD_ISSET(ls, &rd) && ncl < 16) {
			cl[ncl] = accept(ls, NULL, NULL);
			if (cl[ncl] != INVALID_SOCKET) {
				int one = 1;
				setsockopt(cl[ncl], IPPROTO_TCP, TCP_NODELAY, (char *)&one, sizeof one);
				blen[ncl++] = 0;
			}
		}
		for (i = 0; i < ncl; i++) {
			if (!FD_ISSET(cl[i], &rd))
				continue;
			r = recv(cl[i], buf[i] + blen[i], (int)sizeof buf[i] - 1 - blen[i], 0);
			if (r <= 0) {
				closesocket(cl[i]);
				cl[i] = cl[--ncl];
				memcpy(buf[i], buf[ncl], sizeof buf[i]);
				blen[i] = blen[ncl];
				i--;
				continue;
			}
			blen[i] += r;
			buf[i][blen[i]] = 0;
			for (;;) {
				char *nl = strchr(buf[i], '\n');
				int quit;
				if (!nl)
					break;
				*nl = 0;
				if (nl > buf[i] && nl[-1] == '\r')
					nl[-1] = 0;
				quit = (toupper((unsigned char)buf[i][0]) == 'Q');
				handle_line(cl[i], buf[i]);
				blen[i] -= (int)(nl + 1 - buf[i]);
				memmove(buf[i], nl + 1, blen[i] + 1);
				if (quit) {
					closesocket(cl[i]);
					cl[i] = cl[--ncl];
					memcpy(buf[i], buf[ncl], sizeof buf[i]);
					blen[i] = blen[ncl];
					i--;
					break;
				}
			}
		}
	}
	ft.Close(g_ft);
	return 0;
}
