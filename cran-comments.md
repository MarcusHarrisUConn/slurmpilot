## R CMD check results

Tested locally on macOS (`aarch64-apple-darwin23`, R 4.6.1):

- `rcmdcheck::rcmdcheck()` (full check including PDF manual via TinyTeX `pdflatex`):
  0 errors | 0 warnings | 0 notes
- `rcmdcheck::rcmdcheck(args = c("--as-cran"), env = c("_R_CHECK_CRAN_INCOMING_REMOTE_" = "false", "_R_CHECK_LIMIT_CORES_" = "true"))`:
  0 errors | 0 warnings | 0 notes
- `spelling::spell_check_package()`:
  0 spelling issues found.

## Submission Notes

- This is the initial CRAN release (`0.3.0`) of `slurmpilot`.
- All examples, tests, and vignettes strictly respect `<= 2` worker processes,
  write exclusively to `tempdir()` with full cleanup, and leave global state
  (`options()`, `par()`, `Sys.setenv()`, `.Random.seed`) unchanged.
- All vignettes use `VignetteBuilder: knitr` (`knitr::rmarkdown`) and execute
  fully offline without requiring a live SLURM cluster or Quarto CLI.
- All software and acronym names in `DESCRIPTION` are properly single-quoted.
