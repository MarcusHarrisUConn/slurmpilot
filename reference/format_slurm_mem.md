# Format Memory in Megabytes as a SLURM `--mem` String

Formats an integer megabyte value cleanly as either `"<N>G"` (when an
exact multiple of 1024 MB) or `"<N>M"`.

## Usage

``` r
format_slurm_mem(mem_mb)
```

## Arguments

- mem_mb:

  Numeric scalar memory size in megabytes.

## Value

Character scalar formatted for SLURM `--mem`.

## Examples

``` r
format_slurm_mem(512)
#> [1] "512M"
format_slurm_mem(4096)
#> [1] "4G"
```
