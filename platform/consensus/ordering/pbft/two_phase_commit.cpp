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

#include "platform/consensus/ordering/pbft/two_phase_commit.h"

#include <glog/logging.h>

#include "platform/consensus/ordering/pbft/transaction_utils.h"

namespace resdb {

TwoPhaseCommit::TwoPhaseCommit(const ResDBConfig& config,
                               MessageManager* message_manager,
                               ReplicaCommunicator* replica_communicator)
    : config_(config),
      message_manager_(message_manager),
      replica_communicator_(replica_communicator) {}

// ─── Phase 1: Coordinator initiates ──────────────────────────────────────────

int TwoPhaseCommit::InitiateCommit(std::unique_ptr<Request> request) {
  {
    std::lock_guard<std::mutex> lk(tp_mutex_);
    if (!coordinator_started_) {
      coordinator_started_ = true;
      coordinator_start_time_ = std::chrono::steady_clock::now();
    }
  }

  request->set_type(Request::TYPE_2PC_PREPARE);
  LOG(INFO) << "[2PC Coordinator] InitiateCommit seq=" << request->seq()
            << " proxy_id=" << request->proxy_id();
  replica_communicator_->BroadCast(*request);
  return 0;
}

// ─── Phase 1: Participants respond ───────────────────────────────────────────

int TwoPhaseCommit::ProcessPrepare(std::unique_ptr<Context> context,
                                   std::unique_ptr<Request> request) {
  uint64_t seq = request->seq();
  int32_t coordinator_id = request->primary_id();
  LOG(INFO) << "[2PC Participant id=" << config_.GetSelfInfo().id()
            << "] ProcessPrepare seq=" << seq
            << " coordinator=" << coordinator_id;

  // Register the transaction data in the MessageManager collector as a
  // TYPE_PRE_PREPARE (is_main_request=true path).  This stores the payload so
  // that when TYPE_2PC_COMMIT arrives the executor has the data it needs.
  auto pre_prepare = NewRequest(Request::TYPE_PRE_PREPARE, *request,
                                request->sender_id());
  message_manager_->AddConsensusMsg(context->signature, std::move(pre_prepare));

  // Send TYPE_2PC_VOTE back to the coordinator.
  auto vote =
      NewRequest(Request::TYPE_2PC_VOTE, *request, config_.GetSelfInfo().id());
  replica_communicator_->SendMessage(*vote, coordinator_id);
  return 0;
}

// ─── Phase 2: Coordinator collects votes and decides ─────────────────────────

int TwoPhaseCommit::ProcessVote(std::unique_ptr<Context> context,
                                std::unique_ptr<Request> request) {
  uint64_t seq = request->seq();
  int32_t sender = request->sender_id();
  LOG(INFO) << "[2PC Coordinator] ProcessVote seq=" << seq
            << " from=" << sender;

  bool all_voted = false;
  {
    std::lock_guard<std::mutex> lk(vote_mutex_);
    votes_[seq].insert(sender);
    if (votes_[seq].size() >= config_.GetReplicaNum()) {
      all_voted = true;
      votes_.erase(seq);
    }
  }

  if (all_voted) {
    auto commit_msg = NewRequest(Request::TYPE_2PC_COMMIT, *request,
                                 config_.GetSelfInfo().id());
    LOG(INFO) << "[2PC Coordinator] All votes received, broadcasting COMMIT"
              << " seq=" << seq;
    replica_communicator_->BroadCast(*commit_msg);

    // Coordinator throughput measurement
    int64_t count = ++coordinator_txn_count_;
    auto now = std::chrono::steady_clock::now();
    double elapsed_sec =
        std::chrono::duration<double>(now - coordinator_start_time_).count();
    if (elapsed_sec > 0) {
      LOG(ERROR) << "[2PC Throughput][Coordinator] committed=" << count
                 << " elapsed_s=" << elapsed_sec
                 << " throughput=" << (count / elapsed_sec) << " txn/s";
    }
  }
  return 0;
}

// ─── Phase 2: All replicas commit ────────────────────────────────────────────

int TwoPhaseCommit::ProcessCommit(std::unique_ptr<Context> context,
                                  std::unique_ptr<Request> request) {
  uint64_t seq = request->seq();
  LOG(INFO) << "[2PC Replica id=" << config_.GetSelfInfo().id()
            << "] ProcessCommit seq=" << seq;

  // Push a TYPE_2PC_COMMIT message through AddConsensusMsg.
  // MayConsensusChangeStatus handles TYPE_2PC_COMMIT by jumping the collector
  // directly from READY_PREPARE to READY_EXECUTE, which triggers Commit() and
  // hands the transaction off to the TransactionExecutor.
  auto commit_msg = NewRequest(Request::TYPE_2PC_COMMIT, *request,
                               request->sender_id());
  message_manager_->AddConsensusMsg(context->signature, std::move(commit_msg));

  // Participant throughput measurement
  {
    std::lock_guard<std::mutex> lk(tp_mutex_);
    if (!participant_started_) {
      participant_started_ = true;
      participant_start_time_ = std::chrono::steady_clock::now();
    }
  }
  int64_t count = ++participant_txn_count_;
  auto now = std::chrono::steady_clock::now();
  double elapsed_sec =
      std::chrono::duration<double>(now - participant_start_time_).count();
  if (elapsed_sec > 0) {
    LOG(ERROR) << "[2PC Throughput][Participant id="
               << config_.GetSelfInfo().id() << "] committed=" << count
               << " elapsed_s=" << elapsed_sec
               << " throughput=" << (count / elapsed_sec) << " txn/s";
  }
  return 0;
}

}  // namespace resdb
