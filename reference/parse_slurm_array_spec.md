# Parse a SLURM Array Expression into Expanded Integer Indices

Expands SLURM array expressions such as `"1-100:2"`, `"1,3,5-9%4"`, or
bracketed `squeue` expressions `"[1-4,6%2]"` into a vector of integer
task indices.

## Usage

``` r
parse_slurm_array_spec(expr)
```

## Arguments

- expr:

  Character scalar SLURM array expression.

## Value

Integer vector of expanded array indices (`integer(0L)` for empty
strings).

## Examples

``` r
parse_slurm_array_spec("1-10:2")
#> [1] 1 3 5 7 9
parse_slurm_array_spec("1,3,5-9%4")
#> [1] 1 3 5 6 7 8 9
```
