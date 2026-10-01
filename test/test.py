# SPDX-FileCopyrightText: © 2026 Luis Lasso
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.simtime import get_sim_time
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

H_TOTAL = 800  # pixels per line (640 visible)
V_TOTAL = 525  # lines per frame (480 visible)
V_SYNC_START = 490

# Colors as (red, green, blue), 2 bits each
SKY_TOP = (1, 2, 3)
TITLE_ORANGE = (3, 2, 0)


def pixel(dut):
    return (int(dut.red.value), int(dut.green.value), int(dut.blue.value))


async def reset(dut):
    clock = Clock(dut.clk, 40, unit="ns")  # ~25 MHz VGA pixel clock
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1


async def goto_frame_start(dut):
    """Wait for vsync, then until the first visible pixel of the next frame."""
    await FallingEdge(dut.vsync)
    # vsync falls one cycle after line 490 starts; line 0 starts (525 - 490) lines later
    await ClockCycles(dut.clk, (V_TOTAL - V_SYNC_START) * H_TOTAL)


async def sample(dut, x, y):
    """Color at (x, y), measured from the start of the frame (call right after goto_frame_start)."""
    await ClockCycles(dut.clk, y * H_TOTAL + x)
    await FallingEdge(dut.clk)
    return pixel(dut)


@cocotb.test()
async def test_vga_timing(dut):
    """hsync every 800 clocks, vsync every 525 lines."""
    await reset(dut)

    await FallingEdge(dut.hsync)
    t0 = get_sim_time("ns")
    await FallingEdge(dut.hsync)
    t1 = get_sim_time("ns")
    assert round((t1 - t0) / 40) == H_TOTAL, f"hsync period {(t1 - t0) / 40} clocks"

    await RisingEdge(dut.hsync)
    t2 = get_sim_time("ns")
    assert round((t2 - t1) / 40) == 96, "hsync pulse should be 96 clocks"

    await FallingEdge(dut.vsync)
    v0 = get_sim_time("ns")
    await FallingEdge(dut.vsync)
    v1 = get_sim_time("ns")
    assert round((v1 - v0) / 40) == H_TOTAL * V_TOTAL, "vsync period should be one frame"


@cocotb.test()
async def test_title_and_start(dut):
    """The title screen shows LUIS; a press on ui_in[0] starts the game."""
    await reset(dut)

    await goto_frame_start(dut)
    sky = await sample(dut, 600, 40)
    dut._log.info(f"sky pixel: {sky}")
    assert sky == SKY_TOP

    await goto_frame_start(dut)
    letter = await sample(dut, 200, 120)  # inside the "L" of the title
    dut._log.info(f"title pixel: {letter}")
    assert letter == TITLE_ORANGE

    # Press (toggle) the button: the game starts and the title goes away
    dut.ui_in.value = 1
    await goto_frame_start(dut)
    await goto_frame_start(dut)
    after = await sample(dut, 200, 120)
    dut._log.info(f"same pixel while playing: {after}")
    assert after == SKY_TOP
