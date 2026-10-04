/*
 * Lightning Receiver - AD9361 bring-up over JTAG (host program)
 *
 * Runs the ADI no-OS AD9361 driver on the PC; every SPI/AXI access goes to
 * the FPGA through tools/hw/lr_jtag_bridge.tcl (start it first).
 *
 *   ad9361_jtag [--port 5555] [--lo-hz 97950000] [--tune-hz 98000000]
 *               [--bw-hz 22000000] [--gain slow|fast|manual] [--gain-db N]
 *               [--deemph 50|75] [--bist-tone] [--status-only]
 *
 * Configuration (LR FM Phase-1):
 *   1R1T on RX1A / TX1A, LVDS, 61.44 Msps (the FPGA NCO and the 320x CIC
 *   assume this rate), RX LO below the station grid by default so stations
 *   never sit on DC, TX attenuation at maximum (TX is unused).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#include "ad9361_api.h"
#include "ad9361.h"
#include "lr_platform.h"
#include "no_os_delay.h"

extern AD9361_InitParam default_init_param;

#define LR_REG(off)         (LR_REG_BASE + (off))
#define LR_ID_FM1           0x4C520002u   /* first FM build: DC estimator bug */
#define LR_ID_FM1_FIX       0x4C520003u   /* bring-up fixes (DC, audio FIR, ...) */
#define LR_ID_FM1_JTAG      0x4C520004u   /* + open JTAG bridge (lr_jtagd) */
#define LR_SAMPLE_HZ        61440000u

struct lr_opts {
	int port;
	uint64_t lo_hz;
	uint64_t tune_hz;
	uint32_t bw_hz;
	int gain_mode;          /* RF_GAIN_* */
	int gain_db;
	int bist_tone;
	int status_only;
	int deemph_us;          /* 50 (China/EU) or 75 */
};

static void lr_usage(void)
{
	printf("usage: ad9361_jtag [--port N] [--lo-hz F] [--tune-hz F] [--bw-hz B]\n"
	       "                   [--gain slow|fast|manual] [--gain-db N]\n"
	       "                   [--deemph 50|75] [--bist-tone] [--status-only]\n");
}

static int lr_parse(int argc, char **argv, struct lr_opts *o)
{
	int i;

	o->port = 5555;
	o->lo_hz = 97950000ULL;      /* stations on the 100 kHz grid sit at +50 kHz + n*100 kHz */
	o->tune_hz = 0;              /* 0: LO + 50 kHz */
	o->bw_hz = 22000000;         /* covers the +/-10 MHz seek range */
	o->gain_mode = RF_GAIN_SLOWATTACK_AGC;
	o->gain_db = 30;
	o->bist_tone = 0;
	o->status_only = 0;
	o->deemph_us = 50;
	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
		if (!strcmp(a, "--port") && v) { o->port = atoi(v); i++; }
		else if (!strcmp(a, "--lo-hz") && v) { o->lo_hz = strtoull(v, NULL, 10); i++; }
		else if (!strcmp(a, "--tune-hz") && v) { o->tune_hz = strtoull(v, NULL, 10); i++; }
		else if (!strcmp(a, "--bw-hz") && v) { o->bw_hz = (uint32_t)strtoul(v, NULL, 10); i++; }
		else if (!strcmp(a, "--gain-db") && v) { o->gain_db = atoi(v); i++; }
		else if (!strcmp(a, "--gain") && v) {
			if (!strcmp(v, "slow")) o->gain_mode = RF_GAIN_SLOWATTACK_AGC;
			else if (!strcmp(v, "fast")) o->gain_mode = RF_GAIN_FASTATTACK_AGC;
			else if (!strcmp(v, "manual")) o->gain_mode = RF_GAIN_MGC;
			else return -1;
			i++;
		}
		else if (!strcmp(a, "--deemph") && v) {
			o->deemph_us = atoi(v);
			if (o->deemph_us != 50 && o->deemph_us != 75) return -1;
			i++;
		}
		else if (!strcmp(a, "--bist-tone")) o->bist_tone = 1;
		else if (!strcmp(a, "--status-only")) o->status_only = 1;
		else return -1;
	}
	if (o->tune_hz == 0)
		o->tune_hz = o->lo_hz + 50000;
	return 0;
}

static void lr_apply_overrides(const struct lr_opts *o)
{
	AD9361_InitParam *p = &default_init_param;
	/* Standard ADI 30.72 Msps clock chain for init; switched to 61.44 later
	 * (and the LVDS interface re-tuned) once the device is up. */
	static const uint32_t clk3072[6] = {
		983040000, 245760000, 122880000, 61440000, 30720000, 30720000
	};

	p->two_rx_two_tx_mode_enable = 0;
	p->one_rx_one_tx_mode_use_rx_num = 1;
	p->one_rx_one_tx_mode_use_tx_num = 1;
	p->rx_synthesizer_frequency_hz = o->lo_hz;
	p->tx_synthesizer_frequency_hz = 2400000000ULL;     /* far from the FM band */
	memcpy(p->rx_path_clock_frequencies, clk3072, sizeof(clk3072));
	memcpy(p->tx_path_clock_frequencies, clk3072, sizeof(clk3072));
	p->rf_rx_bandwidth_hz = o->bw_hz;
	p->rf_tx_bandwidth_hz = 18000000;
	p->rx_rf_port_input_select = 0;                     /* RX1A balanced */
	p->tx_attenuation_mdB = 89750;                      /* TX unused */
	p->gc_rx1_mode = (uint8_t)o->gain_mode;
	p->digital_interface_tune_skip_mode = 1;           /* tune RX only */
	p->gpio_resetb.number = -1;                         /* SPI soft reset */
}

static void lr_dump_lr(void)
{
	static const struct { const char *n; uint32_t off; } r[] = {
		{"ID", 0x000}, {"RF_FREQ", 0x010}, {"DDC_FREQ", 0x024},
		{"AUDIO_CFG", 0x038}, {"RF_STATUS", 0x01C}, {"ERR_STATUS", 0x048},
		{"UI_STATUS", 0x07C}, {"SEEK_CTRL", 0x080}, {"SIG_POWER", 0x088},
		{"SIG_QUALITY", 0x08C}, {"AUDIO_STATUS", 0x068},
		{"AUDIO_WR_WORDS", 0x06C},
	};
	unsigned i;
	uint32_t v;

	for (i = 0; i < sizeof(r) / sizeof(r[0]); i++) {
		if (lr_reg_read(LR_REG(r[i].off), &v) == 0)
			printf("  LR %-15s = 0x%08X\n", r[i].n, (unsigned)v);
	}
	if (lr_reg_read(LR_AD9361_RX_BASE + 0x5C, &v) == 0)
		printf("  axi_ad9361 STATUS     = 0x%08X\n", (unsigned)v);
	if (lr_reg_read(LR_AD9361_RX_BASE + 0x40, &v) == 0)
		printf("  axi_ad9361 RSTN       = 0x%08X\n", (unsigned)v);
}

int main(int argc, char **argv)
{
	struct lr_opts o;
	struct ad9361_rf_phy *phy = NULL;
	uint32_t id, fs = 0, bw = 0;
	uint64_t lo = 0;
	int32_t ret, gain = 0;
	int32_t ddc;

	setvbuf(stdout, NULL, _IONBF, 0);
	if (lr_parse(argc, argv, &o)) {
		lr_usage();
		return 2;
	}
	if (lr_link_open("127.0.0.1", o.port)) {
		fprintf(stderr, "cannot reach the JTAG bridge on 127.0.0.1:%d "
			"(start tools/hw/lr_jtag_bridge.tcl first)\n", o.port);
		return 1;
	}
	if (lr_reg_read(LR_REG(0x000), &id) || (id != LR_ID_FM1 && id != LR_ID_FM1_FIX && id != LR_ID_FM1_JTAG)) {
		fprintf(stderr, "unexpected LR ID 0x%08X (want 0x%08X or 0x%08X)\n",
			(unsigned)id, LR_ID_FM1, LR_ID_FM1_FIX);
		lr_link_close();
		return 1;
	}
	printf("LR design ID 0x%08X\n", (unsigned)id);
	if (o.status_only) {
		lr_dump_lr();
		lr_link_close();
		return 0;
	}

	lr_apply_overrides(&o);
	printf("== ad9361_init (LO %" PRIu64 " Hz, RX1A, 1R1T, LVDS) ==\n", o.lo_hz);
	ret = ad9361_init(&phy, &default_init_param);
	if (ret < 0 || !phy) {
		fprintf(stderr, "ad9361_init failed (%d)\n", (int)ret);
		goto fail;
	}

	printf("== switch to %u sps and re-tune the LVDS interface ==\n", LR_SAMPLE_HZ);
	ret = ad9361_set_rx_sampling_freq(phy, LR_SAMPLE_HZ);
	if (ret < 0) { fprintf(stderr, "set_rx_sampling_freq failed (%d)\n", (int)ret); goto fail; }
	ret = ad9361_set_tx_sampling_freq(phy, LR_SAMPLE_HZ);
	if (ret < 0) { fprintf(stderr, "set_tx_sampling_freq failed (%d)\n", (int)ret); goto fail; }
	ret = ad9361_dig_tune(phy, LR_SAMPLE_HZ, BE_VERBOSE);
	if (ret < 0) { fprintf(stderr, "RX digital interface tune failed (%d)\n", (int)ret); goto fail; }
	/* ad9361_dig_tune() restores REG_BIST_CONFIG from phy->bist_config, but
	 * the tune it ran inside ad9361_init() left that cached copy at "PRBS on"
	 * (ad9361_bist_prbs updates the cache, the restore write does not).  A
	 * second tune therefore re-enables the RX PRBS: the AD9361 then streams
	 * the test pattern instead of antenna data.  Disable it explicitly. */
	ad9361_bist_prbs(phy, BIST_DISABLE);

	ad9361_set_rx_rf_bandwidth(phy, o.bw_hz);
	ad9361_set_tx_attenuation(phy, 0, 89750);
	ad9361_set_rx_gain_control_mode(phy, 0, (uint8_t)o.gain_mode);
	if (o.gain_mode == RF_GAIN_MGC)
		ad9361_set_rx_rf_gain(phy, 0, o.gain_db);

	if (o.bist_tone) {
		/* Digital test tone injected at the RX output: exercises the LVDS
		 * path and the FPGA FM chain without any antenna signal. */
		ret = ad9361_bist_tone(phy, BIST_INJ_RX, 3840000, 0, 0x0E);
		printf("BIST tone (RX inject, 3.84 MHz) -> %d\n", (int)ret);
	}

	ad9361_get_rx_sampling_freq(phy, &fs);
	ad9361_get_rx_lo_freq(phy, &lo);
	ad9361_get_rx_rf_bandwidth(phy, &bw);
	ad9361_get_rx_rf_gain(phy, 0, &gain);
	printf("AD9361: fs %u sps, RX LO %" PRIu64 " Hz, RF BW %u Hz, gain %d dB\n",
	       (unsigned)fs, lo, (unsigned)bw, (int)gain);

	/* ID 0x4C520002: its dc_correction has an integer-only DC estimator that
	 * drifts to a large negative value and injects a big DC term at the LO,
	 * so bypass it (CONTROL[0]); the AD9361 runs its own RF/BB DC tracking.
	 * ID 0x4C520003 carries the fixed estimator: keep it enabled. */
	{
		uint32_t ctrl = 0, acfg = 0;
		lr_reg_read(LR_REG(0x008), &ctrl);
		ctrl = (id == LR_ID_FM1) ? (ctrl | 1u) : (ctrl & ~1u);
		lr_reg_write(LR_REG(0x008), ctrl & ~4u);
		if (id != LR_ID_FM1) {
			lr_reg_read(LR_REG(0x038), &acfg);
			acfg = (o.deemph_us == 75) ? (acfg | (1u << 18)) : (acfg & ~(1u << 18));
			lr_reg_write(LR_REG(0x038), acfg);
		}
		printf("FPGA: DC correction %s, de-emphasis %s\n",
		       (ctrl & 1u) ? "bypassed (old bitstream)" : "enabled",
		       (id == LR_ID_FM1) ? "75 us fixed (old bitstream)"
		                         : (o.deemph_us == 75 ? "75 us" : "50 us"));
	}

	/* Publish the LO for the GUI and tune the FPGA DDC to the station. */
	ddc = (int32_t)((int64_t)o.tune_hz - (int64_t)lo);
	lr_reg_write(LR_REG(0x010), (uint32_t)lo);
	lr_reg_write(LR_REG(0x024), (uint32_t)ddc);
	printf("FPGA: RF_FREQ=%" PRIu64 ", DDC_FREQ=%d Hz -> listening at %" PRIu64 " Hz\n",
	       lo, (int)ddc, o.tune_hz);

	no_os_mdelay(200);
	lr_dump_lr();
	printf("SPI transactions %lu, AXI accesses %lu\n", lr_spi_count, lr_axi_count);
	printf("AD9361_BRINGUP_OK\n");
	lr_link_close();
	return 0;

fail:
	lr_dump_lr();
	printf("SPI transactions %lu, AXI accesses %lu\n", lr_spi_count, lr_axi_count);
	lr_link_close();
	return 1;
}
