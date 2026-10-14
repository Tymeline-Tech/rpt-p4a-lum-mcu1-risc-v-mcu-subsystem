// -----------------------------------------------------------------------------
// apb_master — APB v2.0 (AMBA 3 APB) master with peripheral address decoder
//
// Translates a simple CPU request/response interface into APB SETUP/ACCESS
// handshakes (PSEL / PENABLE / PREADY / PWRITE) and routes selects to UART,
// GPIO, and Timer slaves. Synthesizable; provides a registered clock-gate
// enable for low-power idle gating.
// -----------------------------------------------------------------------------

module apb_master (
    input  logic        pclk,
    input  logic        preset_n,

    // ---- CPU / fabric request interface ------------------------------------
    input  logic        req_valid,
    output logic        req_ready,
    input  logic [31:0] req_addr,
    input  logic        req_write,
    input  logic [31:0] req_wdata,
    input  logic [3:0]  req_wstrb,

    output logic        rsp_valid,
    input  logic        rsp_ready,
    output logic [31:0] rsp_rdata,
    output logic        rsp_err,

    // ---- APB master port (shared address/control; decoded selects) ---------
    output logic [31:0] paddr,
    output logic        psel_uart,
    output logic        psel_gpio,
    output logic        psel_timer,
    output logic        penable,
    output logic        pwrite,
    output logic [31:0] pwdata,
    output logic [3:0]  pstrb,

    input  logic [31:0] prdata_uart,
    input  logic [31:0] prdata_gpio,
    input  logic [31:0] prdata_timer,
    input  logic        pready_uart,
    input  logic        pready_gpio,
    input  logic        pready_timer,
    input  logic        pslverr_uart,
    input  logic        pslverr_gpio,
    input  logic        pslverr_timer,

    // ---- Low-power: glitch-free clock-gate enable (1 = clock active) -------
    output logic        clk_en
);

  // Register-map / decode constants (module scope for synthesizable localparam)
  `include "apb_addr_map.svh"

  // ---------------------------------------------------------------------------
  // FSM encoding
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_IDLE   = 2'b00,
    ST_SETUP  = 2'b01,
    ST_ACCESS = 2'b10,
    ST_RESP   = 2'b11
  } state_e;

  state_e state_q, state_d;

  // Latched transfer attributes (held through SETUP/ACCESS)
  logic [31:0] addr_q,  addr_d;
  logic        write_q, write_d;
  logic [31:0] wdata_q, wdata_d;
  logic [3:0]  wstrb_q, wstrb_d;

  // Response capture
  logic [31:0] rdata_q, rdata_d;
  logic        err_q,   err_d;

  // Next-cycle APB control (registered for glitch-free PSEL/PENABLE)
  logic [31:0] paddr_d;
  logic        psel_uart_d;
  logic        psel_gpio_d;
  logic        psel_timer_d;
  logic        penable_d;
  logic        pwrite_d;
  logic [31:0] pwdata_d;
  logic [3:0]  pstrb_d;
  logic        clk_en_d;

  // Registered APB outputs
  logic [31:0] paddr_q;
  logic        psel_uart_q;
  logic        psel_gpio_q;
  logic        psel_timer_q;
  logic        penable_q;
  logic        pwrite_q;
  logic [31:0] pwdata_q;
  logic [3:0]  pstrb_q;
  logic        clk_en_q;

  // Muxed slave response for the active select
  logic [31:0] prdata_mux;
  logic        pready_mux;
  logic        pslverr_mux;

  // ---------------------------------------------------------------------------
  // Combinational address decoder for a candidate address
  // ---------------------------------------------------------------------------
  function automatic logic [2:0] apb_decode(input logic [31:0] addr);
    logic in_window;
    logic sel_uart;
    logic sel_gpio;
    logic sel_timer;
    // Use BASE/END so the full register-map constants participate in decode
    in_window = (addr >= APB_PERIPH_BASE) && (addr < APB_PERIPH_END);
    sel_uart  = in_window && ((addr & APB_PERIPH_MASK) == APB_UART_BASE);
    sel_gpio  = in_window && ((addr & APB_PERIPH_MASK) == APB_GPIO_BASE);
    sel_timer = in_window && ((addr & APB_PERIPH_MASK) == APB_TIMER_BASE);
    return {sel_timer, sel_gpio, sel_uart};
  endfunction

  // ---------------------------------------------------------------------------
  // Slave response mux — only the selected peripheral drives the channel
  // ---------------------------------------------------------------------------
  always_comb begin
    prdata_mux  = 32'h0;
    pready_mux  = 1'b1;
    pslverr_mux = 1'b1; // decode miss completes with error

    unique case (1'b1)
      psel_uart_q: begin
        prdata_mux  = prdata_uart;
        pready_mux  = pready_uart;
        pslverr_mux = pslverr_uart;
      end
      psel_gpio_q: begin
        prdata_mux  = prdata_gpio;
        pready_mux  = pready_gpio;
        pslverr_mux = pslverr_gpio;
      end
      psel_timer_q: begin
        prdata_mux  = prdata_timer;
        pready_mux  = pready_timer;
        pslverr_mux = pslverr_timer;
      end
      default: begin
        prdata_mux  = 32'h0;
        pready_mux  = 1'b1;
        pslverr_mux = 1'b1;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Next-state / datapath / next APB outputs
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d      = state_q;
    addr_d       = addr_q;
    write_d      = write_q;
    wdata_d      = wdata_q;
    wstrb_d      = wstrb_q;
    rdata_d      = rdata_q;
    err_d        = err_q;

    paddr_d      = paddr_q;
    psel_uart_d  = 1'b0;
    psel_gpio_d  = 1'b0;
    psel_timer_d = 1'b0;
    penable_d    = 1'b0;
    pwrite_d     = 1'b0;
    pwdata_d     = pwdata_q;
    pstrb_d      = 4'h0;

    req_ready = 1'b0;
    rsp_valid = 1'b0;

    unique case (state_q)
      ST_IDLE: begin
        req_ready = 1'b1;
        if (req_valid) begin
          addr_d  = req_addr;
          write_d = req_write;
          wdata_d = req_wdata;
          wstrb_d = req_wstrb;
          state_d = ST_SETUP;

          // SETUP: assert decoded PSEL, hold PENABLE low
          {psel_timer_d, psel_gpio_d, psel_uart_d} = apb_decode(req_addr);
          paddr_d  = req_addr;
          pwrite_d = req_write;
          pwdata_d = req_wdata;
          pstrb_d  = req_write ? req_wstrb : 4'h0;
          penable_d = 1'b0;
        end
      end

      ST_SETUP: begin
        // ACCESS: keep PSEL/addr/data; raise PENABLE
        {psel_timer_d, psel_gpio_d, psel_uart_d} = apb_decode(addr_q);
        paddr_d   = addr_q;
        pwrite_d  = write_q;
        pwdata_d  = wdata_q;
        pstrb_d   = write_q ? wstrb_q : 4'h0;
        penable_d = 1'b1;
        state_d   = ST_ACCESS;
      end

      ST_ACCESS: begin
        {psel_timer_d, psel_gpio_d, psel_uart_d} = apb_decode(addr_q);
        paddr_d   = addr_q;
        pwrite_d  = write_q;
        pwdata_d  = wdata_q;
        pstrb_d   = write_q ? wstrb_q : 4'h0;
        penable_d = 1'b1;

        if (pready_mux) begin
          rdata_d = prdata_mux;
          err_d   = pslverr_mux;
          // Drop PSEL/PENABLE on the cycle after ACCESS completes
          psel_uart_d  = 1'b0;
          psel_gpio_d  = 1'b0;
          psel_timer_d = 1'b0;
          penable_d    = 1'b0;
          pwrite_d     = 1'b0;
          pstrb_d      = 4'h0;
          state_d      = ST_RESP;
        end
      end

      ST_RESP: begin
        rsp_valid = 1'b1;
        if (rsp_ready) begin
          state_d = ST_IDLE;
        end
      end

      default: begin
        state_d = ST_IDLE;
      end
    endcase

    // Clock-gate enable: awake while a transfer is outstanding or pending
    clk_en_d = (state_d != ST_IDLE) || req_valid;
  end

  // ---------------------------------------------------------------------------
  // Sequential state
  // ---------------------------------------------------------------------------
  always_ff @(posedge pclk or negedge preset_n) begin
    if (!preset_n) begin
      state_q      <= ST_IDLE;
      addr_q       <= 32'h0;
      write_q      <= 1'b0;
      wdata_q      <= 32'h0;
      wstrb_q      <= 4'h0;
      rdata_q      <= 32'h0;
      err_q        <= 1'b0;
      paddr_q      <= 32'h0;
      psel_uart_q  <= 1'b0;
      psel_gpio_q  <= 1'b0;
      psel_timer_q <= 1'b0;
      penable_q    <= 1'b0;
      pwrite_q     <= 1'b0;
      pwdata_q     <= 32'h0;
      pstrb_q      <= 4'h0;
      clk_en_q     <= 1'b1;
    end else begin
      state_q      <= state_d;
      addr_q       <= addr_d;
      write_q      <= write_d;
      wdata_q      <= wdata_d;
      wstrb_q      <= wstrb_d;
      rdata_q      <= rdata_d;
      err_q        <= err_d;
      paddr_q      <= paddr_d;
      psel_uart_q  <= psel_uart_d;
      psel_gpio_q  <= psel_gpio_d;
      psel_timer_q <= psel_timer_d;
      penable_q    <= penable_d;
      pwrite_q     <= pwrite_d;
      pwdata_q     <= pwdata_d;
      pstrb_q      <= pstrb_d;
      clk_en_q     <= clk_en_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Output assignments
  // ---------------------------------------------------------------------------
  assign paddr      = paddr_q;
  assign psel_uart  = psel_uart_q;
  assign psel_gpio  = psel_gpio_q;
  assign psel_timer = psel_timer_q;
  assign penable    = penable_q;
  assign pwrite     = pwrite_q;
  assign pwdata     = pwdata_q;
  assign pstrb      = pstrb_q;
  assign rsp_rdata  = rdata_q;
  assign rsp_err    = err_q;
  assign clk_en     = clk_en_q;

endmodule
