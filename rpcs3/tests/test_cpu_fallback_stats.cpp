#include <gtest/gtest.h>

#include "Emu/CPU/CPUFallbackStats.h"

#include <cstdint>
#include <thread>
#include <vector>

// cpu_fallback_stats decides what the recompiler work in this fork targets, so the properties that
// make its ranking trustworthy are pinned here rather than assumed.
//
// What each case rejects, rather than merely exercising:
//
//   AlignedAddressesSpreadAcrossTable is the hash detector. PPU instructions are 4-byte aligned;
//   drop the ">> 2" from hash() and three quarters of the table becomes unreachable, so half a
//   table's worth of distinct addresses starts overflowing and this fails.
//
//   OverflowIsCountedNotDropped is the honesty constraint. A report that silently loses events
//   understates the fallback and argues against work that is in fact needed, so attributed plus
//   unattributed must equal what was recorded, always.
//
//   ConcurrentRecordsLoseNothing is the one that rejects a plausible-looking table. Several PPU
//   threads entering the same cold function at once all race for the same empty slot; drop the
//   "owner != addr" recheck after a failed compare_exchange and the losers walk on to another
//   slot, splitting one address across several entries and misranking the report.

TEST(CPUFallbackStats, RankingIsByCount)
{
	cpu_fallback_stats stats;

	for (int i = 0; i < 5; i++) stats.record(0x10000);
	for (int i = 0; i < 9; i++) stats.record(0x20000);
	stats.record(0x30000);

	const auto top = stats.snapshot();

	ASSERT_EQ(top.size(), 3u);
	EXPECT_EQ(top[0].first, 0x20000u);
	EXPECT_EQ(top[0].second, 9u);
	EXPECT_EQ(top[1].first, 0x10000u);
	EXPECT_EQ(top[1].second, 5u);
	EXPECT_EQ(top[2].first, 0x30000u);
	EXPECT_EQ(stats.total(), 15u);
	EXPECT_EQ(stats.unattributed(), 0u);
}

TEST(CPUFallbackStats, TiesBreakOnAddressSoReportsAreReproducible)
{
	cpu_fallback_stats stats;

	stats.record(0x20000);
	stats.record(0x10000);

	const auto top = stats.snapshot();

	ASSERT_EQ(top.size(), 2u);
	EXPECT_EQ(top[0].first, 0x10000u);
	EXPECT_EQ(top[1].first, 0x20000u);
}

TEST(CPUFallbackStats, AlignedAddressesSpreadAcrossTable)
{
	cpu_fallback_stats stats;

	const std::uint32_t count = cpu_fallback_stats::k_slots / 2;

	for (std::uint32_t i = 0; i < count; i++)
	{
		stats.record(0x10000 + i * 4);
	}

	EXPECT_EQ(stats.snapshot().size(), count);
	EXPECT_EQ(stats.unattributed(), 0u);
}

TEST(CPUFallbackStats, OverflowIsCountedNotDropped)
{
	cpu_fallback_stats stats;

	const std::uint64_t recorded = cpu_fallback_stats::k_slots * 8;

	for (std::uint64_t i = 0; i < recorded; i++)
	{
		stats.record(0x40000 + static_cast<std::uint32_t>(i) * 4);
	}

	std::uint64_t attributed = 0;
	for (const auto& entry : stats.snapshot())
	{
		attributed += entry.second;
	}

	EXPECT_GT(stats.unattributed(), 0u);
	EXPECT_EQ(attributed + stats.unattributed(), recorded);
	EXPECT_EQ(stats.total(), recorded);
}

TEST(CPUFallbackStats, AddressZeroNeverClaimsASlot)
{
	// 0 is the empty-slot sentinel. A slot claimed for it would be invisible forever.
	cpu_fallback_stats stats;

	for (int i = 0; i < 100; i++)
	{
		stats.record(0);
	}

	EXPECT_TRUE(stats.snapshot().empty());
	EXPECT_EQ(stats.unattributed(), 100u);
	EXPECT_EQ(stats.total(), 100u);
}

TEST(CPUFallbackStats, ConcurrentRecordsLoseNothing)
{
	cpu_fallback_stats stats;

	constexpr int threads = 8;
	constexpr int per_thread = 20000;

	std::vector<std::thread> workers;
	workers.reserve(threads);

	for (int t = 0; t < threads; t++)
	{
		workers.emplace_back([&stats]
		{
			for (int i = 0; i < per_thread; i++)
			{
				stats.record(0x50000 + (i % 4) * 4);
			}
		});
	}

	for (auto& worker : workers)
	{
		worker.join();
	}

	const auto top = stats.snapshot();

	EXPECT_EQ(stats.total(), std::uint64_t{threads} * per_thread);
	EXPECT_EQ(stats.unattributed(), 0u);
	ASSERT_EQ(top.size(), 4u);

	for (const auto& entry : top)
	{
		EXPECT_EQ(entry.second, std::uint64_t{threads} * per_thread / 4);
	}
}

TEST(CPUFallbackStats, WeightIsInterpretedInstructionsNotEntries)
{
	// A function entered once that then interprets a thousand instructions costs a thousand times
	// more than one entered fifty times that returns immediately. Ranking by entry count puts them
	// the wrong way round and points the recompiler work at the wrong function.
	cpu_fallback_stats stats;

	stats.record_n(0x70000, 1000);

	for (int i = 0; i < 50; i++)
	{
		stats.record_n(0x80000, 1);
	}

	const auto top = stats.snapshot();

	ASSERT_EQ(top.size(), 2u);
	EXPECT_EQ(top[0].first, 0x70000u);
	EXPECT_EQ(top[0].second, 1000u);
	EXPECT_EQ(stats.total(), 1050u);
}

TEST(CPUFallbackStats, ZeroWeightDoesNotClaimASlot)
{
	// The fallback path can be entered and find a compiled function without interpreting anything.
	// That is not a fallback and must not occupy a slot or appear in the report.
	cpu_fallback_stats stats;

	stats.record_n(0x90000, 0);

	EXPECT_TRUE(stats.snapshot().empty());
	EXPECT_EQ(stats.total(), 0u);
}

TEST(CPUFallbackStats, ResetClearsCountsAndSlots)
{
	cpu_fallback_stats stats;

	stats.record(0x60000);
	stats.record(0);
	stats.reset();

	EXPECT_TRUE(stats.snapshot().empty());
	EXPECT_EQ(stats.total(), 0u);
	EXPECT_EQ(stats.unattributed(), 0u);
}
