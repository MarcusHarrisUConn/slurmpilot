# Create a Local Parallel Mock SLURM Backend

Convenience constructor wrapping
[MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)`$new(...)`.

## Usage

``` r
mock_slurm_backend(
  root_dir = NULL,
  max_workers = 2L,
  queue_delay = 0,
  mem_limit_mb = NULL,
  time_limit_sec = NULL,
  fault_injection = list(),
  rscript_bin = NULL,
  scrub_secrets = TRUE
)
```

## Arguments

- root_dir:

  Optional directory path for job staging and checkpoints. Defaults to a
  unique temporary directory.

- max_workers:

  Positive integer maximum concurrent worker slots. Default `2L`.

- queue_delay:

  Non-negative numeric queue delay in seconds before starting pending
  chunks. Default `0`.

- mem_limit_mb:

  Optional positive numeric RSS ceiling in MB to actively enforce
  against background worker processes.

- time_limit_sec:

  Optional positive numeric walltime ceiling in seconds to actively
  enforce against background worker processes.

- fault_injection:

  Optional named list with any of `fail_chunks`, `oom_chunks`,
  `timeout_chunks` (integer vectors) and `fail_once` (logical, default
  `TRUE`).

- rscript_bin:

  Optional explicit path to `Rscript`. Defaults to the active R
  installation's `Rscript`.

- scrub_secrets:

  Logical; scrub ambient host credential environment variables before
  spawning workers. Default `TRUE`.

## Value

A
[MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
R6 object.

## Examples

``` r
backend <- mock_slurm_backend(max_workers = 2L)
print(backend)
#> <<MockSlurmBackend>> root=/tmp/RtmpY5vFEo/slurmpilot_mock_17e06c366a6,
#> max_workers=2, jobs=0, active_workers=0
unlink(backend$root_dir, recursive = TRUE)
```
