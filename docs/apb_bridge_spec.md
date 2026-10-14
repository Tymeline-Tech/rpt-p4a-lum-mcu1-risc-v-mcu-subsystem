# LUM-MCU1 APB Bridge Specification

## Overview

The APB bridge connects the RV32IMC core fabric to on-chip peripherals over
**AMBA 3 APB (APB v2.0)** timing. The master (`rtl/bus/apb_master.sv`) performs
address decode, drives `PSEL` / `PENABLE` / `PWRITE` / `PADDR` / `PWDATA`, and
waits for `PREADY` before completing the CPU-side response.

## Protocol timing

| Phase   | `PSEL` | `PENABLE` | Notes                                      |
|---------|--------|-----------|--------------------------------------------|
| IDLE    | 0      | 0         | No transfer                                |
| SETUP   | 1      | 0         | One cycle; address/control stable          |
| ACCESS  | 1      | 1         | Wait until selected slave asserts `PREADY` |

`PWRITE` distinguishes writes (`1`) from reads (`0`). Decode misses complete
locally with `PSLVERR` semantics on the CPU response (`rsp_err`).

## Address map

Constants are defined in `rtl/include/apb_addr_map.svh`. Each peripheral owns a
**4 KiB** window (`APB_PERIPH_MASK = 0xFFFF_F000`).

| Peripheral | Base address  | End (exclusive) | `PSEL` output |
|------------|---------------|-----------------|---------------|
| UART       | `0x4000_0000` | `0x4000_1000`   | `psel_uart`   |
| GPIO       | `0x4000_1000` | `0x4000_2000`   | `psel_gpio`   |
| Timer      | `0x4000_2000` | `0x4000_3000`   | `psel_timer`  |

APB I/O window: `APB_PERIPH_BASE` … `APB_PERIPH_END` (`0x4000_0000` … `0x4000_3000`).

## CPU request interface

| Signal       | Direction | Description                          |
|--------------|-----------|--------------------------------------|
| `req_valid`  | in        | Transfer request valid               |
| `req_ready`  | out       | Master accepts request (IDLE only)   |
| `req_addr`   | in        | 32-bit byte address                  |
| `req_write`  | in        | 1 = write, 0 = read                  |
| `req_wdata`  | in        | Write data                           |
| `req_wstrb`  | in        | Byte strobes (write)                 |
| `rsp_valid`  | out       | Response valid                       |
| `rsp_ready`  | in        | CPU accepts response                 |
| `rsp_rdata`  | out       | Read data                            |
| `rsp_err`    | out       | Slave error or decode miss           |

## Low-power clock gating

`clk_en` is a **registered**, glitch-free enable: high while a transfer is
outstanding or `req_valid` is asserted; low in idle with no pending request.
Integrate with an ICG cell so the APB clock can be gated when the bridge is
idle.

## Files

- `rtl/include/apb_addr_map.svh` — register-map / decode constants
- `rtl/bus/apb_master.sv` — APB master + address decoder
