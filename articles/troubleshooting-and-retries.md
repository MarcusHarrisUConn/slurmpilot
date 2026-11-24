# Troubleshooting, Adaptive Retries & Reproducible Parallel RNG

## Overview

Large HPC array jobs fail in predictable ways: a handful of outlier
tasks hit `OUT_OF_MEMORY` or `TIMEOUT`, shared network filesystems
suffer partial writes, or naive parallel seeding silently correlates
Monte Carlo replications across compute nodes. This vignette
demonstrates how `slurmpilot` handles all three failure modes
deterministically.

## 1. Adaptive Escalation for OOM and Timeout Failures

When `slurm_retry(job, adaptive = TRUE)` (the default) inspects failed
array chunks:

- Chunks in `OUT_OF_MEMORY` automatically trigger `--mem` escalation
  (default `1.5x`, bounded by `max_mem_mb`).
- Chunks in `TIMEOUT` automatically trigger `--time` escalation (default
  `1.5x`, bounded by `max_time_minutes`).
- Already-completed chunks are **never re-executed**; their atomic
  checkpoints remain untouched on disk.
- Every escalation event is logged in per-chunk retry provenance via
  `slurm_retry_history(job)`.

Let us simulate a 4-chunk job where chunk 2 suffers an `OUT_OF_MEMORY`
kill and chunk 4 suffers a `TIMEOUT` kill on attempt 1:

``` r

library(slurmpilot)

tmp_root <- tempfile("sp_troubleshoot_")
be <- mock_slurm_backend(root_dir = tmp_root, max_workers = 2L)

res <- resource_spec(n_tasks = 8L, chunk_size = 2L, mem_mb = 512L, time_minutes = 10)
job <- slurm_submit(
  backend = be,
  fun = function(x) x^3,
  args_list = as.list(seq_len(8L)),
  resources = res,
  name = "adaptive_demo",
  seed = 2026L,
  fault_injection = list(oom_chunks = 2L, timeout_chunks = 4L, fail_once = TRUE)
)

st1 <- slurm_wait(job, timeout = 30, poll_interval = 0.05)
st1$chunks[, c("chunk_id", "state", "attempt", "checkpoint_exists")]
#> # A tibble: 4 × 4
#>   chunk_id state         attempt checkpoint_exists
#>      <int> <chr>           <int> <lgl>            
#> 1        1 COMPLETED           1 TRUE             
#> 2        2 OUT_OF_MEMORY       1 FALSE            
#> 3        3 COMPLETED           1 TRUE             
#> 4        4 TIMEOUT             1 FALSE
```

Calling `slurm_retry(job)` with zero manual flags detects BOTH failure
causes, escalates `--mem` (512 MB -\> 768 MB) and `--time` (10 min -\>
15 min), and resubmits only chunks 2 and 4:

``` r

job <- slurm_retry(job)
st2 <- slurm_wait(job, timeout = 30, poll_interval = 0.05)
print(st2)
#> 
#> ── slurmpilot Job Status: adaptive_demo [COMPLETED]
#> • Progress: 4/4 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 73.8 MB | Cumulative walltime: 0.15s

# Inspect recorded retry provenance
slurm_retry_history(job)
#> # A tibble: 2 × 9
#>   retry_round timestamp             chunk_id trigger_state old_mem_mb new_mem_mb
#>         <int> <chr>                    <int> <chr>              <int>      <int>
#> 1           1 2026-11-24T19:33:54.…        2 OUT_OF_MEMORY        512        768
#> 2           1 2026-11-24T19:33:54.…        4 TIMEOUT              512        768
#> # ℹ 3 more variables: old_time_sec <int>, new_time_sec <int>, adaptive <lgl>

# Verify completed results in exact 1..8 order
slurm_collect(job, simplify = TRUE)
#> [1]   1   8  27  64 125 216 343 512
```

## 2. Detecting and Healing Corrupted Checkpoints via SHA-256

Every completed chunk writes `results/chunk_XXXX.rds` atomically (temp
file + [`file.rename()`](https://rdrr.io/r/base/files.html)) paired with
a cryptographic SHA-256 sidecar (`results/chunk_XXXX.rds.sha256`).
[`verify_checkpoint()`](https://marcusharrisphd.com/slurmpilot/reference/verify_checkpoint.md)
and
[`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md)
validate every digest before deserialization so silent Lustre/NFS
truncation or bit rot can never poison downstream inference:

``` r

cp2 <- file.path(job$local_dir, "results", "chunk_0002.rds")
verify_checkpoint(cp2, require_sidecar = TRUE)$ok
#> [1] TRUE

# Simulate a single corrupted byte on disk
raw_bytes <- readBin(cp2, what = "raw", n = file.info(cp2)$size)
raw_bytes[[length(raw_bytes)]] <- xor(raw_bytes[[length(raw_bytes)]], as.raw(0xFF))
writeBin(raw_bytes, cp2)

# Integrity verifier catches the mismatch immediately
chk <- verify_checkpoint(cp2)
chk$ok
#> [1] FALSE
chk$reason
#> [1] "SHA-256 sidecar mismatch (expected b53ffc03e0f6da0dead4f6f76fbd9fb0e7e91cb91833830bb647b05be98312d7, got b9ef2d1dcf916c23ff9fea3a1a7cd464939c70d9d739815a25210dda21a1f23a)."

# Surgical retry of chunk 2 heals the corrupted checkpoint cleanly
job <- slurm_retry(job, chunks = 2L, adaptive = FALSE)
st3 <- slurm_wait(job, timeout = 30, poll_interval = 0.05)
verify_checkpoint(cp2, require_sidecar = TRUE)$ok
#> [1] TRUE
slurm_collect(job, simplify = TRUE)
#> [1]   1   8  27  64 125 216 343 512
```

## 3. Reproducible Independent Parallel RNG (`L'Ecuyer-CMRG`)

Seeding parallel array jobs with naive consecutive integers
(`set.seed(seed + i)`) does not guarantee non-overlapping random-number
streams. `slurmpilot`’s standalone `worker.R` initializes base R’s
`L'Ecuyer-CMRG` generator and uses
[`parallel::nextRNGStream()`](https://rdrr.io/r/parallel/RngStream.html)
($`2^{127}`$ draws between chunks) combined with
[`parallel::nextRNGSubStream()`](https://rdrr.io/r/parallel/RngStream.html)
($`2^{76}`$ draws between tasks within a chunk).

You can inspect or reproduce any `(seed, chunk_id, task_pos)` stream
directly via
[`slurmpilot_rng_stream()`](https://marcusharrisphd.com/slurmpilot/reference/slurmpilot_rng_stream.md)
without mutating your global `.Random.seed`:

``` r

s_c1_t1 <- slurmpilot_rng_stream(2026L, chunk_id = 1L, task_pos = 1L)
s_c2_t1 <- slurmpilot_rng_stream(2026L, chunk_id = 2L, task_pos = 1L)
!identical(s_c1_t1, s_c2_t1)
#> [1] TRUE

rng_job <- slurm_submit(
  backend = be,
  fun = function(i) list(kind = RNGkind()[[1L]], draws = stats::rnorm(200)),
  args_list = as.list(seq_len(6L)),
  resources = resource_spec(n_tasks = 6L, chunk_size = 2L),
  name = "rng_verify",
  seed = 2026L
)
slurm_wait(rng_job, timeout = 30, poll_interval = 0.05)
#> 
#> ── slurmpilot Job Status: rng_verify [COMPLETED]
#> • Progress: 3/3 chunks (100%) | running=0, pending=0, failed=0, oom=0,
#>   timeout=0, cancelled=0
#> • Peak RSS max: 73.1 MB | Cumulative walltime: 0.11s
rng_out <- slurm_collect(rng_job)

# All workers used L'Ecuyer-CMRG and produced empirically uncorrelated streams
all(vapply(rng_out, function(x) x$kind == "L'Ecuyer-CMRG", logical(1L)))
#> [1] TRUE
cor_mat <- stats::cor(do.call(cbind, lapply(rng_out, `[[`, "draws")))
diag(cor_mat) <- 0
round(max(abs(cor_mat)), 3)
#> [1] 0.144

unlink(tmp_root, recursive = TRUE)
```

## 4. Production HPC Pre-Flight Checklist

Before submitting a multi-thousand-task job to a university or cloud
SLURM cluster:

1.  **Audit globals & closures:** Run
    `inspect_job_globals(fun, args_list, globals, packages)` to catch
    \>50 MB captured closure frames or missing helper symbols.
2.  **Profile empirically:** Run
    `pilot_run(..., sample_method = "stratified")` with 3–5 trials and
    check `pilot$summary$is_heavy_tailed`.
3.  **Choose chunk strategy:** Use `strategy = "lpt"` in
    [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
    whenever task costs are heterogeneous.
4.  **Dry-run SSH/SLURM staging:** Verify the rendered `submit.sbatch`
    and Apptainer `.def` recipe with
    `slurm_ssh_backend(..., dry_run = TRUE)`.
5.  **Preserve checkpoints:** Keep `results/` and `status/` on shared
    cluster scratch so
    [`slurm_retry()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_retry.md)
    recovers partial failures cleanly with SHA-256 verification.
