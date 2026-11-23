test_that("scan_project_env parses renv.lock, DESCRIPTION, and R/qmd scripts", {
  proj <- withr::local_tempdir()

  # Write synthetic renv.lock
  lock_obj <- list(
    R = list(Version = "4.4.1"),
    Packages = list(
      lme4 = list(Package = "lme4", Version = "1.1-35.5", Source = "Repository"),
      Rcpp = list(Package = "Rcpp", Version = "1.0.13", Source = "Repository"),
      cmdstanr = list(
        Package = "cmdstanr",
        Version = "0.8.1",
        Source = "GitHub",
        RemoteUsername = "stan-dev",
        RemoteRepo = "cmdstanr",
        RemoteRef = "main"
      )
    )
  )
  jsonlite::write_json(lock_obj, file.path(proj, "renv.lock"), auto_unbox = TRUE, pretty = TRUE)

  # Write synthetic DESCRIPTION
  writeLines(c(
    "Package: demoanalysis",
    "Version: 0.1.0",
    "Imports: RTMB (>= 1.5), dplyr, httr2",
    "Suggests: sf"
  ), file.path(proj, "DESCRIPTION"))

  # Write synthetic analysis script
  dir.create(file.path(proj, "R"))
  writeLines(c(
    "library(rjags)",
    "requireNamespace('arrow')",
    "# library(not_a_real_pkg)",
    "x <- tidyr::pivot_longer(data.frame(a = 1), cols = 'a')"
  ), file.path(proj, "R", "model.R"))

  env <- scan_project_env(path = proj, extra_packages = c("ggplot2"))

  expect_s3_class(env, "slurmpilot_env")
  expect_equal(env$r_version, "4.4.1")
  expect_true(env$has_renv_lock)
  expect_true(all(c("lme4", "Rcpp", "cmdstanr", "RTMB", "dplyr", "httr2", "rjags", "arrow", "tidyr", "ggplot2") %in% env$packages$package))
  expect_false("not_a_real_pkg" %in% env$packages$package)
  expect_false("sf" %in% env$packages$package)

  # Toolchains detected
  expect_true(all(c("cpp", "cmdstan", "tmb", "jags", "linear_algebra", "http_ssl", "arrow") %in% env$toolchains))
  expect_true(all(c("libtbb-dev", "libjags-dev", "libopenblas-dev", "libcurl4-openssl-dev") %in% env$apt_packages))
  expect_equal(env$env_vars$CMDSTAN, "/opt/cmdstan")
  expect_invisible(print(env))

  # include_suggests picks up sf + spatial toolchain
  env_sug <- scan_project_env(path = proj, include_suggests = TRUE)
  expect_true("sf" %in% env_sug$packages$package)
  expect_true("spatial" %in% env_sug$toolchains)
  expect_true("libgdal-dev" %in% env_sug$apt_packages)
})

test_that("build_apptainer_def generates reproducible Apptainer recipes (contract + snapshot)", {
  env <- scan_project_env(extra_packages = c("lme4", "Rcpp", "cmdstanr", "RTMB"))
  env$r_version <- "4.4.1"
  env$env_hash <- "fixedhash001"

  out_def <- withr::local_tempfile(fileext = ".def")
  def <- build_apptainer_def(
    env = env,
    r_version = "4.4.1",
    cmdstan_version = "2.35.0",
    output_path = out_def
  )

  expect_s3_class(def, "slurmpilot_apptainer_def")
  expect_true(file.exists(out_def))
  expect_equal(readLines(out_def), def$recipe)
  expect_true(def$install_cmdstan)
  expect_false(def$renv_restore)
  expect_match(def$text, "From: rocker/r-ver:4.4.1", fixed = TRUE)
  expect_match(def$text, "export CMDSTAN=/opt/cmdstan", fixed = TRUE)
  expect_match(def$text, "export OMP_NUM_THREADS=1", fixed = TRUE)
  expect_match(def$text, "cmdstanr::install_cmdstan", fixed = TRUE)
  expect_match(def$text, "%test", fixed = TRUE)
  expect_invisible(print(def))

  # Snapshot contract test (normalize output path independent of temp dir)
  def_snap <- build_apptainer_def(
    env = env,
    r_version = "4.4.1",
    cmdstan_version = "2.35.0"
  )
  expect_snapshot(cat(def_snap$text))
})

test_that("build_apptainer_def supports renv.lock restore flow", {
  proj <- withr::local_tempdir()
  jsonlite::write_json(
    list(
      R = list(Version = "4.4.2"),
      Packages = list(Matrix = list(Package = "Matrix", Version = "1.7-0", Source = "Repository"))
    ),
    file.path(proj, "renv.lock"),
    auto_unbox = TRUE
  )
  def <- build_apptainer_def(proj)
  expect_true(def$renv_restore)
  expect_match(def$text, "%files", fixed = TRUE)
  expect_match(def$text, "renv::restore", fixed = TRUE)
})

test_that("render_sbatch_script and render_worker_script satisfy contract and snapshot", {
  res <- resource_spec(
    n_tasks = 40L,
    chunk_size = 5L,
    mem_mb = 4096L,
    time_minutes = 45,
    cpus_per_task = 2L,
    partition = "general",
    account = "quant_methods",
    max_concurrent = 4L
  )

  sb <- render_sbatch_script(
    job_name = "dsem_sim",
    resources = res,
    work_dir = "/scratch/mharris/dsem_sim",
    array_indices = c(2L, 3L, 7L),
    attempt = 2L,
    container_sif = "/scratch/containers/slurmpilot_env.sif",
    container_binds = c("/data/readonly:/data/readonly:ro"),
    modules = c("apptainer/1.3"),
    env_vars = list(STAN_NUM_THREADS = "2"),
    mail_user = "marcus.harris.uconn@gmail.com",
    mail_type = "FAIL"
  )

  expect_s3_class(sb, "slurmpilot_sbatch")
  expect_equal(sb$array_spec, "2-3,7%4")
  expect_match(sb$text, "#SBATCH --array=2-3,7%4", fixed = TRUE)
  expect_match(sb$text, "#SBATCH --mem=4G", fixed = TRUE)
  expect_match(sb$text, "#SBATCH --time=00:45:00", fixed = TRUE)
  expect_match(sb$text, "apptainer exec --cleanenv", fixed = TRUE)
  expect_match(sb$text, "module load apptainer/1.3", fixed = TRUE)
  expect_invisible(print(sb))
  expect_snapshot(cat(sb$text))

  # Worker script parses cleanly as standalone R code
  worker_lines <- render_worker_script()
  expect_no_error(parse(text = worker_lines))
})
