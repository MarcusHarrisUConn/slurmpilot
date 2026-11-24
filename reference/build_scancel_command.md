# Build a SLURM `scancel` Command String

Constructs a `scancel` command targeting either an entire SLURM job or
specific array task indices (`<job_id>_<chunk_id>`).

## Usage

``` r
build_scancel_command(slurm_job_id, chunks = NULL)
```

## Arguments

- slurm_job_id:

  Character or integer SLURM job ID.

- chunks:

  Optional integer vector of specific array task indices to cancel.

## Value

Character scalar `scancel` command.

## Examples

``` r
build_scancel_command("482910")
#> [1] "scancel 482910"
build_scancel_command("482910", chunks = c(2, 5))
#> [1] "scancel 482910_2 482910_5"
```
