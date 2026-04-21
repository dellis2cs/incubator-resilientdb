/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

#pragma once

#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <set>

#include "platform/config/resdb_config.h"
#include "platform/consensus/ordering/pbft/message_manager.h"
#include "platform/networkstrate/replica_communicator.h"
#include "platform/networkstrate/server_comm.h"
#include "platform/proto/resdb.pb.h"

namespace resdb {

// TwoPhaseCommit implements the 2PC commit protocol layered on top of
// ResilientDB.  The replica that the proxy forwards a transaction to acts as
// the coordinator; all other replicas (and the coordinator itself when it
// receives its own broadcast) act as participants.
//
// Phase 1 – Prepare/Voting:
//   Coordinator broadcasts TYPE_2PC_PREPARE.
//   Each participant (including coordinator-as-participant) replies with
//   TYPE_2PC_VOTE.
//
// Phase 2 – Commit/Decision:
//   After receiving votes from all replicas the coordinator broadcasts
//   TYPE_2PC_COMMIT.  Each replica then triggers execution through
//   the existing MessageManager execution pipeline.
class TwoPhaseCommit {
 public:
  TwoPhaseCommit(const ResDBConfig& config, MessageManager* message_manager,
                 ReplicaCommunicator* replica_communicator);

  // Coordinator: given the validated, seq-assigned request, broadcast
  // TYPE_2PC_PREPARE to all replicas (including self).
  int InitiateCommit(std::unique_ptr<Request> request);

  // All replicas: receive TYPE_2PC_PREPARE.
  // Registers transaction data in MessageManager and sends TYPE_2PC_VOTE to
  // the coordinator.
  int ProcessPrepare(std::unique_ptr<Context> context,
                     std::unique_ptr<Request> request);

  // Coordinator: receive TYPE_2PC_VOTE.
  // When votes from all replicas have been collected, broadcasts
  // TYPE_2PC_COMMIT to all replicas.
  int ProcessVote(std::unique_ptr<Context> context,
                  std::unique_ptr<Request> request);

  // All replicas: receive TYPE_2PC_COMMIT.
  // Triggers execution of the transaction through the existing pipeline and
  // logs throughput metrics.
  int ProcessCommit(std::unique_ptr<Context> context,
                    std::unique_ptr<Request> request);

 private:
  ResDBConfig config_;
  MessageManager* message_manager_;
  ReplicaCommunicator* replica_communicator_;

  // Vote tracking: seq -> set of sender_ids that have voted
  std::mutex vote_mutex_;
  std::map<uint64_t, std::set<int32_t>> votes_;

  // Throughput measurement
  std::mutex tp_mutex_;
  std::atomic<int64_t> coordinator_txn_count_{0};
  std::atomic<int64_t> participant_txn_count_{0};
  bool coordinator_started_ = false;
  bool participant_started_ = false;
  std::chrono::steady_clock::time_point coordinator_start_time_;
  std::chrono::steady_clock::time_point participant_start_time_;
};

}  // namespace resdb
