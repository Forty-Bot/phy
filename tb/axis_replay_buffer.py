# SPDX-License-Identifier: AGPL-3.0-Only
# Copyright (C) 2022 Sean Anderson <seanga2@gmail.com>

import cocotb
from cocotb.clock import Clock
from cocotb.regression import TestFactory
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

from .util import ClockEnable, lookahead, timeout

BUF_SIZE = 54

async def send_packet(signals, packet, ratio=1):
    for val, last in lookahead(packet):
        if 'err' in signals:
            if val is None:
                signals['data'].value = 0
                signals['err'].value = 1
            else:
                signals['data'].value = val
                signals['err'].value = 0
        else:
            signals['data'].value = val
        signals['valid'].value = 1
        signals['last'].value = last
        await RisingEdge(signals['clk'])
        while True:
            await FallingEdge(signals['clk'])
            if signals['ready'].value:
                break
        signals['valid'].value = 0
        if ratio != 1:
            await ClockCycles(signals['clk'], ratio - 1, rising=False)

@timeout(30, 'us')
async def test_replay(buf, in_ratio, out_ratio):
    buf.s_axis_valid.value = 0
    buf.s_axis_last.value = 0
    buf.m_axis_ready.value = 1
    buf.replay.value = 0
    buf.done.value = 0

    await Timer(1)
    await cocotb.start(Clock(buf.clk, 8, units='ns').start())
    await FallingEdge(buf.clk)
    await cocotb.start(ClockEnable(buf.clk, buf.m_axis_ready, out_ratio))

    # A packet equal to BUF_SIZE, one around 2**BUF_WIDTH, and one around
    # 2**(BUF_WIDTH + 1) (plus some extra). This should capture most of the fun
    # conditions. We start at different data values to make sure we aren't
    # reusing anything from the last test.
    packets = [list(range(54)), list(range(64, 128)), list(range(128, 512))]

    async def send():
        for packet in packets:
            await send_packet({
                'clk': buf.clk,
                'data': buf.s_axis_data,
                'valid': buf.s_axis_valid,
                'last': buf.s_axis_last,
                'ready': buf.s_axis_ready,
            }, packet, in_ratio)

    async def recv(packet):
        async def handshake():
            while not buf.m_axis_valid.value or not buf.m_axis_ready.value:
                await RisingEdge(buf.clk)

        async def recv_len(length):
            for i, val in enumerate(packet[:length]):
                await handshake()
                assert buf.m_axis_data.value == val
                assert buf.m_axis_last == (i == len(packet) - 1)
                await RisingEdge(buf.clk)

        async def restart():
            await FallingEdge(buf.clk)
            assert buf.replayable.value
            buf.replay.value = 1
            await FallingEdge(buf.clk)
            buf.replay.value = 0

        buf.done.value = 0
        replayable = min(len(packet), BUF_SIZE)
        await recv_len(replayable - 3)
        await restart()
        await recv_len(replayable - 2)
        # As long as the packet is <= BUF_SIZE we should be able to wait
        # Try it out
        if len(packet) <= BUF_SIZE:
            await ClockCycles(buf.clk, 3)
        await restart()

        buf.done.value = 1
        await recv_len(len(packet))

    await cocotb.start(send())
    for packet in packets:
        await recv(packet)

replay_tests = TestFactory(test_replay)
replay_tests.add_option('in_ratio', (1, 4))
replay_tests.add_option('out_ratio', (1, 4))
replay_tests.generate_tests()
