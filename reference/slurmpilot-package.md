# slurmpilot: Auto-Profiling 'SLURM' HPC Orchestration and 'Shiny' Offloading

Eliminates manual 'SLURM' scripting, blind memory and walltime guessing,
and 'Shiny' server freezes for compute-heavy R workflows. Runs empirical
micro-pilot replications in isolated child processes to measure true
peak resident memory and runtime distributions, computes optimal 'SLURM'
array chunking (including Longest Processing Time load balancing) and
resource flags, audits closures and globals before staging, scans
project environments to emit reproducible 'Apptainer' container recipes
and batch scripts, orchestrates remote 'SSH'/'SLURM' or local parallel
mock-'SLURM' execution with atomic SHA-256 checkpoints, independent
parallel random-number streams, and adaptive surgical retries, and
provides non-blocking 'bslib'/'Shiny' telemetry modules.

## See also

Useful links:

- <https://github.com/MarcusHarrisUConn/slurmpilot>

- <https://marcusharrisphd.com/slurmpilot/>

- Report bugs at
  <https://github.com/MarcusHarrisUConn/slurmpilot/issues>

## Author

**Maintainer**: Marcus Harris <marcus.harris.uconn@gmail.com>
\[copyright holder\]

Authors:

- Marcus Harris <marcus.harris.uconn@gmail.com> \[copyright holder\]
