// ============================================================================
// Lightning Receiver - Global Definitions
// File: lr_defines.vh
// ----------------------------------------------------------------------------
// Frozen by LR FPGA Full Design Specification Rev 0.1
// Stream fabric widths, flow IDs, register offsets, AD9361 parameters.
// ============================================================================
`ifndef LR_DEFINES_VH
`define LR_DEFINES_VH

// Stream fabric (AXI4-Stream compatible)
//   TDATA = { i_data[15:0], q_data[15:0] }
//   TUSER = { sample_index[7:0], channel_id[1:0], flags[5:0] }
//   side channel: timestamp[63:0] latched at frame head
`define LR_TDATA_W       32
`define LR_TUSER_W       16
`define LR_TIMESTAMP_W   64

// TUSER field positions
`define LR_TUSER_SIDX_MSB 15
`define LR_TUSER_SIDX_LSB 8
`define LR_TUSER_CH_MSB   7
`define LR_TUSER_CH_LSB   6
`define LR_TUSER_FLG_MSB  5
`define LR_TUSER_FLG_LSB  0

// Channel IDs
`define LR_CH_RX1          2'd0
`define LR_CH_RX2          2'd1

// Flow IDs (Master Spec Sec 11)
`define LR_FLOW_RAW_IQ_CH0  3'd0
`define LR_FLOW_RAW_IQ_CH1  3'd1
`define LR_FLOW_SPECTRUM    3'd2
`define LR_FLOW_AUDIO_PCM   3'd3
`define LR_FLOW_DETECT      3'd4
`define LR_FLOW_TELEMETRY   3'd5

// Register offsets (AXI-Lite)
`define LR_REG_ID            12'h000
`define LR_REG_STATUS        12'h004
`define LR_REG_CONTROL       12'h008
`define LR_REG_MODE          12'h00C
`define LR_REG_RF_FREQ       12'h010
`define LR_REG_RF_GAIN       12'h014
`define LR_REG_RF_BW_RATE    12'h018
`define LR_REG_RF_STATUS     12'h01C
`define LR_REG_STREAM_EN     12'h020
`define LR_REG_DDC_FREQ      12'h024
`define LR_REG_DECIM         12'h028
`define LR_REG_FFT_CFG       12'h02C
`define LR_REG_SPEC_CFG      12'h030
`define LR_REG_DET_CFG       12'h034
`define LR_REG_AUDIO_CFG     12'h038
`define LR_REG_DDR_MODE      12'h03C
`define LR_REG_DDR_STATUS    12'h040
`define LR_REG_NET_STATUS    12'h044
`define LR_REG_ERR_STATUS    12'h048
`define LR_REG_UPTIME        12'h04C
`define LR_REG_SPI_TX        12'h050  // raw 24-bit AD9361 SPI transaction
`define LR_REG_SPI_RX        12'h054
`define LR_REG_SPI_STATUS    12'h058  // bit0 busy, bit1 done pulse
`define LR_REG_SPI_CONTROL   12'h05C  // write bit0=1 to start
`define LR_REG_DET_EVENT_LO  12'h060
`define LR_REG_DET_EVENT_HI  12'h064
// Phase-1 FM radio (JTAG/DDR audio path; replaces the former CMAC_STATUS)
`define LR_REG_AUDIO_STATUS     12'h068  // [0]ring fifo full [1]axi err [2]rec active
                                         // [7:4]net drops [15:8]pack drops [31:16]ring ovf
`define LR_REG_AUDIO_WR_WORDS   12'h06C  // total 32-byte DDR words written (wraps 2^32)
`define LR_REG_AUDIO_RING_BASE  12'h070  // byte address of audio ring in jtag_axi space
`define LR_REG_AUDIO_RING_WORDS 12'h074  // ring length in 32-byte words
`define LR_REG_AUDIO_REC_START  12'h078  // AUDIO_WR_WORDS value at the last REC start
`define LR_REG_UI_STATUS        12'h07C  // [3:0]keys [7:4]last action [15:8]action count
                                         // [19:16]LEDs [20]panel lock [21]FM mode [22]ADC active
`define LR_REG_SEEK_CTRL        12'h080  // W: 1 seek up, 2 seek down, 3 cancel
                                         // R: [0]busy [1]dir up [3:2]result [4]limit
                                         //    [5]no signal (meter timeout)
`define LR_REG_SEEK_CFG         12'h084  // [15:0]step kHz (100) [31:16]range +/- kHz (10000)
`define LR_REG_SIG_POWER        12'h088  // channel mean power |x|^2 (last meter block)
`define LR_REG_SIG_QUALITY      12'h08C  // [15:0]flatness Q8.8 [16]station [31:24]block count
`define LR_REG_SEEK_THR         12'h090  // [15:0]flatness thr Q8.8 (0x140) [31:16]min power hi
`define LR_REG_ID_VALUE         32'h4C52_0004  // 0003: bring-up fixes, 0004: + open JTAG bridge (USER4)

// CONTROL bits
`define LR_CTRL_DC_BYPASS    0
`define LR_CTRL_PANEL_LOCK   1   // host locks the front-panel keys
`define LR_CTRL_ERR_CLEAR    2   // write 1: clear sticky telemetry errors (self-clearing)
// AUDIO_CFG bits ([15:0] = audio gain Q0.15)
`define LR_AUDIO_CFG_REC     16  // DDR audio recording (default 0)
`define LR_AUDIO_CFG_NET     17  // network audio transmission (default 1)
`define LR_AUDIO_CFG_DEEM75  18  // de-emphasis: 0 = 50 us (China/EU, default), 1 = 75 us
// FFT_CFG bits: [1:0] window select, [15:8] spectrum frame decimation N
// (process 1 of N FFT frames; N < 2 selects the default 4)
// SEEK_CTRL result codes
`define LR_SEEK_NONE         2'd0
`define LR_SEEK_FOUND        2'd1
`define LR_SEEK_NOTFOUND     2'd2
`define LR_SEEK_CANCELLED    2'd3

// Mode IDs
`define LR_MODE_FM           2'd0
`define LR_MODE_GENERAL_SDR  2'd1

// AD9361 parameters (frozen baseline)
`define LR_AD9361_SAMPLE_RATE 61_440_000
`define LR_AD9361_REFCLK      40_000_000

// DSP chain
`define LR_FM_CHAN_RATE       192_000
`define LR_AUDIO_RATE         48_000

`endif // LR_DEFINES_VH
