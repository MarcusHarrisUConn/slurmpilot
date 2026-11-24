# Format Integer Array Indices into Compact SLURM `--array` Notation

Compresses a set of positive integer task indices into contiguous ranges
suitable for SLURM `--array`, with optional concurrency throttling
(`%limit`).

## Usage

``` r
format_slurm_array_indices(indices, max_concurrent = NULL)
```

## Arguments

- indices:

  Integer vector of 1-based SLURM array task indices.

- max_concurrent:

  Optional positive integer limiting concurrent array tasks
  (`%max_concurrent`).

## Value

Character scalar SLURM array specification, e.g. `"1-4,7,9-10%2"`.

## Examples

``` r
format_slurm_array_indices(c(1, 2, 3, 5, 8, 9))
#> [1] "1-3,5,8-9"
format_slurm_array_indices(1:20, max_concurrent = 4)
#> [1] "1-20%4"
```
