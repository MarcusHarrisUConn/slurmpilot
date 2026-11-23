# Example 2: Heterogeneous LPT Load Balancing, Apptainer Packaging & SSH Dry-Run
# Runs 100% offline with zero network calls and cleans up temporary files.

library(slurmpilot)

# 1. Heterogeneous task weights (e.g., varying sample size or MCMC iterations)
weights <- c(120, 110, 95, 80, 40, 35, 20, 15, 10, 10, 8, 5)
lpt_plan <- plan_chunks(length(weights), chunk_size = 3L, strategy = "lpt", task_weights = weights)
print(lpt_plan)

# 2. Scan compiled dependencies and emit Apptainer .def recipe
env <- scan_project_env(extra_packages = c("lme4", "Rcpp", "cmdstanr", "RTMB"))
def <- build_apptainer_def(env, r_version = "4.4.1")
print(def)

# 3. Stage a dry-run SSH/SLURM bundle with LPT resource specification
tmp_stage <- tempfile("slurmpilot_ex2_")
on.exit(unlink(tmp_stage, recursive = TRUE), add = TRUE)

res <- resource_spec(
  n_tasks = length(weights),
  chunk_size = 3L,
  mem_mb = 4096L,
  time_minutes = 45,
  cpus_per_task = 2L,
  partition = "general",
  strategy = "lpt",
  task_weights = weights
)

ssh_be <- slurm_ssh_backend(
  host = "hpc.example.edu",
  user = "researcher",
  remote_dir = "/scratch/researcher/slurmpilot_demo",
  local_stage_dir = tmp_stage,
  container_sif = "/scratch/containers/slurmpilot_env.sif",
  dry_run = TRUE
)

job <- slurm_submit(
  backend = ssh_be,
  fun = function(x) sum(seq_len(x)),
  args_list = as.list(as.integer(weights)),
  resources = res,
  name = "lpt_dry_run"
)
print(job)
cat("Staged sbatch preview:\n")
cat(paste(head(readLines(file.path(job$local_dir, "submit.sbatch")), 15L), collapse = "\n"), "\n")
