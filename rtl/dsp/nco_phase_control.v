// ============================================================================
// Lightning Receiver - NCO phase-increment controller
// File: nco_phase_control.v
// ----------------------------------------------------------------------------
// Converts a signed frequency in hertz to the 32-bit NCO tuning word:
//     PINC = frequency_hz * 2^32 / SAMPLE_HZ
// The NCO in ddc_mixer advances once per input *sample*, so the divisor is
// the AD9361 sample rate, not the fabric clock.  The conversion is iterative
// so a register update cannot create a wide divider on the 225 MHz clock.
// ============================================================================
`timescale 1ns/1ps

module nco_phase_control #(
    parameter integer SAMPLE_HZ = 61_440_000
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [31:0] freq_hz,
    output reg        [31:0] cfg_tdata,
    output reg               cfg_tvalid,
    input  wire              cfg_tready
);

    reg signed [31:0] freq_seen;
    reg [63:0] dividend;
    reg [63:0] quotient;
    reg [32:0] remainder;
    reg        negative;
    reg [6:0]  count;
    reg        busy;

    wire [32:0] remainder_shift = {remainder[31:0], dividend[63]};
    wire qbit = (remainder_shift >= SAMPLE_HZ);
    wire [63:0] quotient_next = {quotient[62:0], qbit};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            freq_seen <= 32'sh7FFF_FFFF;
            dividend <= 64'd0;
            quotient <= 64'd0;
            remainder <= 33'd0;
            negative <= 1'b0;
            count <= 7'd0;
            busy <= 1'b0;
            cfg_tdata <= 32'd0;
            cfg_tvalid <= 1'b0;
        end else begin
            if (cfg_tvalid && cfg_tready)
                cfg_tvalid <= 1'b0;

            if (!busy && !cfg_tvalid && (freq_hz != freq_seen)) begin
                freq_seen <= freq_hz;
                if (freq_hz[31])
                    dividend <= {(-freq_hz), 32'd0};
                else
                    dividend <= {freq_hz, 32'd0};
                quotient <= 64'd0;
                remainder <= 33'd0;
                negative <= freq_hz[31];
                count <= 7'd64;
                busy <= 1'b1;
            end else if (busy) begin
                dividend <= {dividend[62:0], 1'b0};
                quotient <= quotient_next;
                if (qbit)
                    remainder <= remainder_shift - SAMPLE_HZ;
                else
                    remainder <= remainder_shift;

                if (count == 7'd1) begin
                    cfg_tdata <= negative ? -quotient_next[31:0]
                                          : quotient_next[31:0];
                    cfg_tvalid <= 1'b1;
                    count <= 7'd0;
                    busy <= 1'b0;
                end else begin
                    count <= count - 1'b1;
                end
            end
        end
    end

endmodule
