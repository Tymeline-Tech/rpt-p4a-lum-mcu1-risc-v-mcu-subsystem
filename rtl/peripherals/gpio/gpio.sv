//==============================================================================
// gpio.sv - 16-pin APB GPIO peripheral for LUM-MCU1
//==============================================================================
`timescale 1ns/1ps

module gpio #(
    parameter int unsigned ADDR_WIDTH = 4
) (
    input  logic                  PCLK,
    input  logic                  PRESETn,

    input  logic                  PSEL,
    input  logic                  PENABLE,
    input  logic                  PWRITE,
    input  logic [ADDR_WIDTH-1:0] PADDR,
    input  logic [31:0]           PWDATA,
    output logic [31:0]           PRDATA,
    output logic                  PREADY,
    output logic                  PSLVERR,

    // Bidirectional pins modeled as separate in/out + direction
    input  logic [15:0]           gpio_in,
    output logic [15:0]           gpio_out,
    output logic [15:0]           gpio_oe,   // 1 = output enabled
    output logic                  irq
);

    localparam logic [ADDR_WIDTH-1:0] ADDR_DATA = 4'h0; // RW output data
    localparam logic [ADDR_WIDTH-1:0] ADDR_DIR  = 4'h4; // RW direction (1=out)
    localparam logic [ADDR_WIDTH-1:0] ADDR_IN   = 4'h8; // RO sampled inputs
    localparam logic [ADDR_WIDTH-1:0] ADDR_IE   = 4'hC; // RW irq enable (level)

    logic        apb_fire, apb_write, apb_read;
    logic [15:0] data_q, dir_q, ie_q;
    logic [15:0] in_sync_q;

    assign PREADY    = 1'b1;
    assign PSLVERR   = 1'b0;
    assign apb_fire  = PSEL && PENABLE;
    assign apb_write = apb_fire && PWRITE;
    assign apb_read  = apb_fire && !PWRITE;

    assign gpio_out = data_q;
    assign gpio_oe  = dir_q;

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            data_q    <= 16'h0;
            dir_q     <= 16'h0;
            ie_q      <= 16'h0;
            in_sync_q <= 16'h0;
        end else begin
            in_sync_q <= gpio_in;
            if (apb_write) begin
                unique case (PADDR)
                    ADDR_DATA: data_q <= PWDATA[15:0];
                    ADDR_DIR:  dir_q  <= PWDATA[15:0];
                    ADDR_IE:   ie_q   <= PWDATA[15:0];
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        PRDATA = 32'h0;
        if (apb_read) begin
            unique case (PADDR)
                ADDR_DATA: PRDATA = {16'h0, data_q};
                ADDR_DIR:  PRDATA = {16'h0, dir_q};
                ADDR_IN:   PRDATA = {16'h0, in_sync_q};
                ADDR_IE:   PRDATA = {16'h0, ie_q};
                default:   PRDATA = 32'h0;
            endcase
        end
    end

    assign irq = |(in_sync_q & ie_q & ~dir_q);

    initial begin
        $dumpfile("gpio.vcd");
        $dumpvars(0, gpio);
    end

endmodule
