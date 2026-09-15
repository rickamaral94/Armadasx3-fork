#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <utility>
#include <vector>

// Which guest addresses are executing in the interpreter instead of recompiled code, and how often.
// Shared by the PPU and SPU fallback paths, hence Emu/CPU rather than Emu/Cell.
//
// The emulator already knows THAT it falls back: ppu_recompiler_fallback carries a perf_meter, and
// the SPU side keeps the set of blocks whose compilation failed. Neither answers the question that
// decides whether the recompiler is worth working on -- WHICH code, and how hot. An aggregate says
// "some percent of PPU time was interpreted"; a failed-block set says a block could not be compiled
// but not whether anything ever reaches it. A block that failed and never runs costs nothing, and
// optimising for it is wasted work.
//
// Deliberately not the plain per-thread counters used for the reservation diagnostics. Those are
// per-thread totals read by a dump on another thread, where a torn read costs nothing. This is
// keyed by address and shared by every PPU thread, so a torn count would silently misrank the
// report that decides what gets optimised next.
//
// Fixed capacity, insert-only, no allocation and no lock. Reached only from a path that is already
// running an interpreter loop, so a relaxed atomic increment is free by comparison -- but a mutex
// would serialise every PPU thread that fell back, turning a diagnostic into a scalability problem
// on exactly the workload it exists to describe.
//
// Header-only and free of engine dependencies, like spu_failed_block_set, so it is testable
// directly rather than through a model of it.
class cpu_fallback_stats
{
public:
	// Slots. Distinct fallback sites are few -- they are the functions a recompiler backend gave
	// up on -- so this is sized to hold all of them with room to spare rather than to be tuned.
	static constexpr std::size_t k_slots = 512;

	// Probe length. Past this a hit is counted as unattributed instead of walking the table: the
	// report only needs the heaviest sites, and an unbounded probe in a hot path to improve the
	// tail of a diagnostic is the wrong trade.
	static constexpr std::size_t k_max_probe = 8;

	// Address 0 marks an empty slot. No PPU function begins there -- it is the bottom of the
	// guest address space, never mapped as executable code -- so it cannot collide with a real
	// entry. record() rejects it anyway rather than relying on that.
	static constexpr std::uint32_t k_empty = 0;

	// Count one event at `addr`. Safe to call from any thread.
	void record(std::uint32_t addr) noexcept
	{
		record_n(addr, 1);
	}

	// Add `weight` events at `addr`, in one atomic operation.
	//
	// Call sites weight by instructions interpreted, not by entries. A function entered once that
	// then interprets a million instructions costs a million times more than one entered a million
	// times that returns immediately, and a ranking by entry count would put them the wrong way
	// round -- which would point the recompiler work at the wrong function.
	//
	// It also keeps the table small: one entry per fallback SITE rather than per interpreted
	// address, so the distinct-key count stays in the dozens instead of the thousands.
	void record_n(std::uint32_t addr, std::uint64_t weight) noexcept
	{
		if (weight == 0)
		{
			return;
		}

		if (addr == k_empty)
		{
			m_unattributed.fetch_add(weight, std::memory_order_relaxed);
			return;
		}

		std::size_t index = hash(addr);

		for (std::size_t probe = 0; probe < k_max_probe; probe++, index = (index + 1) % k_slots)
		{
			slot& s = m_slots[index];

			std::uint32_t owner = s.addr.load(std::memory_order_acquire);

			if (owner == k_empty)
			{
				// Claim it. On losing the race another thread owns the slot; re-read rather than
				// moving on, because the winner may well have claimed it for this same address --
				// which is the common case when several threads enter the same cold function at
				// once.
				if (!s.addr.compare_exchange_strong(owner, addr,
						std::memory_order_acq_rel, std::memory_order_acquire))
				{
					if (owner != addr)
					{
						continue;
					}
				}

				s.count.fetch_add(weight, std::memory_order_relaxed);
				return;
			}

			if (owner == addr)
			{
				s.count.fetch_add(weight, std::memory_order_relaxed);
				return;
			}
		}

		// Table full along this probe path. Counted, not dropped: a report that silently loses
		// events would understate the fallback and argue against work that is in fact needed.
		m_unattributed.fetch_add(weight, std::memory_order_relaxed);
	}

	// Addresses and counts, heaviest first. Not atomic as a whole -- counts keep moving while this
	// runs -- which is correct for a ranking: the report says what dominates, not an exact tally at
	// an instant nobody can observe anyway.
	std::vector<std::pair<std::uint32_t, std::uint64_t>> snapshot() const
	{
		std::vector<std::pair<std::uint32_t, std::uint64_t>> out;
		out.reserve(k_slots);

		for (const slot& s : m_slots)
		{
			const std::uint32_t addr = s.addr.load(std::memory_order_acquire);

			if (addr == k_empty)
			{
				continue;
			}

			const std::uint64_t count = s.count.load(std::memory_order_relaxed);

			if (count != 0)
			{
				out.emplace_back(addr, count);
			}
		}

		// Address breaks ties so a report is reproducible across runs with identical counts.
		std::sort(out.begin(), out.end(), [](const auto& a, const auto& b)
		{
			return a.second != b.second ? a.second > b.second : a.first < b.first;
		});

		return out;
	}

	// Events that could not be attributed to a slot.
	std::uint64_t unattributed() const noexcept
	{
		return m_unattributed.load(std::memory_order_relaxed);
	}

	// Every event recorded, attributed or not. This is the number a percentage is taken against;
	// summing only the snapshot would flatter the result whenever the table overflowed.
	std::uint64_t total() const noexcept
	{
		std::uint64_t sum = m_unattributed.load(std::memory_order_relaxed);

		for (const slot& s : m_slots)
		{
			sum += s.count.load(std::memory_order_relaxed);
		}

		return sum;
	}

	// Between games. Not safe against concurrent record(); call it with the guest stopped.
	void reset() noexcept
	{
		for (slot& s : m_slots)
		{
			s.addr.store(k_empty, std::memory_order_relaxed);
			s.count.store(0, std::memory_order_relaxed);
		}

		m_unattributed.store(0, std::memory_order_relaxed);
	}

private:
	struct slot
	{
		std::atomic<std::uint32_t> addr{k_empty};
		std::atomic<std::uint64_t> count{0};
	};

	// PPU instructions are 4-byte aligned, so the low two bits carry nothing and hashing without
	// dropping them would leave three quarters of the table unreachable. The multiply is a
	// Fibonacci mix, to keep functions that sit at regular intervals from landing on one slot.
	static std::size_t hash(std::uint32_t addr) noexcept
	{
		return ((addr >> 2) * 2654435761u) % k_slots;
	}

	slot m_slots[k_slots];
	std::atomic<std::uint64_t> m_unattributed{0};
};
