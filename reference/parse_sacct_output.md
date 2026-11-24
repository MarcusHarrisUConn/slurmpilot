# Parse Pipe-Delimited SLURM `sacct` Accounting Output

Parses `sacct -n -P --format=JobID,State,Elapsed,MaxRSS,ExitCode` output
into a tidy per-chunk tibble. Automatically consolidates `.batch`
sub-step `MaxRSS` onto the parent array task row (e.g. `12345_2.batch`
merged into `12345_2`) and ignores `.extern` overhead steps.

## Usage

``` r
parse_sacct_output(stdout)
```

## Arguments

- stdout:

  Character scalar or vector captured from `sacct`.

## Value

A
[`tibble::tibble()`](https://tibble.tidyverse.org/reference/tibble.html)
with columns `slurm_job_id`, `chunk_id`, `state`, `elapsed_sec`,
`peak_rss_mb`, and `exit_code`.

## Examples

``` r
sample_out <- paste(
  "12345_1|COMPLETED|00:04:12||0:0",
  "12345_1.batch|COMPLETED|00:04:12|512000K|0:0",
  "12345_2|OUT_OF_MEMORY|00:01:05||0:125",
  sep = "\n"
)
parse_sacct_output(sample_out)
#> # A tibble: 2 × 6
#>   slurm_job_id chunk_id state         elapsed_sec peak_rss_mb exit_code
#>   <chr>           <int> <chr>               <dbl>       <dbl>     <int>
#> 1 12345               1 COMPLETED             252         500         0
#> 2 12345               2 OUT_OF_MEMORY          65          NA       253
```
