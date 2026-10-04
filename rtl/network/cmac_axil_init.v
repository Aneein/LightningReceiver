// ============================================================================
// Lightning Receiver - autonomous CMAC/RS-FEC bring-up
// ----------------------------------------------------------------------------
// Replays the board-proven F_SMART CMAC restore sequence after every FPGA
// configuration.  The original reference design required a Vivado JTAG Tcl
// script after each program operation; without these writes RX and TX remain
// disabled and the 100G link can never come up.
// ============================================================================
`timescale 1ns/1ps

module cmac_axil_init #(
    parameter integer CLK_HZ = 225_000_000,
    parameter [31:0] CMAC_BASE = 32'h44A1_0000
)(
    input  wire        M_AXI_aclk,
    input  wire        M_AXI_aresetn,

    output reg  [31:0] M_AXI_awaddr,
    output wire [2:0]  M_AXI_awprot,
    output reg         M_AXI_awvalid,
    input  wire        M_AXI_awready,
    output reg  [31:0] M_AXI_wdata,
    output wire [3:0]  M_AXI_wstrb,
    output reg         M_AXI_wvalid,
    input  wire        M_AXI_wready,
    input  wire [1:0]  M_AXI_bresp,
    input  wire        M_AXI_bvalid,
    output reg         M_AXI_bready,

    output wire [31:0] M_AXI_araddr,
    output wire [2:0]  M_AXI_arprot,
    output wire        M_AXI_arvalid,
    input  wire        M_AXI_arready,
    input  wire [31:0] M_AXI_rdata,
    input  wire [1:0]  M_AXI_rresp,
    input  wire        M_AXI_rvalid,
    output wire        M_AXI_rready,

    output reg         init_done,
    output reg         init_error,
    output reg  [3:0]  init_step
);

    localparam integer BOOT_CYCLES   = CLK_HZ / 100; // 10 ms
    localparam integer RESET_CYCLES  = CLK_HZ / 5;   // 200 ms
    localparam integer SETTLE_CYCLES = CLK_HZ / 2;   // 500 ms
    localparam integer RFI_CYCLES    = CLK_HZ + (CLK_HZ / 2); // 1.5 s

    localparam [4:0]
        ST_BOOT       = 5'd0,
        ST_FEC_MODE   = 5'd1,
        ST_FEC_EN     = 5'd2,
        ST_RESET_ON   = 5'd3,
        ST_RESET_WAIT = 5'd4,
        ST_RESET_OFF  = 5'd5,
        ST_SETTLE     = 5'd6,
        ST_RX_ON      = 5'd7,
        ST_TX_RFI     = 5'd8,
        ST_RFI_WAIT   = 5'd9,
        ST_TX_NORMAL  = 5'd10,
        ST_DONE       = 5'd11;

    reg [4:0]  state;
    reg [31:0] delay_count;
    reg        aw_done;
    reg        w_done;

    assign M_AXI_awprot = 3'b000;
    assign M_AXI_wstrb  = 4'b1111;
    assign M_AXI_araddr = 32'd0;
    assign M_AXI_arprot = 3'b000;
    assign M_AXI_arvalid = 1'b0;
    assign M_AXI_rready  = 1'b0;

    function is_write_state;
        input [4:0] s;
        begin
            case (s)
                ST_FEC_MODE, ST_FEC_EN, ST_RESET_ON, ST_RESET_OFF,
                ST_RX_ON, ST_TX_RFI, ST_TX_NORMAL: is_write_state = 1'b1;
                default: is_write_state = 1'b0;
            endcase
        end
    endfunction

    task load_write;
        input [4:0] s;
        begin
            case (s)
                ST_FEC_MODE:  begin M_AXI_awaddr <= CMAC_BASE + 32'h1000; M_AXI_wdata <= 32'h0000_0007; end
                ST_FEC_EN:    begin M_AXI_awaddr <= CMAC_BASE + 32'h107C; M_AXI_wdata <= 32'h0000_0003; end
                ST_RESET_ON:  begin M_AXI_awaddr <= CMAC_BASE + 32'h0004; M_AXI_wdata <= 32'hC000_0000; end
                ST_RESET_OFF: begin M_AXI_awaddr <= CMAC_BASE + 32'h0004; M_AXI_wdata <= 32'h0000_0000; end
                ST_RX_ON:     begin M_AXI_awaddr <= CMAC_BASE + 32'h0014; M_AXI_wdata <= 32'h0000_0001; end
                ST_TX_RFI:    begin M_AXI_awaddr <= CMAC_BASE + 32'h000C; M_AXI_wdata <= 32'h0000_0010; end
                default:      begin M_AXI_awaddr <= CMAC_BASE + 32'h000C; M_AXI_wdata <= 32'h0000_0001; end
            endcase
        end
    endtask

    task advance_after_write;
        input [4:0] s;
        begin
            case (s)
                ST_FEC_MODE:  state <= ST_FEC_EN;
                ST_FEC_EN:    state <= ST_RESET_ON;
                ST_RESET_ON:  begin state <= ST_RESET_WAIT; delay_count <= RESET_CYCLES - 1; end
                ST_RESET_OFF: begin state <= ST_SETTLE; delay_count <= SETTLE_CYCLES - 1; end
                ST_RX_ON:     state <= ST_TX_RFI;
                ST_TX_RFI:    begin state <= ST_RFI_WAIT; delay_count <= RFI_CYCLES - 1; end
                default:      state <= ST_DONE;
            endcase
        end
    endtask

    always @(posedge M_AXI_aclk or negedge M_AXI_aresetn) begin
        if (!M_AXI_aresetn) begin
            state         <= ST_BOOT;
            delay_count   <= BOOT_CYCLES - 1;
            M_AXI_awaddr  <= 32'd0;
            M_AXI_awvalid <= 1'b0;
            M_AXI_wdata   <= 32'd0;
            M_AXI_wvalid  <= 1'b0;
            M_AXI_bready  <= 1'b0;
            aw_done       <= 1'b0;
            w_done        <= 1'b0;
            init_done     <= 1'b0;
            init_error    <= 1'b0;
            init_step     <= 4'd0;
        end else begin
            init_step <= state[3:0];

            if (state == ST_BOOT || state == ST_RESET_WAIT ||
                state == ST_SETTLE || state == ST_RFI_WAIT) begin
                if (delay_count != 0) begin
                    delay_count <= delay_count - 1'b1;
                end else begin
                    case (state)
                        ST_BOOT:       state <= ST_FEC_MODE;
                        ST_RESET_WAIT: state <= ST_RESET_OFF;
                        ST_SETTLE:     state <= ST_RX_ON;
                        default:       state <= ST_TX_NORMAL;
                    endcase
                end
            end

            if (is_write_state(state)) begin
                if (!M_AXI_awvalid && !aw_done) begin
                    load_write(state);
                    M_AXI_awvalid <= 1'b1;
                end
                if (!M_AXI_wvalid && !w_done) begin
                    load_write(state);
                    M_AXI_wvalid <= 1'b1;
                end
                if (M_AXI_awvalid && M_AXI_awready) begin
                    M_AXI_awvalid <= 1'b0;
                    aw_done <= 1'b1;
                end
                if (M_AXI_wvalid && M_AXI_wready) begin
                    M_AXI_wvalid <= 1'b0;
                    w_done <= 1'b1;
                end
                if (aw_done && w_done && !M_AXI_bready)
                    M_AXI_bready <= 1'b1;
                if (M_AXI_bready && M_AXI_bvalid) begin
                    M_AXI_bready <= 1'b0;
                    aw_done <= 1'b0;
                    w_done <= 1'b0;
                    if (M_AXI_bresp != 2'b00)
                        init_error <= 1'b1;
                    advance_after_write(state);
                end
            end

            if (state == ST_DONE) begin
                init_done <= 1'b1;
                M_AXI_awvalid <= 1'b0;
                M_AXI_wvalid <= 1'b0;
                M_AXI_bready <= 1'b0;
            end
        end
    end

endmodule
