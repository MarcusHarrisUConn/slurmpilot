# Abstract Base Class for `slurmpilot` Scheduler Backends

Defines the pluggable R6 interface implemented by
[MockSlurmBackend](https://marcusharrisphd.com/slurmpilot/reference/MockSlurmBackend.md)
and
[SlurmSshBackend](https://marcusharrisphd.com/slurmpilot/reference/SlurmSshBackend.md).
Custom HPC scheduler adapters (e.g., PBS/Torque, LSF, or cloud batch
APIs) can subclass `SlurmBackend` and override `submit()`, `status()`,
`retry()`, `cancel()`, `logs()`, and `collect()`.

## Public fields

- `name`:

  Character identifier of the backend implementation.

## Methods

### Public methods

- [`SlurmBackend$new()`](#method-SlurmBackend-initialize)

- [`SlurmBackend$submit()`](#method-SlurmBackend-submit)

- [`SlurmBackend$status()`](#method-SlurmBackend-status)

- [`SlurmBackend$retry()`](#method-SlurmBackend-retry)

- [`SlurmBackend$cancel()`](#method-SlurmBackend-cancel)

- [`SlurmBackend$logs()`](#method-SlurmBackend-logs)

- [`SlurmBackend$collect()`](#method-SlurmBackend-collect)

- [`SlurmBackend$wait()`](#method-SlurmBackend-wait)

- [`SlurmBackend$cleanup()`](#method-SlurmBackend-cleanup)

- [`SlurmBackend$print()`](#method-SlurmBackend-print)

- [`SlurmBackend$clone()`](#method-SlurmBackend-clone)

------------------------------------------------------------------------

### `SlurmBackend$new()`

Initialize the backend.

#### Usage

    SlurmBackend$new()

------------------------------------------------------------------------

### `SlurmBackend$submit()`

Submit a `slurmpilot_job_spec` to the scheduler.

#### Usage

    SlurmBackend$submit(job_spec, ...)

#### Arguments

- `job_spec`:

  A `slurmpilot_job_spec` object.

- `...`:

  Backend-specific submission options.

#### Returns

A `slurmpilot_job` handle.

------------------------------------------------------------------------

### `SlurmBackend$status()`

Poll current job and per-chunk status.

#### Usage

    SlurmBackend$status(job)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

#### Returns

A `slurmpilot_status` object.

------------------------------------------------------------------------

### `SlurmBackend$retry()`

Surgically retry failed/cancelled chunks without rerunning completed
ones.

#### Usage

    SlurmBackend$retry(job, chunks = NULL, resources = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunks`:

  Optional integer vector of chunk IDs to retry (defaults to all
  retryable chunks).

- `resources`:

  Optional updated `slurmpilot_resources` spec (e.g. bumped `--mem` or
  `--time`).

#### Returns

Updated `slurmpilot_job` handle.

------------------------------------------------------------------------

### `SlurmBackend$cancel()`

Cancel active chunks for a job.

#### Usage

    SlurmBackend$cancel(job, chunks = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunks`:

  Optional integer vector of chunk IDs to cancel (default: all active
  chunks).

#### Returns

Latest `slurmpilot_status` invisibly.

------------------------------------------------------------------------

### `SlurmBackend$logs()`

Retrieve stdout/stderr logs for one or all chunks.

#### Usage

    SlurmBackend$logs(job, chunk_id = NULL)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `chunk_id`:

  Optional integer chunk ID.

#### Returns

Named list of log records (`stdout`, `stderr`) per chunk.

------------------------------------------------------------------------

### `SlurmBackend$collect()`

Collect ordered task results from completed chunk checkpoints.

#### Usage

    SlurmBackend$collect(job, simplify = FALSE, allow_partial = FALSE)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `simplify`:

  Logical; simplify homogeneous scalar or data-frame outputs.

- `allow_partial`:

  Logical; allow collecting incomplete results.

#### Returns

Ordered list (or simplified vector/tibble) of task results.

------------------------------------------------------------------------

### `SlurmBackend$wait()`

Block until a job reaches a terminal state or timeout elapses.

#### Usage

    SlurmBackend$wait(job, timeout = Inf, poll_interval = 0.2, progress = FALSE)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

- `timeout`:

  Maximum wait time in seconds. Default `Inf`.

- `poll_interval`:

  Polling cadence in seconds. Default `0.2`.

- `progress`:

  Logical; emit periodic progress updates. Default `FALSE`.

#### Returns

Terminal (or latest on timeout) `slurmpilot_status` object.

------------------------------------------------------------------------

### `SlurmBackend$cleanup()`

Clean up local staging files for a job.

#### Usage

    SlurmBackend$cleanup(job)

#### Arguments

- `job`:

  A `slurmpilot_job` handle.

------------------------------------------------------------------------

### `SlurmBackend$print()`

Print a concise summary of the backend.

#### Usage

    SlurmBackend$print()

------------------------------------------------------------------------

### `SlurmBackend$clone()`

The objects of this class are cloneable with this method.

#### Usage

    SlurmBackend$clone(deep = FALSE)

#### Arguments

- `deep`:

  Whether to make a deep clone.

## Examples

``` r
be <- SlurmBackend$new()
print(be)
#> <<SlurmBackend>> (backend: abstract)
```
