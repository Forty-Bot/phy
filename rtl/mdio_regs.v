// SPDX-License-Identifier: AGPL-3.0-Only
/*
 * Copyright (C) 2022 Sean Anderson <seanga2@gmail.com>
 */

`include "common.vh"

module mdio_regs (
	/* Wishbone */
	input clk,
	output reg ack, err,
	input cyc, stb, we,
	input [4:0] addr,
	input [15:0] data_write,
	output reg [15:0] data_read,

	/* Control signals */
	input link_status,
	input positive_wraparound,
	input negative_wraparound,
	input false_carrier,
	input symbol_error,
	output reg loopback,
	output reg pdown,
	output reg isolate,
	output reg coltest,
	output reg descrambler_test,
	output reg link_monitor_test
);

	/* The current price of a CID is $805... */
	parameter [23:0] OUI		= 0;
	parameter [5:0] MODEL		= 0;
	parameter [3:0] REVISION	= 0;
	/*
	 * Normally, this module will assert err when read/writing to an
	 * unknown register. The master will detect this and won't drive the
	 * MDIO line. However, this might be undesirable if there is no
	 * external MDIO bus. Setting this parameter to 0 will cause it to ack
	 * all transactions. Writes to unknown registers will be ignored, and
	 * reads from unknown registers will yield 16'hffff, emulating
	 * a pull-up on MDIO.
	 */
	parameter EMULATE_PULLUP	= 0;
	/* Enable counter registers */
	parameter ENABLE_COUNTERS	= 1;
	/*
	 * Number of bits in counters; we can't meet timing with 16 bits, so
	 * use a smaller default.
	 */
	parameter COUNTER_WIDTH		= 15;

	/* c22 Basic Mode Control Register */
	localparam BMCR		= 0;
	/* c22 Basic Mode Status Register */
	localparam BMSR		= 1;
	/* c22 Phy Identifier */
	localparam ID1		= 2;
	localparam ID2		= 3;
	/* Negative Wraparound Counter Register */
	localparam NWCR		= 16;
	/* Positive Wraparound Counter Register */
	localparam PWCR		= 17;
	/* Disconnect Counter Register */
	localparam DCR		= 18;
	/* False Carrier Counter Register */
	localparam FCCR		= 19;
	/* Symbol Error Counter Register */
	localparam SECR		= 21;
	/* Vendor Control Register */
	localparam VCR		= 30;

	localparam BMCR_RESET		= 15;
	localparam BMCR_LOOPBACK	= 14;
	localparam BMCR_SPEED_LSB	= 13;
	localparam BMCR_PDOWN		= 11;
	localparam BMCR_ISOLATE		= 10;
	localparam BMCR_DUPLEX		= 8;
	localparam BMCR_COLTEST		= 7;
	localparam BMCR_SPEED_MSB	= 6;

	localparam BMSR_100FULL		= 14;
	localparam BMSR_100HALF		= 13;
	localparam BMSR_LSTATUS		= 2;
	localparam BMSR_EXTCAP		= 0;

	/* VCR Descrambler test mode */
	localparam VCR_DTEST		= 15;
	/* VCR Link monitor test mode */
	localparam VCR_LTEST		= 14;

	integer i;
	reg duplex, link_status_latched, link_status_latched_next, link_status_last, disconnect;
	reg loopback_next, pdown_next, isolate_next, duplex_next, coltest_next;
	reg descrambler_test_next, link_monitor_test_next;
	reg [15:0] data_read_next;
	/* Can't meet timing at 16 bits wide */
	reg [COUNTER_WIDTH-1:0] nwc, pwc, dc, fcc, sec;
	reg [COUNTER_WIDTH-1:0] nwc_next, pwc_next, dc_next, fcc_next, sec_next;

	initial begin
		loopback = 0;
		pdown = 0;
		isolate = 1;
		duplex = 0;
		coltest = 0;
		link_status_latched = 0;
		link_status_last = 0;
		if (ENABLE_COUNTERS) begin
			nwc = 0;
			pwc = 0;
			dc = 0;
			fcc = 0;
			sec = 0;
		end
		descrambler_test = 0;
		link_monitor_test = 0;
	end

	always @(*) begin
		loopback_next = loopback;
		pdown_next = pdown;
		isolate_next = isolate;
		duplex_next = duplex;
		coltest_next = coltest;
		link_status_latched_next = link_status_latched && link_status;
		disconnect = link_status_last && !link_status;
		descrambler_test_next = descrambler_test;
		link_monitor_test_next = link_monitor_test;

		if (ENABLE_COUNTERS) begin
			nwc_next = nwc;
			pwc_next = pwc;
			dc_next = dc;
			fcc_next = fcc;
			sec_next = sec;

			if (!(&nwc)) nwc_next = nwc + negative_wraparound;
			if (!(&pwc)) pwc_next = pwc + positive_wraparound;
			if (!(&dc)) dc_next = dc + disconnect;
			if (!(&fcc)) fcc_next = fcc + false_carrier;
			if (!(&sec)) sec_next = sec + symbol_error;
		end

		data_read_next = 0;
		ack = cyc && stb;
		err = 0;
		case (addr)
		BMCR: begin
			data_read_next[BMCR_LOOPBACK] = loopback;
			data_read_next[BMCR_SPEED_LSB] = 1; /* 100 Mb/s */
			data_read_next[BMCR_PDOWN] = pdown;
			data_read_next[BMCR_ISOLATE] = isolate;
			data_read_next[BMCR_DUPLEX] = duplex;
			data_read_next[BMCR_COLTEST] = coltest;

			if (cyc && stb && we) begin
				loopback_next = data_write[BMCR_LOOPBACK];
				pdown_next = data_write[BMCR_PDOWN];
				isolate_next = data_write[BMCR_ISOLATE];
				duplex_next = data_write[BMCR_DUPLEX];
				coltest_next = data_write[BMCR_COLTEST];

				if (data_write[BMCR_RESET]) begin
					loopback_next = 0;
					pdown_next = 0;
					isolate_next = 1;
					duplex_next = 0;
					coltest_next = 0;
					link_status_latched_next = link_status;
					if (ENABLE_COUNTERS) begin
						nwc_next = negative_wraparound;
						pwc_next = positive_wraparound;
						dc_next = disconnect;
						fcc_next = false_carrier;
						sec_next = symbol_error;
					end
					descrambler_test_next = 0;
					link_monitor_test_next = 0;
				end
			end
		end
		BMSR: begin
			data_read_next[BMSR_100FULL] = 1;
			data_read_next[BMSR_100HALF] = 1;
			data_read_next[BMSR_LSTATUS] = link_status_latched;
			data_read_next[BMSR_EXTCAP] = 1;

			if (cyc && stb && !we)
				link_status_latched_next = link_status;
		end
		ID1: begin
			for (i = 0; i < 16; i = i + 1)
				data_read_next[i] = OUI[17 - i];
		end
		ID2: begin
			data_read_next[3:0] = REVISION;
			data_read_next[9:4] = MODEL;
			for (i = 0; i < 6; i = i + 1)
				data_read_next[i + 4] = OUI[23 - i];
		end
		NWCR: if (ENABLE_COUNTERS) begin
			data_read_next = nwc;

			if (cyc && stb)
				nwc_next = we ? data_write : negative_wraparound;
		end
		PWCR: if (ENABLE_COUNTERS) begin
			data_read_next = pwc;

			if (cyc && stb)
				pwc_next = we ? data_write : positive_wraparound;
		end
		DCR: if (ENABLE_COUNTERS) begin
			data_read_next = dc;

			if (cyc && stb)
				dc_next = we ? data_write : disconnect;
		end
		FCCR: if (ENABLE_COUNTERS) begin
			data_read_next = fcc;

			if (cyc && stb)
				fcc_next = we ? data_write : false_carrier;
		end
		SECR: if (ENABLE_COUNTERS) begin
			data_read_next = sec;

			if (cyc && stb)
				sec_next = we ? data_write : symbol_error;
		end
		VCR: begin
			data_read_next[VCR_DTEST] = descrambler_test;
			data_read_next[VCR_LTEST] = link_monitor_test;

			if (cyc && stb && we) begin
				descrambler_test_next = data_write[VCR_DTEST];
				link_monitor_test_next = data_write[VCR_LTEST];
			end
		end
		default: begin
			if (EMULATE_PULLUP) begin
				data_read_next = 16'hFFFF;
			end else begin
				ack = 0;
				err = stb && cyc;
				data_read_next = 16'hXXXX;
			end
		end
		endcase
	end

	always @(posedge clk) begin
		loopback <= loopback_next;
		pdown <= pdown_next;
		isolate <= isolate_next;
		duplex <= duplex_next;
		coltest <= coltest_next;
		link_status_latched <= link_status_latched_next;
		link_status_last <= link_status;
		data_read <= data_read_next;
		if (ENABLE_COUNTERS) begin
			nwc <= nwc_next;
			pwc <= pwc_next;
			dc <= dc_next;
			fcc <= fcc_next;
			sec <= sec_next;
		end
		descrambler_test <= descrambler_test_next;
		link_monitor_test <= link_monitor_test_next;
	end

endmodule
