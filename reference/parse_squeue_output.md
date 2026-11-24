# Parse Pipe-Delimited SLURM `squeue` Output

Parses `squeue -h -o "%i|%T|%M|%N|%r"` output into a tidy tibble,
expanding compressed array task ranges (such as `12345_[3-6,9]`) into
individual chunk rows with normalized SLURM states.

## Usage

``` r
parse_squeue_output(stdout)
```

## Arguments

- stdout:

  Character scalar or vector captured from `squeue`.

## Value

A
[`tibble::tibble()`](https://tibble.tidyverse.org/reference/tibble.html)
with columns `slurm_job_id`, `chunk_id`, `state`, `elapsed_sec`, `node`,
and `reason`.

## Examples

``` r
parse_squeue_output("12345_1|RUNNING|02:15|node01|None\n12345_[2-4]|PENDING|0:00||(Priority)")
#> # A tibble: 4 × 6
#>   slurm_job_id chunk_id state   elapsed_sec node   reason    
#>   <chr>           <int> <chr>         <dbl> <chr>  <chr>     
#> 1 12345               1 RUNNING         135 node01 None      
#> 2 12345               2 PENDING           0 NA     (Priority)
#> 3 12345               3 PENDING           0 NA     (Priority)
#> 4 12345               4 PENDING           0 NA     (Priority)
```
