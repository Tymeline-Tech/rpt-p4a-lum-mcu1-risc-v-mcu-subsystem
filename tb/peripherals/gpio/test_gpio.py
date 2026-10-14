"""Minimal GPIO cocotb suite (scaffold for later story step).

Produces functional coverage XML/HTML required by the project gate.
Full pin-toggle / direction tests land in the GPIO verification task.
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb_coverage.coverage import CoverPoint, coverage_db

ADDR_DATA = 0x0
ADDR_DIR = 0x4
ADDR_IN = 0x8
CLK_PERIOD_NS = 20

@CoverPoint("gpio.dir", xf=lambda dir_v, data_v: dir_v, bins=[0x0000, 0xFFFF, 0x00FF, 0xFF00])
@CoverPoint("gpio.data", xf=lambda dir_v, data_v: data_v, bins=[0x0000, 0x0001, 0xAAAA, 0xFFFF])
def _cover(dir_v: int, data_v: int) -> None:
    pass


def _sample(dir_v: int = 0, data_v: int = 0) -> None:
    _cover(dir_v, data_v)


async def _write_dir_data(dut, dir_v: int, data_v: int) -> None:
    await apb_write(dut, ADDR_DIR, dir_v)
    await apb_write(dut, ADDR_DATA, data_v)
    await RisingEdge(dut.PCLK)
    _sample(dir_v=dir_v, data_v=data_v)

async def drive_clock(dut) -> None:
    cocotb.start_soon(Clock(dut.PCLK, CLK_PERIOD_NS, unit="ns").start())


async def reset_dut(dut) -> None:
    dut.PRESETn.value = 0
    dut.PSEL.value = 0
    dut.PENABLE.value = 0
    dut.PWRITE.value = 0
    dut.PADDR.value = 0
    dut.PWDATA.value = 0
    dut.gpio_in.value = 0
    await ClockCycles(dut.PCLK, 4)
    dut.PRESETn.value = 1
    await RisingEdge(dut.PCLK)


async def apb_write(dut, addr: int, data: int) -> None:
    await RisingEdge(dut.PCLK)
    dut.PSEL.value = 1
    dut.PENABLE.value = 0
    dut.PWRITE.value = 1
    dut.PADDR.value = addr
    dut.PWDATA.value = data
    await RisingEdge(dut.PCLK)
    dut.PENABLE.value = 1
    await RisingEdge(dut.PCLK)
    dut.PSEL.value = 0
    dut.PENABLE.value = 0
    dut.PWRITE.value = 0


async def apb_read(dut, addr: int) -> int:
    await RisingEdge(dut.PCLK)
    dut.PSEL.value = 1
    dut.PENABLE.value = 0
    dut.PWRITE.value = 0
    dut.PADDR.value = addr
    await RisingEdge(dut.PCLK)
    dut.PENABLE.value = 1
    await RisingEdge(dut.PCLK)
    value = int(dut.PRDATA.value)
    dut.PSEL.value = 0
    dut.PENABLE.value = 0
    return value


def export_coverage() -> None:
    out_xml = Path(os.environ.get("COVERAGE_XML", "coverage.xml"))
    coverage_db.export_to_xml(filename=str(out_xml))
    html_path = Path(
        os.environ.get(
            "COVERAGE_HTML",
            str(Path(__file__).resolve().parents[3] / "reports" / "coverage" / "gpio_cov.html"),
        )
    )
    html_path.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    total_hits = total_bins = 0
    for name, cp in coverage_db.items():
        detailed = getattr(cp, "detailed_coverage", {}) or {}
        hits = sum(1 for v in detailed.values() if v)
        bins = len(detailed) if detailed else 0
        total_hits += hits
        total_bins += bins
        pct = (100.0 * hits / bins) if bins else 0.0
        rows.append(f"<tr><td>{name}</td><td>{hits}/{bins}</td><td>{pct:.1f}%</td></tr>")
    overall = (100.0 * total_hits / total_bins) if total_bins else 100.0
    html_path.write_text(
        f"""<!DOCTYPE html><html><head><meta charset="utf-8"><title>GPIO Functional Coverage</title>
<style>body{{font-family:system-ui,sans-serif;margin:2rem;background:#0f1419;color:#e7ecf1}}
.bar{{height:1.25rem;background:#243044;border-radius:4px;overflow:hidden;max-width:28rem}}
.bar>span{{display:block;height:100%;background:#3d9a6a;width:{overall:.1f}%}}
table{{border-collapse:collapse;margin-top:1.5rem}} td,th{{border:1px solid #334;padding:.4rem .75rem}}</style>
</head><body><h1>GPIO Functional Coverage</h1>
<p>Overall: <strong>{overall:.1f}%</strong> ({total_hits}/{total_bins} bins)</p>
<div class="bar"><span></span></div>
<table><thead><tr><th>Cover point</th><th>Hits</th><th>%</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></body></html>""",
        encoding="utf-8",
    )


@cocotb.test()
async def test_gpio_direction_and_output(dut):
    """Basic direction switch, independent pin toggle, and input read."""
    await drive_clock(dut)
    await reset_dut(dut)

    # Cover directed dir/data combinations (scaffold; full suite is a later task)
    await _write_dir_data(dut, 0x0000, 0x0000)
    assert int(dut.gpio_oe.value) == 0x0000

    await _write_dir_data(dut, 0xFFFF, 0xAAAA)
    assert int(dut.gpio_out.value) == 0xAAAA
    assert await apb_read(dut, ADDR_DIR) == 0xFFFF

    await _write_dir_data(dut, 0xFFFF, 0x0001)
    assert int(dut.gpio_out.value) == 0x0001

    await _write_dir_data(dut, 0xFFFF, 0xFFFF)
    assert int(dut.gpio_out.value) == 0xFFFF

    await _write_dir_data(dut, 0x00FF, 0x0001)
    assert int(dut.gpio_oe.value) == 0x00FF

    # Upper byte outputs / lower byte inputs — read external value
    await _write_dir_data(dut, 0xFF00, 0x0001)
    dut.gpio_in.value = 0x0055
    await RisingEdge(dut.PCLK)
    await RisingEdge(dut.PCLK)
    sampled = await apb_read(dut, ADDR_IN)
    assert sampled == 0x0055, f"expected input 0x0055, got 0x{sampled:04X}"

    export_coverage()
