// -----------------------------------------------------------------------------
// LUM-MCU1 APB peripheral address map
// Shared constants for the APB master address decoder and peripheral stubs.
// Window size per peripheral: 4 KiB (12-bit offset).
// -----------------------------------------------------------------------------
`ifndef APB_ADDR_MAP_SVH
`define APB_ADDR_MAP_SVH

// Peripheral aperture base (APB I/O window in the RV32IMC memory map)
localparam logic [31:0] APB_PERIPH_BASE = 32'h4000_0000;

// Aperture size per peripheral (4 KiB)
localparam logic [31:0] APB_PERIPH_SIZE = 32'h0000_1000;

// Select mask: clears offset bits within a peripheral window
localparam logic [31:0] APB_PERIPH_MASK = ~(APB_PERIPH_SIZE - 32'h1);

// Per-peripheral base addresses (4 KiB aligned)
localparam logic [31:0] APB_UART_BASE  = APB_PERIPH_BASE;
localparam logic [31:0] APB_GPIO_BASE  = APB_PERIPH_BASE + APB_PERIPH_SIZE;
localparam logic [31:0] APB_TIMER_BASE = APB_PERIPH_BASE + (APB_PERIPH_SIZE << 1);

// End of APB I/O window (exclusive): UART + GPIO + Timer
localparam logic [31:0] APB_PERIPH_END = APB_PERIPH_BASE + (APB_PERIPH_SIZE + (APB_PERIPH_SIZE << 1));

`endif // APB_ADDR_MAP_SVH
