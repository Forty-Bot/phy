// SPDX-License-Identifier: AGPL-3.0-Only
/*
 * Copyright (C) 2022 Sean Anderson <seanga2@gmail.com>
 */

`include "common.vh"

module descramble (
	input clk,
	input [1:0] scrambled, scrambled_valid,
	input signal_status, test_mode,
	output reg locked,
	output reg [1:0] unscrambled, unscrambled_valid
);

	reg relock, relock_next, locked_next;
	initial relock = 0;
	reg [1:0] ldd, unscrambled_next;
	reg [10:0] lfsr, lfsr_next;

	/*
	 * The number of consecutive idle bits to require when locking, as
	 * well as the number necessary to prevent unlocking. For the first
	 * case, this must be less than 60 bits (7.2.3.1.1), including the
	 * bits necessary to initialize the lfsr. For the second, this must be
	 * less than 29 bits (7.2.3.3(f)). We use 29 to meet these requirements;
	 * it is increased by 1 to allow for an easier implementation of the
	 * counter, and decreased by 1 to allow easier implementation when
	 * scrambled_valid = 2. The end result is that only 28 bits might be
	 * required in certain situations.
	 */
	localparam CONSECUTIVE_IDLES = 5'd29;
	reg [4:0] idle_counter, idle_counter_next;
	initial idle_counter = CONSECUTIVE_IDLES;

	/*
	 * The amount of time without recieving consecutive idles before we
	 * unlock. This must be greater than 361us (7.2.3.3(f)). 2^16-1 works
	 * out to around 524us at 125MHz.
	 */
	localparam UNLOCK_TIME = 16'hffff;
	/* 5us, or around one minimum-length packet plus some extra */
	localparam TEST_UNLOCK_TIME = 16'd625;
	reg [15:0] unlock_counter, unlock_counter_next;

	always @(*) begin
		ldd = { lfsr[8] ^ lfsr[10], lfsr[7] ^ lfsr[9] };
		unscrambled_next = scrambled ^ ldd;

		/*
		 * We must invert scrambled before adding it to the lfsr in
		 * order to remove the ^1 from the input idle. This doesn't
		 * affect the output of the lfsr during the sample state
		 * because two bits from the lfsr are xor'd together,
		 * canceling out the inversion.
		 */
		lfsr_next = lfsr;
		if (scrambled_valid[0])
			lfsr_next = { lfsr[9:0], locked ? ldd[1] : ~scrambled[1] };
		else if (scrambled_valid[1])
			lfsr_next = { lfsr[8:0], locked ? ldd : ~scrambled };

		idle_counter_next = idle_counter;
		if (scrambled_valid[1]) begin
			if (unscrambled_next[1] && unscrambled_next[0])
				idle_counter_next = idle_counter - 2;
			else if (unscrambled_next[0])
				idle_counter_next = idle_counter - 1;
			else
				idle_counter_next = CONSECUTIVE_IDLES;
		end else if (scrambled_valid[0]) begin
			if (unscrambled_next[1])
				idle_counter_next = idle_counter - 1;
			else
				idle_counter_next = CONSECUTIVE_IDLES;
		end

		relock_next = 0;
		if (!idle_counter_next[4:1]) begin
			/*
			 * Reset the counter to 2 to ensure we can always
			 * subtract idles without underflowing
			 */
			idle_counter_next = 2;
			relock_next = 1;
		end

		locked_next = 1;
		unlock_counter_next = unlock_counter;
		if (relock) begin
			unlock_counter_next = test_mode ? TEST_UNLOCK_TIME : UNLOCK_TIME;
		end else if (|unlock_counter) begin
			unlock_counter_next = unlock_counter - 1;
		end else begin
			locked_next = 0;
		end
	end

	always @(posedge clk) begin
		unscrambled <= unscrambled_next;
		if (signal_status) begin
			lfsr <= lfsr_next;
			idle_counter <= idle_counter_next;
			relock <= relock_next;
			unlock_counter <= unlock_counter_next;
			locked <= locked_next;
			unscrambled_valid <= scrambled_valid;
		end else begin
			lfsr <= 0;
			idle_counter <= CONSECUTIVE_IDLES;
			relock <= 0;
			unlock_counter <= 0;
			locked <= 0;
			unscrambled_valid <= 0;
		end
	end

	`DUMP(0)

endmodule
