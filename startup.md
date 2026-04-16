- docker start d9d51ed7c116
- docker exec -it d9d51ed7c116 /bin/bash

- killall -9 kv_server_performance 2>/dev/null 
- killall -9 kv_service 2>/dev/null

- ./benchmark/protocols/pbft/run_benchmark_100s.shh