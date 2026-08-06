# WP-12 benchmark analysis — /Users/pavan/Documents/AI Projects/Torrentino/Measurements/wp12/bench-20260806-112438.csv

| cell | backend | median wall (s) | 95% CI | p95 | median cpu-s | median RSS (MB) | fb | thermal |
|---|---|---|---|---|---|---|---|---|
| 1g/1024KiB | cpu | 2.2458 | 2.2387–2.2513 | 2.2568 | 2.2398 | 24.6 | 0 | ok |
| 1g/1024KiB | libtorrent | 0.8893 | 0.8795–0.8914 | 0.8958 | 0.8965 | 1033.0 | 0 | ok |
| 1g/1024KiB | metal | 4.6577 | 4.6317–4.6820 | 4.7326 | 4.2348 | 1651.3 | 0 | ok |
| 1g/16384KiB | cpu | 2.2625 | 2.2447–2.2764 | 2.2953 | 2.2595 | 24.6 | 0 | ok |
| 1g/16384KiB | libtorrent | 0.8944 | 0.8837–0.8989 | 0.9005 | 0.8967 | 1033.5 | 0 | ok |
| 1g/16384KiB | metal | 8.6520 | 8.6269–8.6771 | 8.7016 | 4.4215 | 1593.9 | 0 | ok |
| 1g/4096KiB | cpu | 2.2221 | 2.1393–2.2450 | 2.2539 | 2.2090 | 24.6 | 0 | ok |
| 1g/4096KiB | libtorrent | 0.8099 | 0.8006–0.8225 | 0.8408 | 0.8062 | 1033.0 | 0 | ok |
| 1g/4096KiB | metal | 5.2013 | 5.1210–5.5250 | 5.9598 | 4.0171 | 1576.7 | 0 | ok |
| 4g/1024KiB | cpu | 9.0127 | 8.9572–9.0489 | 9.0845 | 8.9981 | 72.6 | 0 | ok |
| 4g/1024KiB | libtorrent | 3.6754 | 3.6524–3.6876 | 3.6939 | 3.7069 | 4105.2 | 0 | ok |
| 4g/1024KiB | metal | 18.6012 | 18.5199–18.6455 | 18.6691 | 17.0824 | 1688.7 | 0 | ok |
| 4g/16384KiB | cpu | 8.9069 | 8.8734–8.9749 | 9.0285 | 8.8523 | 72.3 | 0 | ok |
| 4g/16384KiB | libtorrent | 3.6462 | 3.6171–3.6732 | 3.7033 | 3.6438 | 4105.5 | 0 | ok |
| 4g/16384KiB | metal | 34.3577 | 34.2728–34.4537 | 34.5783 | 17.4647 | 2350.2 | 0 | ok |
| 4g/4096KiB | cpu | 8.9691 | 8.9275–9.0170 | 9.0605 | 8.9191 | 72.4 | 0 | ok |
| 4g/4096KiB | libtorrent | 3.2601 | 3.2403–3.3229 | 3.3948 | 3.2562 | 4105.1 | 0 | ok |
| 4g/4096KiB | metal | 21.6808 | 21.6108–21.7573 | 21.9021 | 17.0815 | 1616.5 | 0 | ok |
| 64m/1024KiB | cpu | 0.1294 | 0.1282–0.1366 | 0.1407 | 0.1289 | 9.9 | 0 | ok |
| 64m/1024KiB | libtorrent | 0.0558 | 0.0551–0.0562 | 0.0565 | 0.0563 | 72.9 | 0 | ok |
| 64m/1024KiB | metal | 0.3562 | 0.3529–0.3624 | 0.3708 | 0.2701 | 356.6 | 0 | ok |
| 64m/16384KiB | cpu | 0.1416 | 0.1398–0.1421 | 0.1423 | 0.1419 | 9.6 | 0 | ok |
| 64m/16384KiB | libtorrent | 0.0559 | 0.0550–0.0564 | 0.0572 | 0.0559 | 73.0 | 0 | ok |
| 64m/16384KiB | metal | 1.2885 | 1.2775–1.3253 | 1.3876 | 0.2751 | 369.6 | 0 | ok |
| 64m/256KiB | cpu | 0.1407 | 0.1397–0.1413 | 0.1416 | 0.1409 | 9.8 | 0 | ok |
| 64m/256KiB | libtorrent | 0.0565 | 0.0560–0.0571 | 0.0580 | 0.0577 | 73.0 | 0 | ok |
| 64m/256KiB | metal | 0.3137 | 0.3077–0.3324 | 0.3529 | 0.2735 | 353.8 | 0 | ok |
| 64m/4096KiB | cpu | 0.1400 | 0.1393–0.1407 | 0.1414 | 0.1398 | 9.7 | 0 | ok |
| 64m/4096KiB | libtorrent | 0.0569 | 0.0552–0.0603 | 0.0673 | 0.0563 | 73.0 | 0 | ok |
| 64m/4096KiB | metal | 0.5393 | 0.5354–0.5491 | 0.5691 | 0.2802 | 343.4 | 0 | ok |

## §12.7 gate verdicts (measured on this machine)

| gate | verdict | evidence |
|---|---|---|
| G6 | below-threshold | 1g/1024KiB: 0.48x at 1g/1024KiB (<4 GiB eligibility line; informational) |
| G7 | below-threshold | 1g/1024KiB: p95 ratio CPU/Metal = 0.477 (informational) |
| G8 | below-threshold | 1g/1024KiB: Metal/CPU peak RSS ratio = 66.99 (informational) |
| G9 | below-threshold | 1g/1024KiB: Metal cpu-s/MiB 4.0386 vs CPU 2.1360 (informational) |
| G10 | PASS | 1g/1024KiB: thermal evidence OK (no throttling observed) |
| G6 | below-threshold | 1g/16384KiB: 0.26x at 1g/16384KiB (<4 GiB eligibility line; informational) |
| G7 | below-threshold | 1g/16384KiB: p95 ratio CPU/Metal = 0.264 (informational) |
| G8 | below-threshold | 1g/16384KiB: Metal/CPU peak RSS ratio = 64.66 (informational) |
| G9 | below-threshold | 1g/16384KiB: Metal cpu-s/MiB 4.2167 vs CPU 2.1548 (informational) |
| G10 | PASS | 1g/16384KiB: thermal evidence OK (no throttling observed) |
| G6 | below-threshold | 1g/4096KiB: 0.43x at 1g/4096KiB (<4 GiB eligibility line; informational) |
| G7 | below-threshold | 1g/4096KiB: p95 ratio CPU/Metal = 0.378 (informational) |
| G8 | below-threshold | 1g/4096KiB: Metal/CPU peak RSS ratio = 64.09 (informational) |
| G9 | below-threshold | 1g/4096KiB: Metal cpu-s/MiB 3.8310 vs CPU 2.1067 (informational) |
| G10 | PASS | 1g/4096KiB: thermal evidence OK (no throttling observed) |
| G6 | FAIL | 4g/1024KiB: Metal 18.6012s vs CPU 9.0127s = 0.48x (>=1.20 required on >=4 GiB workloads) |
| G7 | FAIL | 4g/1024KiB: p95 ratio CPU/Metal = 0.487 (>=0.95 required) |
| G8 | FAIL | 4g/1024KiB: Metal/CPU peak RSS ratio = 23.26 (<10 required) |
| G9 | FAIL | 4g/1024KiB: Metal cpu-s/MiB 16.2910 vs CPU 8.5813 |
| G10 | PASS | 4g/1024KiB: thermal evidence OK (no throttling observed) |
| G6 | FAIL | 4g/16384KiB: Metal 34.3577s vs CPU 8.9069s = 0.26x (>=1.20 required on >=4 GiB workloads) |
| G7 | FAIL | 4g/16384KiB: p95 ratio CPU/Metal = 0.261 (>=0.95 required) |
| G8 | FAIL | 4g/16384KiB: Metal/CPU peak RSS ratio = 32.48 (<10 required) |
| G9 | FAIL | 4g/16384KiB: Metal cpu-s/MiB 16.6557 vs CPU 8.4422 |
| G10 | PASS | 4g/16384KiB: thermal evidence OK (no throttling observed) |
| G6 | FAIL | 4g/4096KiB: Metal 21.6808s vs CPU 8.9691s = 0.41x (>=1.20 required on >=4 GiB workloads) |
| G7 | FAIL | 4g/4096KiB: p95 ratio CPU/Metal = 0.414 (>=0.95 required) |
| G8 | FAIL | 4g/4096KiB: Metal/CPU peak RSS ratio = 22.33 (<10 required) |
| G9 | FAIL | 4g/4096KiB: Metal cpu-s/MiB 16.2901 vs CPU 8.5059 |
| G10 | PASS | 4g/4096KiB: thermal evidence OK (no throttling observed) |
| G6 | below-threshold | 64m/1024KiB: 0.36x at 64m/1024KiB (<4 GiB eligibility line; informational) |
| G7 | below-threshold | 64m/1024KiB: p95 ratio CPU/Metal = 0.379 (informational) |
| G8 | below-threshold | 64m/1024KiB: Metal/CPU peak RSS ratio = 36.20 (informational) |
| G9 | below-threshold | 64m/1024KiB: Metal cpu-s/MiB 0.2575 vs CPU 0.1229 (informational) |
| G10 | PASS | 64m/1024KiB: thermal evidence OK (no throttling observed) |
| G6 | below-threshold | 64m/16384KiB: 0.11x at 64m/16384KiB (<4 GiB eligibility line; informational) |
| G7 | below-threshold | 64m/16384KiB: p95 ratio CPU/Metal = 0.103 (informational) |
| G8 | below-threshold | 64m/16384KiB: Metal/CPU peak RSS ratio = 38.30 (informational) |
| G9 | below-threshold | 64m/16384KiB: Metal cpu-s/MiB 0.2623 vs CPU 0.1354 (informational) |
| G10 | PASS | 64m/16384KiB: thermal evidence OK (no throttling observed) |
| G6 | below-threshold | 64m/256KiB: 0.45x at 64m/256KiB (<4 GiB eligibility line; informational) |
| G7 | below-threshold | 64m/256KiB: p95 ratio CPU/Metal = 0.401 (informational) |
| G8 | below-threshold | 64m/256KiB: Metal/CPU peak RSS ratio = 36.28 (informational) |
| G9 | below-threshold | 64m/256KiB: Metal cpu-s/MiB 0.2608 vs CPU 0.1344 (informational) |
| G10 | PASS | 64m/256KiB: thermal evidence OK (no throttling observed) |
| G6 | below-threshold | 64m/4096KiB: 0.26x at 64m/4096KiB (<4 GiB eligibility line; informational) |
| G7 | below-threshold | 64m/4096KiB: p95 ratio CPU/Metal = 0.248 (informational) |
| G8 | below-threshold | 64m/4096KiB: Metal/CPU peak RSS ratio = 35.40 (informational) |
| G9 | below-threshold | 64m/4096KiB: Metal cpu-s/MiB 0.2672 vs CPU 0.1333 (informational) |
| G10 | PASS | 64m/4096KiB: thermal evidence OK (no throttling observed) |

Gates G1–G5, G11 are covered by test_wp12_01/03/04 (QA scripts). G6 is measured only where a >=4 GiB workload fit on this disk; if every cell is below the eligibility line the plan's decision rule cannot be satisfied and the outcome is REJECT_METAL (with measured evidence, not N/A).
