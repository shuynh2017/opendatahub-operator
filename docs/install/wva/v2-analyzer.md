
# V2 (Token-based Capacity Analyzer)
[NOTE: this is still needed to be verified - don't include in official doc yet]
V2 (token-based capacity) analyzer uses the following definitions and calculations for scaling decisions.

## Supply
### Replica Level: KV_token_capacity
`KV_token_capacity` is the **total** KV-cache memory allocated to the replica, in tokens:

```
KV_token_capacity = num_gpu_blocks × block_size
```
Where:
  - num_gpu_blocks = number of GPU memory blocks allocated for KV-cache
  - block_size = tokens per block (e.g., 16)
  - Both values read from `vllm:cache_config_info` metric


V2 calculates supply and demand in terms of tokens which should reflect the supply/demand more accurately comparing to usage percentage in V1.

### Replica Level: per_replica_capacity
`KV_token_capacity` is the **total** capacity for a replica; however, to apply safety margins and to consider for bottlenecks,  `per_replica_capacity` is needed to be defined. `per_replica_capacity` will be used in scaling decisions:

```
per_replica_capacity = min(memory_ceiling, compute_ceiling)
```

Where:
```
memory_ceiling = KV_token_capacity × kvCacheThreshold

```
- `kvCacheThreshold` is configurable in WVA configmap, default to 0.80.

- Intuitively, `memory_ceiling` defines for example only 80% is usable, 20% reserved, prevents running the cache at 100% (risk of OOM).

`compute_ceiling` = tokens the GPU can actually process before compute (not memory) becomes the bottleneck:
  - Estimated from queue saturation behavior when `vllm:num_requests_waiting ≥ queueLengthThreshold` where `queueLengthThreshold` is configurable in WVA configmap, default to 5.
 - Or derived from deployment's `--max-num-seqs`, `--max-num-batched-tokens`, etc.
  - Matters for long-generation workloads where GPU compute saturates before memory fills
  - Intuitively, for a replica, if there are none or few requests waiting, then its capacity is `memory_ceiling`; but if there are many requests waiting, then its capacity is estimated to reflect the waiting requests. This implies WVA dynamically adjusts per replica capacity based on load currently on the replica to better reflect its capacity.
  
### Model Level: TotalAnticipatedSupply
WVA takes `pending` replicas into account when calculating the supply. This reflects more accurately the supply, avoiding over provisioning.

`TotalAnticipatedSupply` for a **model** is the sum of total anticipated supply of **all its variants** which include `pending` replicas.

This implies WVA has model-level view of the supply where a model can have variants with different roles, or different hardware selection.

## Demand
Demand is the total amount of work the model currently needs to serve, measured in KV-cache tokens. Specifically, how many KV-cache tokens do we need to handle all the work currently in flight - both what's running now and what's queued up waiting to run?

### Replica Level: tokens_in_use
```
 tokens_in_use = kv_cache_usage × KV_token_capacity
```
  Where:
  - `kv_cache_usage` = utilization fraction from `vllm:kv_cache_usage_perc` metric - a value between 0 and 1 (e.g., 0.73 = 73% of cache is occupied)

 ### Replica Level: local_queue_tokens

`local_queue_tokens` is the tokens for requests queued at the replica level. Note that this is **not exactly** the number of tokens for requests queued since average input tokens per request is used as shown below:

```
  local_queue_tokens = num_requests_waiting × avg_input_tokens
```

Where:
- `num_requests_waiting` = count of requests in the local queue
  - Read from `vllm:num_requests_waiting` metric
- `avg_input_tokens` = average input tokens per request
  - Calculated from `vllm:request_prompt_tokens_sum` / `vllm:request_prompt_tokens_count`

### EPP Level: scheduler_queue_tokens

`scheduler_queue_tokens` is the tokens for requests queued upstream in the EPP flow-control layer - requests that haven't reached any pod yet - this is the proactive part of demand that V1 doesn't see. Note that this is **not exactly** the number of tokens for requests queued since average input tokens per request is used as shown below.

```
  scheduler_queue_tokens = upstream_queue_size × avg_input_tokens × (1 - prefix_cache_hit_rate)
```
Where:
  - `upstream_queue_size` = count of requests queued in EPP
    - Read from `inference_extension_flow_control_queue_size` metric (EPP)
    - Or derived from `inference_extension_flow_control_queue_bytes` / avg request size
  - `avg_input_tokens` = same as `local_queue_tokens` above
  - `prefix_cache_hit_rate` = fraction of input tokens saved by prefix caching
    - Calculated from `vllm:prefix_cache_hits` / `vllm:prefix_cache_queries` 
    - Optional - if not available, assume 0 (no discount)

`(1 - prefix_cache_hit_rate)` is the **discount factor**, explained as:
  - With prefix caching, common prompt prefixes are reused
  - A request with 1000 input tokens might only need 200 new KV-cache tokens (800 cached)
  - Hit rate of 0.60 means on average 60% of input tokens don't consume new cache
  - Effective tokens = 1000 × (1 - 0.60) = 400 tokens
  
Intuitively, WVA takes requests queued at EPP layer into account when calculating the demand, and uses prefix cache hit rate for more accurate estimation.

### Model Level: TotalDemand
Total demand for a model is defined as:

`TotalDemand` = `tokens_in_use` + `local_queue_tokens` + `scheduler_queue_tokens`

## Scaling Decisions
The scaling decisions are as follows:
- If `TotalDemand` == `TotalAnticipatedSupply` this is considered saturated, so if `TotalDemand` > 85% `TotalAnticipatedSupply` then scale up, and if  `TotalDemand` < 70% `TotalAnticipatedSupply` then scale down. The 85%, 70% are defined by configurations `scaleUpThreshold`, `scaleDownBoundary`, respectively. The range between `scaleUpThreshold` and `scaleDownBoundary` can be adjusted, for example, can be increased to prevent rapid scaling up and down.
  
## Comparing V1 (Percentage-based) vs V2 (Token-based Capacity)
Key differences:
- In general, V2 calculates supply and demand in terms of tokens which should reflect the supply/demand more accurately comparing to usage percentage in V1.
- For replica capacity, V2 takes into account the number of queued requests which should result into more accurate supply where as V1 only sees the token in used (as fraction of usage percentage).
- V2 takes pending replicas into account when calculating the supply. This reflects more accurately the supply, avoiding over provisioning. In V1, pending replicas are not taken into account and the algorithm doesn't scale up when there are pending replicas. As the result, in V2, for bursting workload, the model scales up **multiple replicas** quickly to meet the demand earlier comparing to V1.
- For replica level demand, V2 takes into account the number of queued requests which should result into more accurate demand.
- V2 takes into account the number of queued requests and prefix hit cache rate at EPP level. This should result in proactively scaling before backlog becomes latency.