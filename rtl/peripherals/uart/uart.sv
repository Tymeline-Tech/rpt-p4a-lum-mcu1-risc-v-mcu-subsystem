//==============================================================================
// uart.sv - APB UART peripheral for LUM-MCU1
// TX/RX, programmable baud divisor, digital loopback, TX-empty / RX-full IRQs
//==============================================================================
`timescale 1ns/1ps

module uart #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ADDR_WIDTH = 5
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

    output logic                  uart_txd,
    input  logic                  uart_rxd,

    output logic                  irq
);

    // Word-aligned register map
    localparam logic [ADDR_WIDTH-1:0] ADDR_DATA   = 5'h00;
    localparam logic [ADDR_WIDTH-1:0] ADDR_STATUS = 5'h04;
    localparam logic [ADDR_WIDTH-1:0] ADDR_CTRL   = 5'h08;
    localparam logic [ADDR_WIDTH-1:0] ADDR_BAUD   = 5'h0C;
    localparam logic [ADDR_WIDTH-1:0] ADDR_IE     = 5'h10;
    localparam logic [ADDR_WIDTH-1:0] ADDR_IP     = 5'h14;

    localparam int CTRL_TX_EN = 0;
    localparam int CTRL_RX_EN = 1;
    localparam int CTRL_LOOP  = 2;

    localparam int IRQ_TX_EMPTY = 0;
    localparam int IRQ_RX_FULL  = 1;

    logic        apb_fire;
    logic        apb_write;
    logic        apb_read;

    logic [31:0] ctrl_q;
    logic [15:0] baud_div_q;
    logic [1:0]  ie_q;
    logic [1:0]  ip_q;

    logic [7:0]  tx_hold_q;
    logic        tx_hold_valid_q;
    logic        tx_busy;
    logic        tx_done_pulse;

    logic [7:0]  rx_data_q;
    logic        rx_full_q;
    logic        rx_done_pulse;
    logic [7:0]  rx_byte;

    logic        serial_out;
    logic        serial_in;

    assign PREADY    = 1'b1;
    assign PSLVERR   = 1'b0;
    assign apb_fire  = PSEL && PENABLE;
    assign apb_write = apb_fire && PWRITE;
    assign apb_read  = apb_fire && !PWRITE;

    assign serial_in = ctrl_q[CTRL_LOOP] ? serial_out : uart_rxd;
    assign uart_txd  = serial_out;

    //--------------------------------------------------------------------------
    // Register file / hold buffers
    //--------------------------------------------------------------------------
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            ctrl_q         <= 32'h0;
            baud_div_q     <= 16'd16;
            ie_q           <= 2'b0;
            ip_q           <= 2'b0;
            tx_hold_q      <= 8'h00;
            tx_hold_valid_q<= 1'b0;
            rx_data_q      <= 8'h00;
            rx_full_q      <= 1'b0;
        end else begin
            if (apb_write) begin
                unique case (PADDR)
                    ADDR_DATA: begin
                        if (ctrl_q[CTRL_TX_EN] && !tx_hold_valid_q) begin
                            tx_hold_q       <= PWDATA[7:0];
                            tx_hold_valid_q <= 1'b1;
                        end
                    end
                    ADDR_CTRL: ctrl_q     <= PWDATA;
                    ADDR_BAUD: baud_div_q <= (PWDATA[15:0] == 16'd0) ? 16'd1 : PWDATA[15:0];
                    ADDR_IE:   ie_q       <= PWDATA[1:0];
                    ADDR_IP:   ip_q       <= ip_q & ~PWDATA[1:0];
                    default: ;
                endcase
            end

            // TX engine accepts held byte
            if (tx_hold_valid_q && !tx_busy) begin
                tx_hold_valid_q <= 1'b0;
            end

            if (rx_done_pulse) begin
                rx_data_q         <= rx_byte;
                rx_full_q         <= 1'b1;
                ip_q[IRQ_RX_FULL] <= 1'b1;
            end

            if (apb_read && (PADDR == ADDR_DATA)) begin
                rx_full_q <= 1'b0;
            end

            if (tx_done_pulse) begin
                ip_q[IRQ_TX_EMPTY] <= 1'b1;
            end
        end
    end

    logic tx_start;
    assign tx_start = tx_hold_valid_q && !tx_busy && ctrl_q[CTRL_TX_EN];

    logic tx_empty;
    assign tx_empty = !tx_busy && !tx_hold_valid_q;

    //--------------------------------------------------------------------------
    // TX engine
    //--------------------------------------------------------------------------
    typedef enum logic [0:0] {TX_IDLE, TX_BITS} tx_state_e;
    tx_state_e   tx_state;
    logic [15:0] tx_div_cnt;
    logic [3:0]  tx_bit_idx;
    logic [9:0]  tx_shift;

    assign tx_busy = (tx_state != TX_IDLE);

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_state      <= TX_IDLE;
            tx_div_cnt    <= 16'd0;
            tx_bit_idx    <= 4'd0;
            tx_shift      <= 10'h3FF;
            serial_out    <= 1'b1;
            tx_done_pulse <= 1'b0;
        end else begin
            tx_done_pulse <= 1'b0;
            unique case (tx_state)
                TX_IDLE: begin
                    serial_out <= 1'b1;
                    tx_div_cnt <= 16'd0;
                    if (tx_start) begin
                        // frame: {stop, data[7:0], start}
                        tx_shift   <= {1'b1, tx_hold_q, 1'b0};
                        tx_bit_idx <= 4'd0;
                        serial_out <= 1'b0;
                        tx_state   <= TX_BITS;
                    end
                end
                TX_BITS: begin
                    if (tx_div_cnt == (baud_div_q - 16'd1)) begin
                        tx_div_cnt <= 16'd0;
                        if (tx_bit_idx == 4'd9) begin
                            tx_state      <= TX_IDLE;
                            serial_out    <= 1'b1;
                            tx_done_pulse <= 1'b1;
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 4'd1;
                            tx_shift   <= {1'b1, tx_shift[9:1]};
                            serial_out <= tx_shift[1];
                        end
                    end else begin
                        tx_div_cnt <= tx_div_cnt + 16'd1;
                    end
                end
                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // RX engine — sample at mid-bit
    //--------------------------------------------------------------------------
    typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_e;
    rx_state_e   rx_state;
    logic [15:0] rx_div_cnt;
    logic [3:0]  rx_bit_idx;
    logic [7:0]  rx_shift;
    logic        rx_q0, rx_q1;
    logic        rx_falling;

    assign rx_byte    = rx_shift;
    assign rx_falling = rx_q1 & ~rx_q0;

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_q0 <= 1'b1;
            rx_q1 <= 1'b1;
        end else begin
            rx_q0 <= serial_in;
            rx_q1 <= rx_q0;
        end
    end

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rx_state      <= RX_IDLE;
            rx_div_cnt    <= 16'd0;
            rx_bit_idx    <= 4'd0;
            rx_shift      <= 8'h00;
            rx_done_pulse <= 1'b0;
        end else begin
            rx_done_pulse <= 1'b0;

            if (!ctrl_q[CTRL_RX_EN]) begin
                rx_state   <= RX_IDLE;
                rx_div_cnt <= 16'd0;
            end else begin
                unique case (rx_state)
                    RX_IDLE: begin
                        rx_div_cnt <= 16'd0;
                        if (rx_falling) begin
                            rx_state <= RX_START;
                        end
                    end
                    RX_START: begin
                        // Wait half bit to mid-start
                        if (rx_div_cnt == ({1'b0, baud_div_q[15:1]})) begin
                            rx_div_cnt <= 16'd0;
                            if (!rx_q0) begin
                                rx_state   <= RX_DATA;
                                rx_bit_idx <= 4'd0;
                            end else begin
                                rx_state <= RX_IDLE;
                            end
                        end else begin
                            rx_div_cnt <= rx_div_cnt + 16'd1;
                        end
                    end
                    RX_DATA: begin
                        if (rx_div_cnt == (baud_div_q - 16'd1)) begin
                            rx_div_cnt <= 16'd0;
                            rx_shift   <= {rx_q0, rx_shift[7:1]};
                            if (rx_bit_idx == 4'd7) begin
                                rx_state <= RX_STOP;
                            end else begin
                                rx_bit_idx <= rx_bit_idx + 4'd1;
                            end
                        end else begin
                            rx_div_cnt <= rx_div_cnt + 16'd1;
                        end
                    end
                    RX_STOP: begin
                        if (rx_div_cnt == (baud_div_q - 16'd1)) begin
                            rx_div_cnt    <= 16'd0;
                            rx_done_pulse <= 1'b1;
                            rx_state      <= RX_IDLE;
                        end else begin
                            rx_div_cnt <= rx_div_cnt + 16'd1;
                        end
                    end
                    default: rx_state <= RX_IDLE;
                endcase
            end
        end
    end

    //--------------------------------------------------------------------------
    // APB read data / interrupt
    //--------------------------------------------------------------------------
    always_comb begin
        PRDATA = 32'h0;
        if (apb_read) begin
            unique case (PADDR)
                ADDR_DATA:   PRDATA = {24'h0, rx_data_q};
                ADDR_STATUS: PRDATA = {29'h0, tx_busy, rx_full_q, tx_empty};
                ADDR_CTRL:   PRDATA = ctrl_q;
                ADDR_BAUD:   PRDATA = {16'h0, baud_div_q};
                ADDR_IE:     PRDATA = {30'h0, ie_q};
                ADDR_IP:     PRDATA = {30'h0, ip_q};
                default:     PRDATA = 32'h0;
            endcase
        end
    end

    assign irq = |(ip_q & ie_q);

    initial begin
        $dumpfile("uart.vcd");
        $dumpvars(0, uart);
    end

endmodule
