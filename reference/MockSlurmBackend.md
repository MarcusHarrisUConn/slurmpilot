# Local Parallel Mock SLURM Scheduler Backend

Full-featured local SLURM array simulator that executes the exact
generated `worker.R` script in isolated background R processes via
`processx`, throttled by a configurable concurrency queue
(`max_workers`). Supports live OS RSS polling via `ps`, disk-based
atomic chunk checkpoints, real or simulated `FAILED` / `OUT_OF_MEMORY` /
`TIMEOUT` / `CANCELLED` states, surgical retry of failed chunks,
cancellation, log inspection, and ordered result collection — enabling
100% offline development and testing on a laptop.

## Super class

[`SlurmBackend`](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.md)
-\> `MockSlurmBackend`

## Public fields

- `name`:

  Backend identifier (`"mock_slurm"`).

- `root_dir`:

  Root directory storing simulated job workspaces.

- `max_workers`:

  Maximum concurrent background R worker processes.

- `queue_delay`:

  Optional simulated queue wait delay in seconds before dispatching
  pending chunks.

- `mem_limit_mb`:

  Optional enforced RSS limit in MB (exceeding triggers
  `OUT_OF_MEMORY`).

- `time_limit_sec`:

  Optional enforced walltime limit in seconds (exceeding triggers
  `TIMEOUT`).

- `fault_injection`:

  Default fault injection specification (`fail_chunks`, `oom_chunks`,
  `timeout_chunks`, `fail_once`).

- `rscript_bin`:

  Path to the `Rscript` executable used for worker processes.

## Methods

### Public methods

- [`MockSlurmBackend$new()`](#method-MockSlurmBackend-initialize)

- [`MockSlurmBackend$set_fault_injection()`](#method-MockSlurmBackend-set_fault_injection)

- [`MockSlurmBackend$submit()`](#method-MockSlurmBackend-submit)

- [`MockSlurmBackend$status()`](#method-MockSlurmBackend-status)

- [`MockSlurmBackend$retry()`](#method-MockSlurmBackend-retry)

- [`MockSlurmBackend$cancel()`](#method-MockSlurmBackend-cancel)

- [`MockSlurmBackend$logs()`](#method-MockSlurmBackend-logs)

- [`MockSlurmBackend$collect()`](#method-MockSlurmBackend-collect)

- [`MockSlurmBackend$shutdown()`](#method-MockSlurmBackend-shutdown)

- [`MockSlurmBackend$print()`](#method-MockSlurmBackend-print)

- [`MockSlurmBackend$clone()`](#method-MockSlurmBackend-clone)

Inherited methods

- [`SlurmBackend$cleanup()`](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.html#method-cleanup)
- [`SlurmBackend$wait()`](https://marcusharrisphd.com/slurmpilot/reference/SlurmBackend.html#method-wait)

------------------------------------------------------------------------

### `MockSlurmBackend$new()`

Create a new `MockSlurmBackend`.

#### Usage

    MockSlurmBackend$new(
      root_dir = NULL,
      max_workers = 2L,
      queue_delay = 0,
      mem_limit_mb = NULL,
      time_limit_sec = NULL,
      fault_injection = list(),
      rscript_bin = NULL
    )

#### Arguments

- `root_dir`:

  Optional directory path for job staging and checkpoints. Defaults to a
  unique temporary directory.

- `max_workers`:

  Positive integer maximum concurrent worker slots. Default `2L`.

- `queue_delay`:

  Non-negative numeric queue delay in seconds before starting pending
  chunks. Default `0`.

- `mem_limit_mb`:

  Optional positive numeric RSS ceiling in MB to actively enforce
  against background worker processes.

- `time_limit_sec`:

  Optional positive numeric walltime ceiling in seconds to actively
  enforce against background worker processes.

- `fault_injection`:

  Optional named list with any of `fail_chunks`, `oom_chunks`,
  `timeout_chunks` (integer vectors) and `fail_once` (logical, default
  `TRUE`).

- `rscript_bin`:

  Optional explicit path to `Rscript`. Defaults to the active R
  installation's `Rscript`.

------------------------------------------------------------------------

### `MockSlurmBackend$set_fault_injection()`

Update default fault injection rules for future submissions.

#### Usage

    MockSlurmBackend$set_fault_injection(
      fail_chunks = integer(),
      oom_chunks = integer(),
      timeout_chunks = integer(),
      fail_once = TRUE
    )

#### Arguments

- `fail_chunks`:

  Integer vector of chunk IDs to fail.

- `oom_chunks`:

  Integer vector of chunk IDs to OOM-kill.

- `timeout_chunks`:

  Integer vector of chunk IDs to timeout-kill.

- `fail_once`:

  Logical; if `TRUE` (default), faults trigger only on attempt 1.

------------------------------------------------------------------------

### `MockSlurmBackend$submit()`

Submit a `slurmpilot_job_spec` to the local mock scheduler.

#### Usage

    MockSlurmBackend$submit(job_spec, fault_injection = NULL, ...)

#### Arguments

- `job_spec`:

  A `slurmpilot_job_spec` object.

- `fault_injection`:

  Optional per-job fault injection override.

- `...`:

  Unused.

#### Returns

A `slurmpilot_job` handle.

------------------------------------------------------------------------

### `MockSlurmBackend$status()`

Advance the local scheduler queue and return current job status.

#### Usage

    MockSlurmBackend$status(job)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

#### Returns

A `slurmpilot_status` object.

------------------------------------------------------------------------

### `MockSlurmBackend$retry()`

Surgically retry failed/OOM/timed-out/cancelled chunks.

#### Usage

    MockSlurmBackend$retry(job, chunks = NULL, resources = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunks`:

  Optional integer vector of chunk IDs to retry.

- `resources`:

  Optional updated `slurmpilot_resources` spec.

#### Returns

Updated `slurmpilot_job` handle.

------------------------------------------------------------------------

### `MockSlurmBackend$cancel()`

Cancel active chunks (PENDING or RUNNING) for a job.

#### Usage

    MockSlurmBackend$cancel(job, chunks = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunks`:

  Optional integer vector of chunk IDs to cancel.

#### Returns

Updated `slurmpilot_status` invisibly.

------------------------------------------------------------------------

### `MockSlurmBackend$logs()`

Read stdout and stderr logs for one or all chunks.

#### Usage

    MockSlurmBackend$logs(job, chunk_id = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunk_id`:

  Optional integer chunk ID.

#### Returns

Named list of `list(stdout = ..., stderr = ...)` entries.

------------------------------------------------------------------------

### `MockSlurmBackend$collect()`

Collect ordered results from completed chunk checkpoints on disk.

#### Usage

    MockSlurmBackend$collect(job, simplify = FALSE, allow_partial = FALSE)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `simplify`:

  Logical; simplify homogeneous scalar or data-frame results.

- `allow_partial`:

  Logical; allow returning partial results if some chunks failed.

#### Returns

Ordered list (or simplified vector/tibble) of task results.

------------------------------------------------------------------------

### `MockSlurmBackend$shutdown()`

Terminate and reap all active background worker processes cleanly.

#### Usage

    MockSlurmBackend$shutdown()

#### Returns

Integer count of reaped worker processes (invisibly).

------------------------------------------------------------------------

### `MockSlurmBackend$print()`

Print summary of the local mock backend.

#### Usage

    MockSlurmBackend$print()

------------------------------------------------------------------------

### `MockSlurmBackend$clone()`

The objects of this class are cloneable with this method.

#### Usage

    MockSlurmBackend$clone(deep = FALSE)

#### Arguments

- `deep`:

  Whether to make a deep clone.

## Examples

``` r
be <- MockSlurmBackend$new(max_workers = 2L)
print(be)
#> <<MockSlurmBackend>> root=/tmp/RtmpamJPcO/slurmpilot_mock_189e6afe1167,
#> max_workers=2, jobs=0, active_workers=0
unlink(be$root_dir, recursive = TRUE)
```
