# Render a Self-Contained SLURM `sbatch` Array Submission Script

Generates a POSIX/bash-safe SLURM batch script configured from a
`slurmpilot_resources` plan (with strict defense against `#SBATCH`
newline, shell metacharacter, path traversal, and CLI flag injection).
Supports surgical array index overrides, Apptainer container execution,
environment modules, and structured logging.

## Usage

``` r
render_sbatch_script(
  job_name,
  resources,
  work_dir,
  worker_script = "worker.R",
  array_indices = NULL,
  attempt = 1L,
  container_sif = NULL,
  container_binds = character(),
  modules = character(),
  env_vars = list(),
  log_dir = "logs",
  mail_user = NULL,
  mail_type = NULL,
  extra_sbatch = character(),
  output_path = NULL
)
```

## Arguments

- job_name:

  Character SLURM `--job-name` (validated against control
  characters/metacharacters and sanitized).

- resources:

  A `slurmpilot_resources` object from
  [`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md)
  or
  [`resource_spec()`](https://marcusharrisphd.com/slurmpilot/reference/resource_spec.md).

- work_dir:

  Remote or local working directory containing `payload.rds`,
  `chunks.rds`, and `worker_script`.

- worker_script:

  Filename or path of the worker script (default `"worker.R"`).

- array_indices:

  Optional integer vector overriding `--array` for surgical retries of
  specific failed chunks.

- attempt:

  Positive integer submission attempt number passed to `worker.R` via
  `SLURMPILOT_ATTEMPT`. Default `1L`.

- container_sif:

  Optional path to an Apptainer/Singularity `.sif` image. When supplied,
  wraps `Rscript` inside `apptainer exec --cleanenv`.

- container_binds:

  Optional character vector of Apptainer `--bind` mount specifications
  (e.g. `"/scratch:/scratch"`). `work_dir` is always bound automatically
  when `container_sif` is set.

- modules:

  Optional character vector of HPC environment modules to load via
  `module load`.

- env_vars:

  Optional named list or character vector of extra environment variables
  exported in the job script.

- log_dir:

  Relative subdirectory inside `work_dir` for SLURM stdout/stderr logs.
  Default `"logs"`.

- mail_user:

  Optional email address for `--mail-user`.

- mail_type:

  Optional SLURM `--mail-type` (e.g., `"END,FAIL"`).

- extra_sbatch:

  Optional character vector of extra `#SBATCH` flags (without leading
  `#SBATCH`; `--wrap` and shell metacharacters are forbidden).

- output_path:

  Optional file path to write the rendered `.sbatch` script.

## Value

An S3 object of class `"slurmpilot_sbatch"` with `script` (character
vector of lines), `text` (single string), `path`, `job_name`,
`array_spec`, and `resources`.

## See also

[`estimate_resources()`](https://marcusharrisphd.com/slurmpilot/reference/estimate_resources.md),
[`build_apptainer_def()`](https://marcusharrisphd.com/slurmpilot/reference/build_apptainer_def.md),
[`render_worker_script()`](https://marcusharrisphd.com/slurmpilot/reference/render_worker_script.md)

## Examples

``` r
res <- resource_spec(n_tasks = 40, chunk_size = 4, mem_mb = 2048, time_minutes = 20)
sb <- render_sbatch_script("mc_power", res, work_dir = "/scratch/user/mc_power")
cat(sb$text)
#> #!/usr/bin/env bash
#> #SBATCH --job-name=mc_power
#> #SBATCH --array=1-10
#> #SBATCH --cpus-per-task=1
#> #SBATCH --mem=2G
#> #SBATCH --time=00:20:00
#> #SBATCH --output=/scratch/user/mc_power/logs/chunk_%a.out
#> #SBATCH --error=/scratch/user/mc_power/logs/chunk_%a.err
#> 
#> set -euo pipefail
#> 
#> WORK_DIR='/scratch/user/mc_power'
#> mkdir -p "${WORK_DIR}/logs" "${WORK_DIR}/results" "${WORK_DIR}/status"
#> cd "${WORK_DIR}"
#> 
#> export OMP_NUM_THREADS=1
#> export OPENBLAS_NUM_THREADS=1
#> export MKL_NUM_THREADS=1
#> export SLURMPILOT_WORK_DIR="${WORK_DIR}"
#> export SLURMPILOT_CHUNK_ID="${SLURM_ARRAY_TASK_ID}"
#> export SLURMPILOT_ATTEMPT=1
#> 
#> echo "[slurmpilot] Starting job ${SLURM_JOB_ID:-local} array task ${SLURM_ARRAY_TASK_ID} on $(hostname)"
#> Rscript "${WORK_DIR}/worker.R" --work-dir "${WORK_DIR}" --chunk-id "${SLURM_ARRAY_TASK_ID}" --attempt "1"
```
