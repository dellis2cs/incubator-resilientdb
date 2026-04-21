# Benchmark Script Differences: `run_benchmark_100s.sh` vs `start_performance.sh`

## Overview

Two benchmark scripts exist in this directory. They test the same server binary but
drive load in fundamentally different ways. This matters especially for Two-Phase Commit
(2PC), where the distinction causes `start_performance.sh` to fail entirely.

---

## `run_benchmark_100s.sh` — External Client Benchmark

**How it works:**

1. Builds `kv_service` (the normal server binary) and `kv_service_tools` (the client).
2. Starts 4 replica servers + 1 proxy node (`node5`, acting as the client-facing proxy).
3. Runs `kv_service_tools` in a loop for 100 seconds, sending `SET foo bar` requests to
   the proxy over the network.
4. The proxy forwards each request into the consensus layer as a new user transaction.

**Request flow:**

```
kv_service_tools → proxy (node5) → Coordinator (Replica 1)
                                        ↓ TYPE_2PC_PREPARE (broadcast)
                                   All 4 Replicas
                                        ↓ TYPE_2PC_VOTE (unicast to coordinator)
                                   Coordinator
                                        ↓ TYPE_2PC_COMMIT (broadcast)
                                   All 4 Replicas → execute → reply to proxy → reply to client
```

**What is measured:**

- End-to-end committed transactions per second (our custom `[2PC Throughput]` logger).
- Per-5-second windowed stats via the built-in `txn:` counter.
- Client-observed round-trip latency (`req client latency:` in the proxy log).

**Works with 2PC:** Yes. This is the correct script for 2PC benchmarking.

---

## `start_performance.sh` — Internal Performance Mode Benchmark

**How it works:**

1. Builds `kv_server_performance` (a separate binary, not `kv_service`).
2. That binary calls `config->RunningPerformance(true)` and `SetupPerformanceDataFunc(...)`.
3. Each replica auto-generates its own synthetic KV transactions internally — no external
   client is involved.
4. Transactions are injected directly into the consensus pipeline, bypassing the normal
   client network reception path.

**What is measured:**

- Raw consensus throughput in an idealized, zero-network-client-overhead scenario.
- This is what produced the ~24,000 ops/sec numbers in Assignment 1 (PBFT).

---

## Why `start_performance.sh` Does Not Work Well with 2PC

### Problem 1: Port conflicts

`start_performance.sh` does not kill existing `kv_service` processes. If
`run_benchmark_100s.sh` was run first, ports 10001–10005 are still bound and
`kv_server_performance` crashes immediately with:

```
bind TcpSocket error: Address already in use (errno: 98)
Assertion `socket_->Listen(...) == 0' failed.
```

Fix: `killall -9 kv_service kv_server_performance 2>/dev/null` before running.

### Problem 2: Performance mode bypasses the 2PC entry point

In normal mode, a client request arrives at the proxy, gets forwarded to the primary
replica, and enters the consensus layer through `Commitment::ProcessNewRequest`. That is
where our 2PC logic begins — `two_phase_commit_->InitiateCommit(...)` is called there.

In performance mode (`RunningPerformance(true)`), each server *self-proposes* batches
internally. The transaction generation loop runs at full CPU speed and injects requests
far faster than 2PC can process them, because:

- 2PC requires a full network round-trip for votes before each commit.
- The internal generator does not wait for the previous batch to commit before proposing
  the next one.
- Vote tracking state (`votes_` map in `TwoPhaseCommit`) fills up with overlapping
  sequence numbers and the coordinator can never accumulate a full quorum cleanly.

The result is extremely low throughput (~2.4 txn/s over the full uptime) and then the
replicas go idle because the pipeline is congested.

### Problem 3: The numbers are not comparable

Even if performance mode could be made to work with 2PC, the resulting throughput numbers
would not be a fair comparison to the PBFT Assignment 1 numbers:

| Dimension            | `run_benchmark_100s.sh` (2PC)   | `start_performance.sh` (PBFT A1) |
|----------------------|---------------------------------|----------------------------------|
| Transaction source   | External client over TCP        | Internally generated, no network |
| Client latency       | Measured (0.121 ms)             | Not applicable                   |
| Network overhead     | Full round-trip included        | Eliminated                       |
| Protocol overhead    | Full 3-phase 2PC round-trips    | PBFT 3-phase, pipelined batches  |
| What it measures     | Real end-to-end throughput      | Peak consensus engine throughput |

---

## 2PC Benchmark Results (100-second run)

| Metric                         | Value                   |
|-------------------------------|-------------------------|
| Total transactions committed   | 828 (all 4 replicas)    |
| Coordinator throughput         | 8.31 txn/s              |
| Avg participant throughput     | 8.32 txn/s              |
| Steady-state window rate       | ~164–168 txn/s per window (820–840 txn / 5 s) |
| Avg client latency             | 0.1210 ms (0.000121 s)  |
| Benchmark duration             | ~100 seconds            |
| Replicas                       | 4 replicas + 1 proxy    |

All 4 replicas committed the same 828 transactions, confirming protocol correctness.
