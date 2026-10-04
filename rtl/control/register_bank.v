// ============================================================================
// Lightning Receiver - AXI-Lite Register Bank
// File: register_bank.v
// ----------------------------------------------------------------------------
// Central control/status register file (map in lr_defines.vh). AXI4-Lite
// slave plus a secondary config port for the UART command parser.
//
// Internal writers (front panel / seek controller) modify registers through
// dedicated ports so the register file stays the single source of truth and
// the host GUI simply reads back the result:
//   ui_rec_toggle / ui_net_toggle : toggle AUDIO_CFG.REC / AUDIO_CFG.NET
//   int_ddc_valid / int_ddc_data  : set DDC_FREQ (seek / manual tuning)
// If a bus (AXI or UART) write happens in the same cycle, internal requests
// are held one cycle and applied on top of the new value.  A bus write to
// DDC_FREQ discards any pending internal tuning: the host always wins, and
// ddc_bus_wr tells the seek controller to stop.
// ============================================================================
`timescale 1ns/1ps
`include "lr_defines.vh"

module register_bank (
    input  wire         s_axi_aclk,
    input  wire         s_axi_aresetn,
    // AXI4-Lite slave
    input  wire [11:0]  s_axi_awaddr,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [11:0]  s_axi_araddr,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,
    // RW register outputs
    output reg  [31:0]  reg_control,
    output reg  [1:0]   reg_mode,
    output reg  [31:0]  reg_rf_freq,
    output reg  [31:0]  reg_rf_gain,
    output reg  [31:0]  reg_rf_bw_rate,
    (* X_INTERFACE_IGNORE = "true" *) output reg [5:0] reg_stream_en,
    output reg  [31:0]  reg_ddc_freq,
    output reg  [15:0]  reg_decim,
    output reg  [31:0]  reg_fft_cfg,
    output reg  [31:0]  reg_spec_cfg,
    output reg  [31:0]  reg_det_cfg,
    output reg  [31:0]  reg_audio_cfg,
    output reg  [31:0]  reg_ddr_mode,
    output reg  [31:0]  reg_seek_cfg,
    output reg  [31:0]  reg_seek_thr,
    (* X_INTERFACE_IGNORE = "true" *) output reg seek_cmd_valid,
    (* X_INTERFACE_IGNORE = "true" *) output reg [1:0] seek_cmd,
    (* X_INTERFACE_IGNORE = "true" *) output reg ddc_bus_wr,
    (* X_INTERFACE_IGNORE = "true" *) output reg err_clear,
    // internal writers (front panel / seek)
    (* X_INTERFACE_IGNORE = "true" *) input wire ui_rec_toggle,
    (* X_INTERFACE_IGNORE = "true" *) input wire ui_net_toggle,
    (* X_INTERFACE_IGNORE = "true" *) input wire int_ddc_valid,
    (* X_INTERFACE_IGNORE = "true" *) input wire [31:0] int_ddc_data,
    (* X_INTERFACE_IGNORE = "true" *) output reg [23:0] spi_tx_data,
    (* X_INTERFACE_IGNORE = "true" *) output reg spi_start,
    (* X_INTERFACE_IGNORE = "true" *) input wire [23:0] spi_rx_data,
    (* X_INTERFACE_IGNORE = "true" *) input wire spi_busy,
    (* X_INTERFACE_IGNORE = "true" *) input wire spi_done,
    // RO inputs
    input  wire [31:0]  status_in,
    input  wire [31:0]  rf_status_in,
    input  wire [31:0]  ddr_status_in,
    input  wire [31:0]  net_status_in,
    input  wire [31:0]  err_status_in,
    input  wire [31:0]  uptime_in,
    input  wire [63:0]  det_event_in,
    input  wire [31:0]  audio_status_in,
    input  wire [31:0]  audio_wr_words_in,
    input  wire [31:0]  audio_ring_base_in,
    input  wire [31:0]  audio_ring_words_in,
    input  wire [31:0]  audio_rec_start_in,
    input  wire [31:0]  ui_status_in,
    input  wire [31:0]  seek_status_in,
    input  wire [31:0]  sig_power_in,
    input  wire [31:0]  sig_quality_in,
    input  wire [31:0]  tele_rdata,
    output wire [5:0]   tele_addr,
    output reg          wr_strobe,
    // secondary config port (UART command parser, same clock domain)
    (* X_INTERFACE_IGNORE = "true" *) input wire cfg_wr_valid,
    (* X_INTERFACE_IGNORE = "true" *) input wire [11:0] cfg_wr_addr,
    (* X_INTERFACE_IGNORE = "true" *) input wire [31:0] cfg_wr_data,
    (* X_INTERFACE_IGNORE = "true" *) input wire cfg_rd_valid,
    (* X_INTERFACE_IGNORE = "true" *) input wire [11:0] cfg_rd_addr,
    (* X_INTERFACE_IGNORE = "true" *) output reg [31:0] cfg_rd_data
);

    reg aw_pending, w_pending, bvalid_q, ar_pending;
    reg [11:0] aw_addr, ar_addr;
    reg [31:0] w_data;

    // AXI-Lite AW and W are independent channels and may arrive in either
    // order.  Hold each until the pair is complete, then issue one response.
    assign s_axi_awready = !aw_pending && !bvalid_q;
    assign s_axi_wready  = !w_pending  && !bvalid_q;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_arready = !ar_pending;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = ar_pending;
    assign tele_addr     = ar_pending ? ar_addr[7:2] : 6'd0;

    // Bus write detection for internal-writer arbitration.
    wire axi_wr_fire = !bvalid_q &&
                       (aw_pending || (s_axi_awready && s_axi_awvalid)) &&
                       (w_pending  || (s_axi_wready  && s_axi_wvalid));
    wire [11:0] axi_wr_addr = aw_pending ? aw_addr : s_axi_awaddr;
    wire bus_wr_now  = axi_wr_fire || cfg_wr_valid;
    wire bus_ddc_hit = (axi_wr_fire && ({axi_wr_addr[11:2], 2'b00} == `LR_REG_DDC_FREQ)) ||
                       (cfg_wr_valid && ({cfg_wr_addr[11:2], 2'b00} == `LR_REG_DDC_FREQ));
    reg        pend_rec, pend_net, pend_ddc_v;
    reg [31:0] pend_ddc_d;

    // ------------------------------------------------------------------------
    // Write decode (shared by AXI-Lite and cfg port)
    // ------------------------------------------------------------------------
    task write_reg;
        input [11:0] a;
        input [31:0] d;
        begin
            // Register constants are byte offsets.  Decode an aligned byte
            // address; comparing a[11:2] directly against 12'h008-style
            // constants makes every non-zero register miss.
            case ({a[11:2], 2'b00})
                `LR_REG_CONTROL: begin
                    // ERR_CLEAR is a self-clearing command bit.
                    reg_control <= d & ~(32'd1 << `LR_CTRL_ERR_CLEAR);
                    err_clear   <= d[`LR_CTRL_ERR_CLEAR];
                end
                `LR_REG_MODE:       reg_mode      <= d[1:0];
                `LR_REG_RF_FREQ:    reg_rf_freq   <= d;
                `LR_REG_RF_GAIN:    reg_rf_gain   <= d;
                `LR_REG_RF_BW_RATE: reg_rf_bw_rate <= d;
                `LR_REG_STREAM_EN:  reg_stream_en <= d[5:0];
                `LR_REG_DDC_FREQ:   reg_ddc_freq  <= d;
                `LR_REG_DECIM:      reg_decim     <= d[15:0];
                `LR_REG_FFT_CFG:    reg_fft_cfg   <= d;
                `LR_REG_SPEC_CFG:   reg_spec_cfg  <= d;
                `LR_REG_DET_CFG:    reg_det_cfg   <= d;
                `LR_REG_AUDIO_CFG:  reg_audio_cfg <= d;
                `LR_REG_DDR_MODE:   reg_ddr_mode  <= d;
                `LR_REG_SEEK_CFG:   reg_seek_cfg  <= d;
                `LR_REG_SEEK_THR:   reg_seek_thr  <= d;
                `LR_REG_SEEK_CTRL: begin
                    seek_cmd_valid <= (d[1:0] != 2'd0);
                    seek_cmd       <= d[1:0];
                end
                `LR_REG_SPI_TX:     spi_tx_data   <= d[23:0];
                `LR_REG_SPI_CONTROL: spi_start    <= d[0];
                default: ;
            endcase
        end
    endtask

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            aw_addr <= 12'd0; aw_pending <= 1'b0;
            w_data <= 32'd0; w_pending <= 1'b0; bvalid_q <= 1'b0;
            wr_strobe <= 1'b0;
            reg_control <= 32'd0; reg_mode <= 2'd0;
            reg_rf_freq <= 32'd98_000_000; reg_rf_gain <= 32'd0;
            reg_rf_bw_rate <= 32'd0;
            // telemetry/detect/audio/spectrum/raw enabled by default
            reg_stream_en <= 6'b111_101;
            reg_ddc_freq <= 32'd0; reg_decim <= 16'd320;
            reg_fft_cfg <= 32'd0; reg_spec_cfg <= 32'd0;
            // gain unity, REC off, NET on
            reg_det_cfg <= 32'd0; reg_audio_cfg <= 32'h0002_7FFF;
            // bit0: raw-IQ recorder.  Off by default in the FM-radio build so
            // DDR bandwidth is reserved for the audio ring; host may enable it.
            reg_ddr_mode <= 32'd0;
            reg_seek_cfg <= {16'd10000, 16'd100};   // +/-10 MHz, 100 kHz grid
            reg_seek_thr <= {16'd0, 16'h0140};      // flatness 1.25 (~8 dB CNR)
            seek_cmd_valid <= 1'b0; seek_cmd <= 2'd0;
            ddc_bus_wr <= 1'b0; err_clear <= 1'b0;
            pend_rec <= 1'b0; pend_net <= 1'b0;
            pend_ddc_v <= 1'b0; pend_ddc_d <= 32'd0;
            spi_tx_data <= 24'd0; spi_start <= 1'b0;
        end else begin
            wr_strobe <= 1'b0;
            spi_start <= 1'b0;
            seek_cmd_valid <= 1'b0;
            err_clear <= 1'b0;
            ddc_bus_wr <= bus_ddc_hit;
            if (s_axi_awready && s_axi_awvalid) begin
                aw_addr <= s_axi_awaddr;
                aw_pending <= 1'b1;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_data <= s_axi_wdata;
                w_pending <= 1'b1;
            end

            if (!bvalid_q &&
                (aw_pending || (s_axi_awready && s_axi_awvalid)) &&
                (w_pending  || (s_axi_wready  && s_axi_wvalid))) begin
                if (aw_pending)
                    write_reg(aw_addr, w_pending ? w_data : s_axi_wdata);
                else
                    write_reg(s_axi_awaddr, w_pending ? w_data : s_axi_wdata);
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                bvalid_q <= 1'b1;
                wr_strobe <= 1'b1;
            end
            if (bvalid_q && s_axi_bready)
                bvalid_q <= 1'b0;

            if (cfg_wr_valid) begin
                write_reg(cfg_wr_addr, cfg_wr_data);
                wr_strobe <= 1'b1;
            end

            // Internal writers: deferred while a bus write lands this cycle.
            if (bus_wr_now) begin
                pend_rec <= pend_rec ^ ui_rec_toggle;
                pend_net <= pend_net ^ ui_net_toggle;
                if (bus_ddc_hit) begin
                    pend_ddc_v <= 1'b0;            // host value wins
                end else if (int_ddc_valid) begin
                    pend_ddc_v <= 1'b1;
                    pend_ddc_d <= int_ddc_data;
                end
            end else begin
                if (pend_rec ^ ui_rec_toggle)
                    reg_audio_cfg[`LR_AUDIO_CFG_REC] <= ~reg_audio_cfg[`LR_AUDIO_CFG_REC];
                if (pend_net ^ ui_net_toggle)
                    reg_audio_cfg[`LR_AUDIO_CFG_NET] <= ~reg_audio_cfg[`LR_AUDIO_CFG_NET];
                if (int_ddc_valid)
                    reg_ddc_freq <= int_ddc_data;
                else if (pend_ddc_v)
                    reg_ddc_freq <= pend_ddc_d;
                pend_rec <= 1'b0;
                pend_net <= 1'b0;
                pend_ddc_v <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Read channel
    // ------------------------------------------------------------------------
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            ar_addr <= 12'd0; ar_pending <= 1'b0;
        end else begin
            if (!ar_pending && s_axi_arvalid) begin
                ar_addr <= s_axi_araddr;
                ar_pending <= 1'b1;
            end else if (ar_pending && s_axi_rready) begin
                ar_pending <= 1'b0;
            end
        end
    end

    reg [31:0] rdata_mux;
    always @(*) begin
        case ({ar_addr[11:2], 2'b00})
            `LR_REG_ID:          rdata_mux = `LR_REG_ID_VALUE;
            `LR_REG_STATUS:      rdata_mux = status_in;
            `LR_REG_CONTROL:     rdata_mux = reg_control;
            `LR_REG_MODE:        rdata_mux = {30'd0, reg_mode};
            `LR_REG_RF_FREQ:     rdata_mux = reg_rf_freq;
            `LR_REG_RF_GAIN:     rdata_mux = reg_rf_gain;
            `LR_REG_RF_BW_RATE:  rdata_mux = reg_rf_bw_rate;
            `LR_REG_RF_STATUS:   rdata_mux = rf_status_in;
            `LR_REG_STREAM_EN:   rdata_mux = {26'd0, reg_stream_en};
            `LR_REG_DDC_FREQ:    rdata_mux = reg_ddc_freq;
            `LR_REG_DECIM:       rdata_mux = {16'd0, reg_decim};
            `LR_REG_FFT_CFG:     rdata_mux = reg_fft_cfg;
            `LR_REG_SPEC_CFG:    rdata_mux = reg_spec_cfg;
            `LR_REG_DET_CFG:     rdata_mux = reg_det_cfg;
            `LR_REG_AUDIO_CFG:   rdata_mux = reg_audio_cfg;
            `LR_REG_DDR_MODE:    rdata_mux = reg_ddr_mode;
            `LR_REG_DDR_STATUS:  rdata_mux = ddr_status_in;
            `LR_REG_NET_STATUS:  rdata_mux = net_status_in;
            `LR_REG_ERR_STATUS:  rdata_mux = err_status_in;
            `LR_REG_UPTIME:      rdata_mux = uptime_in;
            `LR_REG_SPI_TX:      rdata_mux = {8'd0, spi_tx_data};
            `LR_REG_SPI_RX:      rdata_mux = {8'd0, spi_rx_data};
            `LR_REG_SPI_STATUS:  rdata_mux = {30'd0, spi_done, spi_busy};
            `LR_REG_SPI_CONTROL: rdata_mux = 32'd0;
            `LR_REG_DET_EVENT_LO: rdata_mux = det_event_in[31:0];
            `LR_REG_DET_EVENT_HI: rdata_mux = det_event_in[63:32];
            `LR_REG_AUDIO_STATUS:     rdata_mux = audio_status_in;
            `LR_REG_AUDIO_WR_WORDS:   rdata_mux = audio_wr_words_in;
            `LR_REG_AUDIO_RING_BASE:  rdata_mux = audio_ring_base_in;
            `LR_REG_AUDIO_RING_WORDS: rdata_mux = audio_ring_words_in;
            `LR_REG_AUDIO_REC_START:  rdata_mux = audio_rec_start_in;
            `LR_REG_UI_STATUS:        rdata_mux = ui_status_in;
            `LR_REG_SEEK_CTRL:        rdata_mux = seek_status_in;
            `LR_REG_SEEK_CFG:         rdata_mux = reg_seek_cfg;
            `LR_REG_SIG_POWER:        rdata_mux = sig_power_in;
            `LR_REG_SIG_QUALITY:      rdata_mux = sig_quality_in;
            `LR_REG_SEEK_THR:         rdata_mux = reg_seek_thr;
            default:             rdata_mux = tele_rdata;
        endcase
    end

    assign s_axi_rdata = rdata_mux;

    // secondary config read (1-cycle after valid)
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            cfg_rd_data <= 32'd0;
        end else if (cfg_rd_valid) begin
            case ({cfg_rd_addr[11:2], 2'b00})
                `LR_REG_ID:         cfg_rd_data <= `LR_REG_ID_VALUE;
                `LR_REG_STATUS:     cfg_rd_data <= status_in;
                `LR_REG_MODE:       cfg_rd_data <= {30'd0, reg_mode};
                `LR_REG_RF_FREQ:    cfg_rd_data <= reg_rf_freq;
                `LR_REG_RF_GAIN:    cfg_rd_data <= reg_rf_gain;
                `LR_REG_STREAM_EN:  cfg_rd_data <= {26'd0, reg_stream_en};
                `LR_REG_RF_STATUS:  cfg_rd_data <= rf_status_in;
                `LR_REG_DDR_STATUS: cfg_rd_data <= ddr_status_in;
                `LR_REG_NET_STATUS: cfg_rd_data <= net_status_in;
                `LR_REG_ERR_STATUS: cfg_rd_data <= err_status_in;
                `LR_REG_UPTIME:     cfg_rd_data <= uptime_in;
                `LR_REG_SPI_TX:     cfg_rd_data <= {8'd0, spi_tx_data};
                `LR_REG_SPI_RX:     cfg_rd_data <= {8'd0, spi_rx_data};
                `LR_REG_SPI_STATUS: cfg_rd_data <= {30'd0, spi_done, spi_busy};
                `LR_REG_DET_EVENT_LO: cfg_rd_data <= det_event_in[31:0];
                `LR_REG_DET_EVENT_HI: cfg_rd_data <= det_event_in[63:32];
                `LR_REG_AUDIO_STATUS:   cfg_rd_data <= audio_status_in;
                `LR_REG_AUDIO_WR_WORDS: cfg_rd_data <= audio_wr_words_in;
                `LR_REG_AUDIO_CFG:      cfg_rd_data <= reg_audio_cfg;
                `LR_REG_DDC_FREQ:       cfg_rd_data <= reg_ddc_freq;
                `LR_REG_AUDIO_REC_START: cfg_rd_data <= audio_rec_start_in;
                `LR_REG_UI_STATUS:      cfg_rd_data <= ui_status_in;
                `LR_REG_SEEK_CTRL:      cfg_rd_data <= seek_status_in;
                `LR_REG_SIG_POWER:      cfg_rd_data <= sig_power_in;
                `LR_REG_SIG_QUALITY:    cfg_rd_data <= sig_quality_in;
                default:            cfg_rd_data <= 32'hDEAD_BEEF;
            endcase
        end
    end

endmodule
