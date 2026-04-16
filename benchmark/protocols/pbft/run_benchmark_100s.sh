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
echo "===== THROUGHPUT (txn/s per replica, last 5 readings at t=100s) ====="
for i in 0 1 2 3; do
  echo "--- Replica $((i+1)) (bench_server${i}.log) ---"
  grep "txn:" bench_server${i}.log | tail -5
done

echo ""
echo "===== CLIENT/PROXY LATENCY (last 5 readings at t=100s) ====="
grep "req client latency:" bench_client.log | tail -5

echo ""
echo "=== Done ==="
