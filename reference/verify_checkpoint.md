# Verify SHA-256 Checksum and Readability of a Chunk Checkpoint

Validates that a chunk `.rds` checkpoint exists, matches its recorded
SHA-256 sidecar digest (and optional `expected_sha256`), and
deserializes cleanly via
[`readRDS()`](https://rdrr.io/r/base/readRDS.html). Protects
[`slurm_collect()`](https://marcusharrisphd.com/slurmpilot/reference/slurm_collect.md)
against silent corruption or partial writes on shared HPC filesystems.

## Usage

``` r
verify_checkpoint(result_path, expected_sha256 = NULL, require_sidecar = FALSE)
```

## Arguments

- result_path:

  Path to a `chunk_XXXX.rds` checkpoint file.

- expected_sha256:

  Optional 64-character hexadecimal SHA-256 string to verify against in
  addition to the `.sha256` sidecar file (if present).

- require_sidecar:

  Logical; if `TRUE`, fails when no `.sha256` sidecar exists and
  `expected_sha256` is `NULL`. Default `FALSE` (verifies whenever a
  sidecar or `expected_sha256` is available).

## Value

A named list with `ok` (logical), `sha256` (actual SHA-256 hex),
`expected_sha256`, `reason` (`NA_character_` when valid), and `object`
(the deserialized chunk object when valid, else `NULL`).

## Examples

``` r
tmp <- tempfile(fileext = ".rds")
saveRDS(list(chunk_id = 1L, results = list()), tmp)
writeLines(digest::digest(tmp, algo = "sha256", file = TRUE), paste0(tmp, ".sha256"))
verify_checkpoint(tmp)$ok
#> [1] TRUE
unlink(c(tmp, paste0(tmp, ".sha256")))
```
