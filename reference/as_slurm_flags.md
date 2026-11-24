# Convert a Resource Specification into SLURM CLI Flags

Formats a `slurmpilot_resources` object into canonical SLURM
`--flag=value` directives suitable for `sbatch` headers or command-line
submission.

## Usage

``` r
as_slurm_flags(x, array_indices = NULL, ...)

# S3 method for class 'slurmpilot_resources'
as_slurm_flags(x, array_indices = NULL, ...)
```

## Arguments

- x:

  Object to format (typically a `slurmpilot_resources` object).

- array_indices:

  Optional integer vector overriding the `--array` range (used during
  surgical retries of specific failed chunks).

- ...:

  Additional arguments passed to methods.

## Value

Character vector of SLURM flags (e.g.
`c("--array=1-10", "--mem=2G", ...)`).

## Examples

``` r
res <- resource_spec(n_tasks = 20, chunk_size = 5, mem_mb = 2048, time_minutes = 30)
as_slurm_flags(res)
#> [1] "--array=1-4"       "--cpus-per-task=1" "--mem=2G"         
#> [4] "--time=00:30:00"  
as_slurm_flags(res, array_indices = c(2L, 4L))
#> [1] "--array=2,4"       "--cpus-per-task=1" "--mem=2G"         
#> [4] "--time=00:30:00"  
```
