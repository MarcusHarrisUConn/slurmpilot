# Example 1: End-to-End Micro-Pilot, Adaptive Retry, and Autopilot Workflow
# Runs 100% locally using <= 2 worker processes and cleans up temporary files.

library(slurmpilot)

# Define a reproducible Monte Carlo Welch t-test power workload
tasks <- lapply(seq_len(12L), function(i) {
  list(task_id = i, n = 50L, delta = 0.4, reps = 60L)
})

power_worker <- function(cfg) {
  rejects <- replicate(cfg$reps, {
    stats::t.test(stats::rnorm(cfg$n, cfg$delta), stats::rnorm(cfg$n, 0))$p.value < 0.05
  })
  data.frame(task_id = cfg$task_id, power = mean(rejects))
}

# Pre-submit closure & bundle audit
audit <- inspect_job_globals(power_worker, args_list = tasks)
print(audit)

# Run local parallel Mock SLURM backend with one-time simulated OOM on chunk 2
tmp_root <- tempfile("slurmpilot_ex1_")
on.exit(unlink(tmp_root, recursive = TRUE), add = TRUE)
backend <- mock_slurm_backend(root_dir = tmp_root, max_workers = 2L)

run <- slurm_autopilot(
  fun = power_worker,
  args_list = tasks,
  backend = backend,
  n_pilot = 2L,
  max_chunk_size = 4L,
  seed = 2026L,
  auto_retry = 1L,
  simplify = TRUE,
  poll_interval = 0.05,
  fault_injection = list(oom_chunks = 2L, fail_once = TRUE)
)

print(run)
print(slurm_retry_history(run$job))
cat(sprintf("Mean empirical power across %d tasks: %.1f%%\n", nrow(run$results), 100 * mean(run$results$power)))
