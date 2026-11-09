# Benchmark run 2026-11-09T13:01:30+00:00 (c901dc2)

Mac17,9 (Apple M5 Pro, 24 GB), macOS 27.2 (26B123), git version 2.54.0, power ac, Low Power Mode off

| Scenario | Metric | Median | p90 | Unit | Runs |
|---|---|---|---|---|---|
| diff-switch | core.diffParse | 0.005 | 0.005 | ms | 9 |
| diff-switch | diff.switch | 63.476 | 68.698 | ms | 9 |
| diff-switch | footprint | 194.800 | 194.800 | MB | 1 |
| graph-scroll | footprint_all_loaded | 101.700 | 101.700 | MB | 1 |
| graph-scroll | graph.firstRows | 707.500 | 707.500 | ms | 1 |
| graph-scroll | page_append | 0.340 | 0.360 | ms | 5 |
| graph-scroll | row_draw | 0.009 | 0.016 | ms | 9900 |
| graph-scroll | scroll_step | 1.680 | 2.040 | ms | 400 |
| idle-0tabs | cpu_percent | 0.000 | 0.000 | % | 1 |
| idle-0tabs | footprint | 32.000 | 32.000 | MB | 1 |
| idle-0tabs | idle_wakeups_per_s | 9.000 | 9.000 | 1/s | 1 |
| idle-0tabs | threads | 4.000 | 4.000 | count | 1 |
| idle-1tabs | cpu_percent | 0.000 | 0.000 | % | 1 |
| idle-1tabs | footprint | 71.000 | 71.000 | MB | 1 |
| idle-1tabs | idle_wakeups_per_s | 1.000 | 1.000 | 1/s | 1 |
| idle-1tabs | threads | 3.000 | 3.000 | count | 1 |
| idle-5tabs | cpu_percent | 0.158 | 2.400 | % | 1 |
| idle-5tabs | footprint | 70.000 | 70.000 | MB | 1 |
| idle-5tabs | idle_wakeups_per_s | 5.267 | 5.267 | 1/s | 1 |
| idle-5tabs | threads | 15.000 | 15.000 | count | 1 |
| large-diff | core.diffParse | 2.377 | 2.453 | ms | 10 |
| large-diff | diff.switch | 194.018 | 197.330 | ms | 10 |
| large-diff | footprint | 1215.100 | 1215.100 | MB | 1 |
| launch-cold | first_window | 236.000 | 253.800 | ms | 5 |
| launch-warm | first_window | 264.600 | 274.300 | ms | 10 |
| many-files | core.status | 0.059 | 0.061 | ms | 10 |
| many-files | graph.firstPage | 88.785 | 93.273 | ms | 10 |
| many-files | repo.open | 134.673 | 137.360 | ms | 10 |
| micro | diff-parse-50k | 0.957 | 1.069 | ms | 30 |
| micro | lane-layout-100k | 49.423 | 49.721 | ms | 7 |
| micro | lane-layout-10k | 5.573 | 5.711 | ms | 7 |
| micro | patch-build-50k | 8.480 | 8.657 | ms | 30 |
| micro | status-parse-100k | 8.608 | 8.668 | ms | 30 |
| multi-tab | footprint | 109.900 | 109.900 | MB | 1 |
| multi-tab | tab.switch | 16.715 | 27.785 | ms | 60 |
| open-close-loop | footprint.after10 | 246.600 | 246.600 | MB | 1 |
| open-close-loop | footprint.first | 149.900 | 149.900 | MB | 1 |
| open-close-loop | footprint.last | 530.500 | 530.500 | MB | 1 |
| open-close-loop | footprint.settled | 410.800 | 410.800 | MB | 1 |
| open-repo | core.status | 0.003 | 0.004 | ms | 10 |
| open-repo | graph.firstPage | 127.003 | 128.350 | ms | 10 |
| open-repo | repo.open | 169.868 | 181.315 | ms | 10 |
