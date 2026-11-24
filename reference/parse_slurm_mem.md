# Parse a SLURM Memory String to Megabytes

Parses SLURM `MaxRSS`, `ReqMem`, or `--mem` values — including standard
units (`"512K"`, `"2048M"`, `"4G"`, `"0.5T"`), IEC units (`"2GiB"`), and
SLURM per-CPU / per-node `ReqMem` suffixes (`"100Mc"`, `"200Mn"`,
`"4Gc"`) — into numeric megabytes (MiB).

## Usage

``` r
parse_slurm_mem(x)
```

## Arguments

- x:

  Character vector of SLURM memory strings.

## Value

Numeric vector in megabytes (`NA_real_` for empty/invalid values).

## Examples

``` r
parse_slurm_mem(c("1024K", "2.5G", "0.5T", "100Mc", "200Mn"))
#> [1]      1   2560 524288    100    200
```
