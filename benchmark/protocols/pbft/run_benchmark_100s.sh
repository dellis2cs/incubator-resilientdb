#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# 100-second PBFT benchmark:
#   - 4 replicas + 1 client/proxy (kv_service)
#   - kv_service_tools drives continuous SET load
#   - Throughput (txn/s) sampled every 5s at each replica
#   - Latency (req client latency) sampled every 5s at proxy
#   - Final metrics printed at t=100s

set -e

WORK_PATH=$PWD
SERVER_PATH=./bazel-bin/service/kv/kv_service
CLIENT_TOOLS_PATH=./bazel-bin/service/tools/kv/api_tools/kv_service_tools
SERVER_CONFIG=service/tools/config/server/server.config
CLIENT_CONFIG=service/tools/config/interface/service.config
CERT_PATH=${WORK_PATH}/service/tools/data/cert/

echo "=== Building kv_service and kv_service_tools ==="
bazel build //service/kv:kv_service //service/tools/kv/api_tools:kv_service_tools $@

echo "=== Killing any existing instances ==="
killall -9 kv_service 2>/dev/null || true

echo "=== Starting 4 replicas + 1 proxy ==="
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node1.key.pri $CERT_PATH/cert_1.cert > bench_server0.log &
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node2.key.pri $CERT_PATH/cert_2.cert > bench_server1.log &
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node3.key.pri $CERT_PATH/cert_3.cert > bench_server2.log &
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node4.key.pri $CERT_PATH/cert_4.cert > bench_server3.log &
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node5.key.pri $CERT_PATH/cert_5.cert > bench_client.log &

echo "Waiting 15 seconds for nodes to start and complete heartbeats..."
sleep 15

echo "=== Starting continuous load via kv_service_tools (100 seconds) ==="
SECONDS=0
while [ $SECONDS -lt 100 ]; do
  $CLIENT_TOOLS_PATH $CLIENT_CONFIG set foo bar &>/dev/null
done

echo ""
echo "===== 2PC THROUGHPUT SUMMARY ====="

echo ""
echo "--- Coordinator (Replica 1) ---"
grep "\[2PC Throughput\]\[Coordinator\]" bench_server0.log | tail -1

echo ""
echo "--- Participants ---"
for i in 0 1 2 3; do
  grep "\[2PC Throughput\]\[Participant" bench_server${i}.log | tail -1
done

echo ""
echo "===== 2PC THROUGHPUT (txn/s) — last 5 active windows per replica ====="
for i in 0 1 2 3; do
  echo "--- Replica $((i+1)) ---"
  grep "txn:" bench_server${i}.log | grep -v "txn:0" | tail -5
done

echo ""
echo "===== LATENCY (last 5 readings) ====="
grep "req client latency:" bench_client.log | tail -5

echo ""
echo "===== FINAL NUMBERS FOR REPORT ====="

# Coordinator throughput from our 2PC logger
COORD_LINE=$(grep "\[2PC Throughput\]\[Coordinator\]" bench_server0.log | tail -1)
COORD_TP=$(echo "$COORD_LINE" | grep -oP 'throughput=\K[0-9.]+')
echo "Coordinator throughput : ${COORD_TP} txn/s"

# Average participant throughput
TOTAL=0
COUNT=0
for i in 0 1 2 3; do
  TP=$(grep "\[2PC Throughput\]\[Participant" bench_server${i}.log | tail -1 | grep -oP 'throughput=\K[0-9.]+')
  if [ -n "$TP" ]; then
    TOTAL=$(awk "BEGIN {print $TOTAL + $TP}")
    COUNT=$((COUNT + 1))
  fi
done
if [ $COUNT -gt 0 ]; then
  AVG_TP=$(awk "BEGIN {printf \"%.4f\", $TOTAL / $COUNT}")
  echo "Avg participant throughput: ${AVG_TP} txn/s  (across $COUNT participants)"
fi

# Average latency
AVG_LAT=$(grep "req client latency:" bench_client.log \
  | grep -oP 'latency:\K[0-9.]+' \
  | awk '{s+=$1; c++} END {if(c>0) printf "%.6f", s/c}')
echo "Avg client latency     : ${AVG_LAT} s  ($(awk "BEGIN {printf \"%.4f\", ${AVG_LAT:-0} * 1000}") ms)"

echo ""
echo "=== Done ==="
