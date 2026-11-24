## R CMD check results

Tested locally on macOS (`aarch64-apple-darwin23`, R 4.6.1):

- `rcmdcheck::rcmdcheck()` (full check including PDF manual via TinyTeX `pdflatex`):
  0 errors | 0 warnings | 0 notes
- `rcmdcheck::rcmdcheck(args = c("--as-cran"), env = c("_R_CHECK_CRAN_INCOMING_REMOTE_" = "false", "_R_CHECK_LIMIT_CORES_" = "true"))`:
  0 errors | 0 warnings | 0 package notes (1 local macOS host-only note for legacy `/usr/bin/tidy` + missing `V8`)
- `spelling::spell_check_package()`:
  0 spelling issues found.

## Submission Notes

- Release `0.5.0` of `slurmpilot` delivers a comprehensive independent peer
  red-team security and reliability hardening pass (remediating all 18 findings
  across `cli` glue safety, `#SBATCH`/SSH/SCP/URL/symlink injection defenses,
  ambient credential scrubbing, Apptainer `--cleanenv` env forwarding, POSIX
  `~/` expansion, `rcapsule` interoperability, pipeline DAG semantics,
  efficiency reporting, bounded SLURM parsers, resilient Shiny error handling,
  and $O(N \log M)$ LPT chunking) locked by permanent regression tests in
  `tests/testthat/test-peer-redteam.R`.
- Line coverage verified via `covr::package_coverage()` exceeds 93%.
- All examples, tests, and vignettes strictly respect `<= 2` worker processes,
  write exclusively to `tempdir()` with full cleanup, and leave global state
  (`options()`, `par()`, `Sys.setenv()`, `.Random.seed`, `showConnections()`)
  unchanged.
- All 5 vignettes use `VignetteBuilder: knitr` (`knitr::rmarkdown`) and execute
  fully offline without requiring a live SLURM cluster or Quarto CLI.
- Note on local macOS `--as-cran`: Apple's legacy `/usr/bin/tidy` triggers a
  host-only HTML validation skip note; all package-level `--as-cran` checks
  pass with 0 errors, 0 warnings, and 0 package notes.
