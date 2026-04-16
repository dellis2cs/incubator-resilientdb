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

killall -9 kv_server_performance 2>/dev/null

SERVER_PATH=./bazel-bin/benchmark/protocols/pbft/kv_server_performance
SERVER_CONFIG=service/tools/config/server/server.config
WORK_PATH=$PWD
CERT_PATH=${WORK_PATH}/service/tools/data/cert/

bazel build //benchmark/protocols/pbft:kv_server_performance //benchmark/protocols/pbft:kv_service_tools $@

nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node1.key.pri $CERT_PATH/cert_1.cert > bench_server0.log &
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node2.key.pri $CERT_PATH/cert_2.cert > bench_server1.log &
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node3.key.pri $CERT_PATH/cert_3.cert > bench_server2.log &
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node4.key.pri $CERT_PATH/cert_4.cert > bench_server3.log &

# Node 5 acts as the client/proxy; RunningPerformance(true) drives load from here
nohup $SERVER_PATH $SERVER_CONFIG $CERT_PATH/node5.key.pri $CERT_PATH/cert_5.cert > bench_client.log &

echo "Waiting 10 seconds for nodes to start and complete heartbeats..."
sleep 10

# Send a single trigger request to node 5 to call StartEval() and fill the request queue
echo "Triggering benchmark via kv_service_tools..."
./bazel-bin/benchmark/protocols/pbft/kv_service_tools service/tools/config/interface/service.config

echo "Benchmark started. Waiting 90 more seconds to collect metrics..."
sleep 90

echo ""
echo "===== THROUGHPUT (txn/s per replica, last 5 readings) ====="
for i in 0 1 2 3; do
  echo "--- bench_server${i}.log ---"
  grep "txn:" bench_server${i}.log | tail -5
done

echo ""
echo "===== CLIENT/PROXY LATENCY (last 5 readings) ====="
grep "req client latency:" bench_client.log | tail -5
