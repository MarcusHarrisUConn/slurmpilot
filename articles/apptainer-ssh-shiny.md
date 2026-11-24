# Apptainer Packaging, Remote SSH/SLURM & Non-Blocking Shiny Offloading

## Overview

Moving a validated workflow from `MockSlurmBackend` onto a university or
cloud HPC cluster requires reproducible compiled containers,
firewall-friendly SSH orchestration, and (for interactive dashboards)
non-blocking Shiny modules. This vignette walks through each piece
end-to-end.

## 1. Scanning Project Environments & Compiled Toolchains

[`scan_project_env()`](https://marcusharrisphd.com/slurmpilot/reference/scan_project_env.md)
inspects `renv.lock`, `DESCRIPTION`, and R/Rmd/Quarto scripts to build a
unified dependency manifest and infer required compiled toolchains
(`cpp`, `cmdstan`, `rstan`, `tmb`, `jags`, `linear_algebra`, `spatial`,
`http_ssl`, `graphics`, `arrow`):

``` r

library(slurmpilot)

proj_dir <- tempfile("sp_proj_")
dir.create(file.path(proj_dir, "R"), recursive = TRUE)

writeLines(c(
  "Package: multilevelstudy",
  "Version: 0.1.0",
  "Imports: lme4, Rcpp, RTMB, dplyr"
), file.path(proj_dir, "DESCRIPTION"))

writeLines(c(
  "library(cmdstanr)",
  "library(ggplot2)",
  "x <- tibble::tibble(a = 1:3)"
), file.path(proj_dir, "R", "fit_models.R"))

env <- scan_project_env(path = proj_dir)
print(env)
#> 
#> ── slurmpilot HPC Environment Manifest
#> • R version: 4.6.2 (env hash: 66264420552b)
#> • Packages detected: 7 (renv.lock: FALSE)
#> • Compiled toolchains: cpp, cmdstan, tmb, linear_algebra
#> • System apt packages (11): build-essential, ca-certificates, cmake, curl, g++,
#>   gfortran, liblapack-dev, libnlopt-dev, ...
env$toolchains
#> [1] "cpp"            "cmdstan"        "tmb"            "linear_algebra"
names(toolchain_registry())
#>  [1] "cpp"            "cmdstan"        "rstan"          "tmb"           
#>  [5] "jags"           "linear_algebra" "spatial"        "http_ssl"      
#>  [9] "graphics"       "arrow"
```

## 2. Building Reproducible Apptainer `.def` Recipes

[`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md)
generates a deterministic Apptainer/Singularity recipe pinned to
`rocker/r-ver:<r_version>` with minimal `apt-get` system packages, C++17
`Makevars`, single-threaded BLAS/OpenMP defaults (preventing thread
oversubscription across SLURM array jobs), optional CmdStan
installation, and `%test` verification:

``` r

def <- build_apptainer_def(env, r_version = "4.4.1")
print(def)
#> 
#> ── slurmpilot Apptainer Definition
#> • Base image: rocker/r-ver:4.4.1
#> • Packages: 7 | renv restore: FALSE | CmdStan: TRUE
#> • Lines: 59 | Build: `apptainer build slurmpilot_env.sif slurmpilot_env.def`
cat(paste(head(def$recipe, 32L), collapse = "\n"), "\n")
#> Bootstrap: docker
#> From: rocker/r-ver:4.4.1
#> 
#> %labels
#>     GeneratedBy slurmpilot
#>     RVersion 4.4.1
#>     Toolchains cpp,cmdstan,tmb,linear_algebra
#>     EnvHash 66264420552b
#> 
#> %environment
#>     export LC_ALL=C.UTF-8
#>     export LANG=C.UTF-8
#>     export OMP_NUM_THREADS=1
#>     export OPENBLAS_NUM_THREADS=1
#>     export MKL_NUM_THREADS=1
#>     export R_REMOTES_NO_ERRORS_FROM_WARNINGS=true
#>     export CMDSTAN=/opt/cmdstan
#> 
#> %post
#>     set -eu
#>     export DEBIAN_FRONTEND=noninteractive
#>     apt-get update && apt-get install -y --no-install-recommends \
#>         build-essential \
#>         ca-certificates \
#>         cmake \
#>         curl \
#>         g++ \
#>         gfortran \
#>         liblapack-dev \
#>         libnlopt-dev \
#>         libopenblas-dev \
#>         libtbb-dev \
```

## 3. Rendering Hardened SLURM `sbatch` Scripts

[`render_sbatch_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_sbatch_script.md)
renders a POSIX-safe array script with strict defense against newline,
shell metacharacter, and path-traversal injection. Surgical retries
compress target indices cleanly with
[`format_slurm_array_indices()`](https://marcusharrisphd.com/slurmpilot/reference/format_slurm_array_indices.md):

``` r

res <- resource_spec(
  n_tasks = 100L,
  chunk_size = 10L,
  mem_mb = 4096L,
  time_minutes = 60,
  cpus_per_task = 2L,
  partition = "general",
  account = "quant_lab",
  max_concurrent = 5L
)

sb <- render_sbatch_script(
  job_name = "bayesian_dsem",
  resources = res,
  work_dir = "/scratch/researcher/bayesian_dsem",
  container_sif = "/scratch/containers/slurmpilot_env.sif",
  modules = c("apptainer/1.3"),
  mail_type = "FAIL"
)

cat(sb$text)
#> #!/usr/bin/env bash
#> #SBATCH --job-name=bayesian_dsem
#> #SBATCH --array=1-10%5
#> #SBATCH --cpus-per-task=2
#> #SBATCH --mem=4G
#> #SBATCH --time=01:00:00
#> #SBATCH --partition=general
#> #SBATCH --account=quant_lab
#> #SBATCH --output=/scratch/researcher/bayesian_dsem/logs/chunk_%a.out
#> #SBATCH --error=/scratch/researcher/bayesian_dsem/logs/chunk_%a.err
#> #SBATCH --mail-type=FAIL
#> 
#> set -euo pipefail
#> 
#> WORK_DIR='/scratch/researcher/bayesian_dsem'
#> mkdir -p "${WORK_DIR}/logs" "${WORK_DIR}/results" "${WORK_DIR}/status"
#> cd "${WORK_DIR}"
#> 
#> # Load HPC environment modules
#> module load apptainer/1.3
#> 
#> export OMP_NUM_THREADS=2
#> export OPENBLAS_NUM_THREADS=2
#> export MKL_NUM_THREADS=2
#> export SLURMPILOT_WORK_DIR="${WORK_DIR}"
#> export SLURMPILOT_CHUNK_ID="${SLURM_ARRAY_TASK_ID}"
#> export SLURMPILOT_ATTEMPT=1
#> export APPTAINERENV_OMP_NUM_THREADS=2
#> export APPTAINERENV_OPENBLAS_NUM_THREADS=2
#> export APPTAINERENV_MKL_NUM_THREADS=2
#> export APPTAINERENV_SLURMPILOT_WORK_DIR="${WORK_DIR}"
#> export APPTAINERENV_SLURMPILOT_CHUNK_ID="${SLURM_ARRAY_TASK_ID}"
#> export APPTAINERENV_SLURMPILOT_ATTEMPT=1
#> 
#> echo "[slurmpilot] Starting job ${SLURM_JOB_ID:-local} array task ${SLURM_ARRAY_TASK_ID} on $(hostname)"
#> apptainer exec --cleanenv --bind '/scratch/researcher/bayesian_dsem:/scratch/researcher/bayesian_dsem' '/scratch/containers/slurmpilot_env.sif' Rscript "${WORK_DIR}/worker.R" --work-dir "${WORK_DIR}" --chunk-id "${SLURM_ARRAY_TASK_ID}" --attempt "1"
```

## 4. Remote SSH/SLURM Orchestration (`SlurmSshBackend`)

`SlurmSshBackend` communicates exclusively over non-interactive `ssh`
and `scp` (`BatchMode=yes`, explicit `--` option delimiters, dangerous
directive blocking, and bounded exponential backoff for transient
network blips) — avoiding ZeroMQ firewall issues on university clusters.

Use `dry_run = TRUE` to inspect staged files and exact SSH/SCP commands
offline:

``` r

tmp_stage <- tempfile("sp_ssh_stage_")
ssh_be <- slurm_ssh_backend(
  host = "hpc.university.edu",
  user = "researcher",
  remote_dir = "/scratch/researcher/slurmpilot",
  local_stage_dir = tmp_stage,
  partition = "general",
  container_sif = "/scratch/containers/slurmpilot_env.sif",
  ssh_max_retries = 3L,
  dry_run = TRUE
)

dry_job <- slurm_submit(
  backend = ssh_be,
  fun = function(x) mean(stats::rnorm(x$n)),
  args_list = lapply(1:10, function(i) list(n = 500)),
  resources = resource_spec(n_tasks = 10L, chunk_size = 5L, mem_mb = 2048L, time_minutes = 15),
  name = "dry_run_demo"
)

print(dry_job)
#> 
#> ── slurmpilot Job Handle
#> • Job: dry_run_demo (id=slurm_20261124_210639_6e02f7b9, backend=slurm_ssh)
#> • Chunks: 2 (10 tasks, 2G, 00:15:00)
#> • Workspace:
#>   /tmp/RtmpHVpnUp/sp_ssh_stage_1dc41ada8a9/slurm_20261124_210639_6e02f7b9
names(dry_job$meta$dry_run_commands)
#> [1] "mkdir"  "scp"    "sbatch"
```

`slurmpilot` also exports hardened SLURM output parsers covering stepped
array expressions, per-CPU/per-node memory suffixes (`Mc`/`Mn`), and
`.batch` sub-step consolidation:

``` r

parse_slurm_array_spec("1-10:2,15%4")
#> [1]  1  3  5  7  9 15
parse_slurm_mem(c("1024K", "2.5G", "0.5T", "100Mc", "200Mn"))
#> [1]      1   2560 524288    100    200

parse_squeue_output("482910_1|RUNNING|04:20|cn042|None\n482910_[2-4]|PENDING|0:00||(Priority)")
#> # A tibble: 4 × 6
#>   slurm_job_id chunk_id state   elapsed_sec node  reason    
#>   <chr>           <int> <chr>         <dbl> <chr> <chr>     
#> 1 482910              1 RUNNING         260 cn042 None      
#> 2 482910              2 PENDING           0 NA    (Priority)
#> 3 482910              3 PENDING           0 NA    (Priority)
#> 4 482910              4 PENDING           0 NA    (Priority)

parse_sacct_output(paste(
  "482910_1|COMPLETED|00:08:15||0:0",
  "482910_1.batch|COMPLETED|00:08:15|1536M|0:0",
  "482910_2|OUT_OF_MEMORY|00:02:10||0:125",
  "482910_2.batch|OUT_OF_MEMORY|00:02:10|4Gc|0:125",
  sep = "\n"
))
#> # A tibble: 2 × 6
#>   slurm_job_id chunk_id state         elapsed_sec peak_rss_mb exit_code
#>   <chr>           <int> <chr>               <dbl>       <dbl>     <int>
#> 1 482910              1 COMPLETED             495        1536         0
#> 2 482910              2 OUT_OF_MEMORY         130        4096       253

unlink(c(proj_dir, tmp_stage), recursive = TRUE)
```

## 5. Non-Blocking `bslib` / Shiny Offload Modules

Drop `mod_hpc_submit_ui/server` and `mod_hpc_monitor_ui/server` into any
`bslib` app to run micro-pilots and array jobs in background OS
processes while keeping the Shiny UI responsive at all times:

``` r

library(shiny)
library(bslib)
library(slurmpilot)

ui <- page_fluid(
  theme = bs_theme(version = 5, bootswatch = "flatly"),
  mod_hpc_submit_ui("submit", show_fault_toggle = TRUE),
  mod_hpc_monitor_ui("monitor")
)

server <- function(input, output, session) {
  backend <- mock_slurm_backend(max_workers = 2L)

  submit <- mod_hpc_submit_server(
    id = "submit",
    backend = backend,
    fun = function(x) mean(stats::rnorm(x$n)),
    args_builder = function(n_tasks) lapply(seq_len(n_tasks), function(i) list(n = 1000))
  )

  monitor <- mod_hpc_monitor_server(
    id = "monitor",
    job = submit$job,
    auto_collect = TRUE,
    simplify = TRUE
  )
}

shinyApp(ui, server)
```

Run the bundled interactive demo studio via
[`slurmpilot::run_demo_app()`](https://marcusharrisphd.com/slurmpilot/reference/run_demo_app.md).
