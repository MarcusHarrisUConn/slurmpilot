# Parse a SLURM Time String to Seconds

Parses SLURM elapsed/limit time strings such as `"MM"`, `"MM:SS"`,
`"HH:MM:SS"`, `"D-HH"`, `"D-HH:MM"`, or `"D-HH:MM:SS"` (with optional
fractional seconds) into numeric seconds.

## Usage

``` r
parse_slurm_time(x)
```

## Arguments

- x:

  Character vector of SLURM time strings.

## Value

Numeric vector of durations in seconds (`NA_real_` for unparseable,
`"UNLIMITED"`, `"INVALID"`, or missing inputs).

## Examples

``` r
parse_slurm_time(c("05:30", "01:15:00", "2-03:00:10", "00:02:15.500"))
#> [1]    330.0   4500.0 183610.0    135.5
```
