# Permanent regression tests for all 18 peer red-team findings (v0.5.0)
# Covers C1-C2, H1-H6, M1-M8, and L1-L2.

test_that("C1: print methods do not evaluate glue expressions in untrusted strings", {
  withr::local_envvar(
    SLURMPILOT_C1_PWN1 = "",
    SLURMPILOT_C1_PWN2 = "",
    SLURMPILOT_C1_PWN3 = ""
  )

  # 1. slurmpilot_globals_report print sink
  rep_fake <- structure(
    list(
      ok = FALSE,
      warnings = "{Sys.setenv(SLURMPILOT_C1_PWN1 = 'PWNED')}",
      estimated_bundle_mb = 0.01,
      closure_size_mb = 0,
      globals_size_mb = 0,
      args_size_mb = 0,
      closure_objects = tibble::tibble(name = character(), class = character(), size_mb = numeric(), env_name = character()),
      globals_table = tibble::tibble(name = character(), class = character(), size_mb = numeric()),
      missing_variables = character(),
      unexported_functions = character()
    ),
    class = "slurmpilot_globals_report"
  )
  capture.output(print(rep_fake), type = "message")
  expect_identical(Sys.getenv("SLURMPILOT_C1_PWN1"), "")

  # 2. slurmpilot_efficiency print sink
  res_c1 <- resource_spec(n_tasks = 2L, chunk_size = 2L, mem_mb = 1024, time_minutes = 10)
  eff_fake <- slurm_efficiency_report(
    data.frame(chunk_id = 1L, state = "COMPLETED", wall_sec = 10, peak_rss_mb = 100),
    resources = res_c1
  )
  eff_fake$recommendations <- "{Sys.setenv(SLURMPILOT_C1_PWN2 = 'PWNED')}"
  capture.output(print(eff_fake), type = "message")
  expect_identical(Sys.getenv("SLURMPILOT_C1_PWN2"), "")

  # 3. Real inspect_job_globals() with malicious backticked identifier
  evil_fn <- eval(parse(text = "function(x) x + `{Sys.setenv(SLURMPILOT_C1_PWN3='PWNED')}`"))
  environment(evil_fn) <- globalenv()
  rep_real <- inspect_job_globals(evil_fn)
  capture.output(print(rep_real), type = "message")
  expect_identical(Sys.getenv("SLURMPILOT_C1_PWN3"), "")
})

test_that("C2: extra_sbatch blocks --wrap/multi-flag smuggling and paths reject spaces", {
  res <- resource_spec(n_tasks = 4L, chunk_size = 2L)

  expect_error(
    render_sbatch_script("c2_job", res, "/tmp/work", extra_sbatch = "--comment=ok --wrap='id'"),
    "Unsafe|Forbidden|forbidden|space|metacharacter|Single-flag",
    ignore.case = TRUE
  )
  expect_error(
    render_sbatch_script("c2_job", res, "/tmp/work", extra_sbatch = "--wrap=id"),
    "Forbidden|forbidden",
    ignore.case = TRUE
  )
  expect_error(
    render_sbatch_script("c2_job", res, "/tmp/work", extra_sbatch = "--prolog=/tmp/evil.sh"),
    "Forbidden|forbidden",
    ignore.case = TRUE
  )
  expect_error(
    render_sbatch_script("c2_job", res, "/tmp/work", extra_sbatch = "--output=/tmp/evil.out"),
    "Forbidden|forbidden",
    ignore.case = TRUE
  )
  expect_error(
    render_sbatch_script("c2_job", res, "/tmp/work", extra_sbatch = "--export=ALL"),
    "Forbidden|forbidden",
    ignore.case = TRUE
  )

  # Legitimate single flags still pass
  sb_ok <- render_sbatch_script(
    "c2_ok", res, "/tmp/work",
    extra_sbatch = c("--gres=gpu:1", "--constraint=a100", "--exclusive")
  )
  expect_true(any(grepl("^#SBATCH --gres=gpu:1$", sb_ok$script)))

  # Spaces in SLURM work_dir, container_sif, container_binds, remote_dir rejected
  expect_error(
    render_sbatch_script("c2_space", res, "/tmp/my study"),
    "whitespace|Unsafe",
    ignore.case = TRUE
  )
  expect_error(
    render_sbatch_script("c2_space", res, "/tmp/work", container_sif = "/opt/my container.sif"),
    "whitespace|Unsafe",
    ignore.case = TRUE
  )
  expect_error(
    slurm_ssh_backend(host = "hpc.example.org", user = "alice", remote_dir = "/scratch/my dir", dry_run = TRUE),
    "whitespace|Unsafe",
    ignore.case = TRUE
  )
})

test_that("H1: SSH -F/dangerous flags and SCP remote metacharacters are rejected", {
  bad_opts <- list(
    c("-F", "/tmp/evil.cfg"),
    "-F/tmp/evil.cfg",
    "-vF/tmp/evil.cfg",
    "-S/tmp/ctl",
    "-L8080:127.0.0.1:80",
    "-R9000:127.0.0.1:22",
    "-D1080",
    "-Jjump.example.org",
    "-A",
    "-i/tmp/stolen_key",
    "-oIdentityFile=/etc/passwd",
    "-oControlPath=/tmp/ctl",
    "-oForwardAgent=yes",
    "-oSendEnv=*",
    "-oProxyJump=evil.host",
    c("-o", "ProxyCommand=id")
  )
  for (opt in bad_opts) {
    expect_error(
      slurm_ssh_backend(host = "hpc.example.org", user = "alice", ssh_options = opt, dry_run = TRUE),
      "Dangerous|forbidden|Unsafe",
      ignore.case = TRUE
    )
  }

  be <- slurm_ssh_backend(
    host = "hpc.example.org",
    user = "alice",
    ssh_options = c("-oBatchMode=yes", "-oConnectTimeout=10", "-4"),
    dry_run = TRUE
  )
  expect_s3_class(be, "SlurmSshBackend")

  # SCP remote command injection & whitespace rejected
  expect_error(
    build_scp_args("/tmp/local.rds", "alice@hpc.example.org:/tmp/dest;id"),
    "metacharacter|Unsafe|whitespace",
    ignore.case = TRUE
  )
  expect_error(
    build_scp_args("/tmp/local.rds", "alice@hpc.example.org:/tmp/$(id)"),
    "metacharacter|Unsafe|whitespace",
    ignore.case = TRUE
  )
  expect_error(
    build_scp_args("/tmp/local.rds", "alice@hpc.example.org:/tmp/a b"),
    "whitespace|Unsafe",
    ignore.case = TRUE
  )
})

test_that("H2: use_rcapsule_container interoperates with rcapsule specs, compiles, manifests, and exports", {
  # 1. rcapsule_apptainer_spec (in-memory def_content, def_sha256, bind_paths, no def_path/sif_path)
  rc_spec <- structure(
    list(
      project_name = "my_analysis",
      r_version = "4.4.1",
      base_image = "rocker/r-ver:4.4.1",
      bind_paths = c("/scratch", "/data"),
      def_content = c("Bootstrap: docker", "From: rocker/r-ver:4.4.1"),
      def_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    ),
    class = c("rcapsule_apptainer_spec", "rcapsule")
  )
  cs1 <- use_rcapsule_container(container = rc_spec)
  expect_s3_class(cs1, "slurmpilot_container_spec")
  expect_equal(cs1$source, "rcapsule")
  expect_equal(cs1$sif_path, "/opt/containers/my_analysis.sif")
  expect_equal(cs1$binds, c("/scratch", "/data"))
  expect_equal(cs1$digest, rc_spec$def_sha256)
  expect_equal(cs1$r_version, "4.4.1")
  expect_equal(cs1$def_content, rc_spec$def_content)

  # 2. rcapsule_apptainer (compile_apptainer output with $path, $content, $sha256)
  rc_ap <- structure(
    list(
      path = "/scratch/proj/Apptainer.def",
      content = c("Bootstrap: docker", "From: rocker/r-ver:4.4.1"),
      sha256 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
      bind_paths = c("/work")
    ),
    class = "rcapsule_apptainer"
  )
  cs2 <- use_rcapsule_container(container = rc_ap)
  expect_equal(cs2$source, "rcapsule")
  expect_equal(cs2$def_path, "/scratch/proj/Apptainer.def")
  expect_equal(cs2$sif_path, "/scratch/proj/Apptainer.sif")
  expect_equal(cs2$digest, rc_ap$sha256)
  expect_equal(cs2$binds, "/work")

  # 3. rcapsule_manifest (nested integrity$content_digest + environment$r_version)
  rc_man <- structure(
    list(
      project_name = "study_manifest",
      environment = list(r_version = "4.4.2"),
      integrity = list(content_digest = "abcdef0123456789abcdef0123456789")
    ),
    class = "rcapsule_manifest"
  )
  cs3 <- use_rcapsule_container(container = rc_man)
  expect_equal(cs3$source, "rcapsule")
  expect_equal(cs3$sif_path, "/opt/containers/study_manifest.sif")
  expect_equal(cs3$digest, "abcdef0123456789abcdef0123456789")
  expect_equal(cs3$r_version, "4.4.2")

  # 4. rcapsule_export (export_capsule_bundle format = "dir", sha256 = NA)
  exp_dir <- withr::local_tempdir()
  writeLines("Bootstrap: docker", file.path(exp_dir, "Apptainer.def"))
  rc_exp <- structure(
    list(
      output_path = exp_dir,
      format = "dir",
      files = c("Apptainer.def", "capsule.json"),
      sha256 = NA_character_,
      capsule_id = "cap_a1b2c3d4e5f6"
    ),
    class = "rcapsule_export"
  )
  cs4 <- use_rcapsule_container(container = rc_exp)
  expect_equal(cs4$source, "rcapsule")
  expect_equal(cs4$def_path, file.path(exp_dir, "Apptainer.def"))
  expect_equal(cs4$sif_path, file.path(exp_dir, "Apptainer.sif"))
  expect_equal(cs4$digest, "cap_a1b2c3d4e5f6")

  # Attach to job_spec
  js <- slurm_job_spec(function(x) x, list(1, 2), resource_spec(2L, 1L))
  js2 <- use_rcapsule_container(js, rc_spec)
  expect_equal(js2$container_sif, "/opt/containers/my_analysis.sif")
  expect_equal(js2$env_vars$SLURMPILOT_CONTAINER_DIGEST, rc_spec$def_sha256)
})

test_that("H3: remote_dir starting with ~/ expands via $HOME rather than literal single-quoted tilde", {
  expect_equal(sp_sh_quote_path("~/slurmpilot_jobs"), "\"$HOME\"/'slurmpilot_jobs'")
  expect_equal(sp_sh_quote_path("~"), "\"$HOME\"")
  expect_equal(sp_sh_quote_path("/scratch/jobs"), "'/scratch/jobs'")

  res <- resource_spec(n_tasks = 4L, chunk_size = 2L)
  sb <- render_sbatch_script(
    "tilde_job",
    res,
    work_dir = "~/slurmpilot_jobs/tilde_job",
    container_sif = "/opt/env.sif"
  )
  expect_true(any(grepl('^WORK_DIR="\\$HOME"/\'slurmpilot_jobs/tilde_job\'$', sb$script)))
  expect_false(any(grepl("^WORK_DIR='~/", sb$script)))
  # #SBATCH --output/--error must not emit literal ~/
  expect_true(any(grepl("^#SBATCH --output=slurmpilot_jobs/tilde_job/logs/chunk_%a\\.out$", sb$script)))
  expect_true(any(grepl('--bind "\\$\\{WORK_DIR\\}:\\$\\{WORK_DIR\\}"', sb$script)))

  # Dry-run SlurmSshBackend with default remote_dir = "~/slurmpilot_jobs"
  local_stg <- withr::local_tempdir()
  be <- slurm_ssh_backend(
    host = "hpc.example.org",
    user = "alice",
    remote_dir = "~/slurmpilot_jobs",
    local_stage_dir = local_stg,
    dry_run = TRUE
  )
  job <- slurm_submit(be, function(x) x, as.list(1:4), resources = res, name = "tilde_ssh")
  cmd_texts <- vapply(job$meta$dry_run_commands, function(e) paste(e$args, collapse = " "), character(1L))
  expect_true(any(grepl('mkdir -p "\\$HOME"/\'slurmpilot_jobs/', cmd_texts)))
  expect_true(any(grepl('sbatch --parsable "\\$HOME"/\'slurmpilot_jobs/', cmd_texts)))
  expect_false(any(grepl("'~/slurmpilot_jobs", cmd_texts, fixed = TRUE)))
})

test_that("H4: render_sbatch_script exports APPTAINERENV_* variables when using --cleanenv", {
  res <- resource_spec(n_tasks = 4L, chunk_size = 2L, cpus_per_task = 3L)
  sb_cont <- render_sbatch_script(
    job_name = "h4_container",
    resources = res,
    work_dir = "/scratch/work",
    container_sif = "/opt/containers/study.sif",
    env_vars = list(MY_MODEL_FLAG = "exact", SLURMPILOT_CONTAINER_DIGEST = "deadbeef1234")
  )
  expect_true(any(grepl("^export APPTAINERENV_OMP_NUM_THREADS=3$", sb_cont$script)))
  expect_true(any(grepl("^export APPTAINERENV_OPENBLAS_NUM_THREADS=3$", sb_cont$script)))
  expect_true(any(grepl("^export APPTAINERENV_MKL_NUM_THREADS=3$", sb_cont$script)))
  expect_true(any(grepl('^export APPTAINERENV_SLURMPILOT_WORK_DIR="\\$\\{WORK_DIR\\}"$', sb_cont$script)))
  expect_true(any(grepl('^export APPTAINERENV_SLURMPILOT_CHUNK_ID="\\$\\{SLURM_ARRAY_TASK_ID\\}"$', sb_cont$script)))
  expect_true(any(grepl("^export APPTAINERENV_SLURMPILOT_ATTEMPT=1$", sb_cont$script)))
  expect_true(any(grepl("^export APPTAINERENV_MY_MODEL_FLAG='exact'$", sb_cont$script)))
  expect_true(any(grepl("^export APPTAINERENV_SLURMPILOT_CONTAINER_DIGEST='deadbeef1234'$", sb_cont$script)))

  # Native (non-containerized) sbatch omits APPTAINERENV_
  sb_native <- render_sbatch_script(
    job_name = "h4_native",
    resources = res,
    work_dir = "/scratch/work",
    env_vars = list(MY_MODEL_FLAG = "exact")
  )
  expect_false(any(grepl("^export APPTAINERENV_", sb_native$script)))
})

test_that("H5: sp_assert_path_confined blocks non-existent .. traversal and dangling external symlinks", {
  root <- withr::local_tempdir()
  outside <- withr::local_tempdir()

  # Non-existent intermediate directory + ..
  expect_error(
    sp_assert_path_confined(file.path(root, "does_not_exist", "..", "..", "etc", "passwd"), root),
    "escapes|traversal",
    ignore.case = TRUE
  )

  # Legitimate non-existent nested file under root succeeds
  ok_path <- file.path(root, "results", "chunk_0001.rds")
  expect_no_error(sp_assert_path_confined(ok_path, root))

  skip_on_os("windows")
  # Dangling symlink pointing outside root
  dangling <- file.path(root, "dangling.rds")
  file.symlink(file.path(outside, "nonexistent_target.rds"), dangling)
  expect_error(
    sp_assert_path_confined(dangling, root),
    "escapes",
    ignore.case = TRUE
  )

  # Symlinked directory pointing outside root, with non-existent child inside it
  link_dir <- file.path(root, "ext_dir")
  file.symlink(outside, link_dir)
  expect_error(
    sp_assert_path_confined(file.path(link_dir, "future_file.rds"), root),
    "escapes",
    ignore.case = TRUE
  )
})

test_that("H6: closure active bindings, nested env sizing/secrets, ambient scrubbing, and 0600 sbatch", {
  # 1. Active binding is NOT evaluated by inspect_job_globals()
  e_act <- new.env(parent = globalenv())
  triggered <- FALSE
  makeActiveBinding("boom_binding", function() {
    triggered <<- TRUE
    stop("active binding should not be triggered!")
  }, e_act)
  fn_act <- function(x) x + 1
  environment(fn_act) <- e_act
  rep_act <- inspect_job_globals(fn_act)
  expect_false(triggered)
  expect_true("boom_binding" %in% rep_act$active_bindings)

  # 2. Nested environment memory bloat AND nested secret detection
  e_outer <- new.env(parent = globalenv())
  e_inner <- new.env(parent = emptyenv())
  e_inner$big_vec <- numeric(300000L) # ~2.4 MB
  e_inner$aws_secret <- "AKIAFAKEKEY1234567890"
  e_outer$holder <- e_inner
  fn_nest <- function(x) x + 1
  environment(fn_nest) <- e_outer

  rep_nest <- inspect_job_globals(fn_nest, size_warn_mb = 1)
  expect_gt(rep_nest$closure_size_mb, 1.5)
  expect_true("holder$aws_secret" %in% rep_nest$secret_objects)
  expect_false(rep_nest$ok)
  expect_true(any(grepl("secret/credential", rep_nest$warnings, ignore.case = TRUE)))

  # 3. Ambient credential scrubbing in pilot_run() and MockSlurmBackend
  withr::local_envvar(
    AWS_SECRET_ACCESS_KEY = "super_secret_aws_value",
    OPENAI_API_KEY = "sk-test-secret-key",
    SLURMPILOT_SAFE_TAG = "allowed_tag"
  )

  # pilot_run scrubs secrets by default
  p_scrub <- pilot_run(
    fun = function(x) {
      if (nzchar(Sys.getenv("AWS_SECRET_ACCESS_KEY")) || nzchar(Sys.getenv("OPENAI_API_KEY"))) {
        stop("SECRET_LEAKED")
      }
      x + 1
    },
    args_list = list(1),
    n_pilot = 1L,
    isolate = TRUE,
    scrub_secrets = TRUE
  )
  expect_equal(p_scrub$summary$n_ok, 1L)

  # MockSlurmBackend scrubs ambient secrets AND forwards explicit job_spec$env_vars
  be <- mock_slurm_backend(max_workers = 1L)
  withr::defer(unlink(be$root_dir, recursive = TRUE, force = TRUE))
  spec_env <- slurm_job_spec(
    fun = function(x) {
      list(
        aws = Sys.getenv("AWS_SECRET_ACCESS_KEY"),
        openai = Sys.getenv("OPENAI_API_KEY"),
        explicit = Sys.getenv("MY_EXPLICIT_STUDY_VAR")
      )
    },
    args_list = list(1),
    resources = resource_spec(1L, 1L),
    env_vars = list(MY_EXPLICIT_STUDY_VAR = "forwarded_ok")
  )
  j <- slurm_submit(backend = be, fun = spec_env)
  st <- slurm_wait(j, poll_interval = 0.05)
  expect_equal(st$state, "COMPLETED")
  res_env <- slurm_collect(j)[[1L]]
  expect_identical(res_env$aws, "")
  expect_identical(res_env$openai, "")
  expect_identical(res_env$explicit, "forwarded_ok")

  # 4. render_sbatch_script warns on secret env var and sets 0600 permissions
  sb_path <- withr::local_tempfile(fileext = ".sbatch")
  expect_warning(
    render_sbatch_script(
      "secret_warn_job",
      resource_spec(2L, 1L),
      "/tmp/work",
      env_vars = list(API_KEY = "secret123"),
      output_path = sb_path
    ),
    "secret|plaintext",
    ignore.case = TRUE
  )
  if (.Platform$OS.type == "unix") {
    mode_oct <- as.integer(file.info(sb_path)$mode)
    # Group and other permission bits must be zero (mode & 077 == 0)
    expect_equal(bitwAnd(mode_oct, 63L), 0L)
  }
})

test_that("M1: SlurmSshBackend retry preserves container_binds and live submit rejects DRY_RUN dependency", {
  local_stg <- withr::local_tempdir()
  be_dry <- slurm_ssh_backend(
    host = "hpc.example.org",
    user = "alice",
    local_stage_dir = local_stg,
    container_sif = "/opt/containers/base.sif",
    container_binds = c("/shared/a:/a:ro"),
    dry_run = TRUE
  )
  res <- resource_spec(n_tasks = 4L, chunk_size = 2L)
  spec <- slurm_job_spec(
    fun = function(x) x,
    args_list = as.list(1:4),
    resources = res,
    name = "m1_binds",
    container_binds = c("/shared/b:/b:ro")
  )
  j <- be_dry$submit(spec)
  j_retry <- be_dry$retry(j, chunks = 2L)
  retry_sbatch <- readLines(file.path(j_retry$local_dir, "retry_2.sbatch"), warn = FALSE)
  exec_lines <- grep("apptainer exec", retry_sbatch, value = TRUE)
  expect_true(any(grepl("/shared/a:/a:ro", exec_lines, fixed = TRUE)))
  expect_true(any(grepl("/shared/b:/b:ro", exec_lines, fixed = TRUE)))

  # Live (non-dry-run) backend must reject afterok:DRY_RUN before SSH
  be_live <- slurm_ssh_backend(
    host = "hpc.example.org",
    user = "alice",
    local_stage_dir = withr::local_tempdir(),
    dry_run = FALSE
  )
  spec_dep <- slurm_job_spec(
    fun = function(x) x,
    args_list = list(1),
    resources = resource_spec(1L, 1L),
    dependency = "afterok:DRY_RUN"
  )
  expect_error(
    be_live$submit(spec_dep),
    "DRY_RUN|placeholder",
    ignore.case = TRUE
  )
  expect_error(
    be_live$submit(slurm_job_spec(function(x) x, list(1), resource_spec(1L, 1L)), dependency = "afterok:DRY_RUN"),
    "DRY_RUN|placeholder",
    ignore.case = TRUE
  )
})

test_that("M2: slurm_pipeline_run validates wait=FALSE, stop_on_failure/afternotok/afterany, and 0-task dynamic stages", {
  be <- mock_slurm_backend(max_workers = 1L)
  withr::defer(unlink(be$root_dir, recursive = TRUE, force = TRUE))

  # 1. wait = FALSE with edges on MockSlurmBackend aborts cleanly
  p_async <- slurm_pipeline(
    name = "m2_wait_false",
    slurm_stage("s1", fun = function(x) x, args_list = list(1), resources = resource_spec(1L, 1L)),
    slurm_stage("s2", fun = function(x) x, args_list = list(1), resources = resource_spec(1L, 1L), depends_on = "s1")
  )
  expect_error(
    slurm_pipeline_run(p_async, backend = be, wait = FALSE),
    "wait = TRUE|cannot schedule",
    ignore.case = TRUE
  )

  # 2a. stop_on_failure = TRUE: failing upstream skips afterok, runs afternotok, and afterany runs even after SKIPPED
  p_fail <- slurm_pipeline(
    name = "m2_recovery",
    slurm_stage("s_fail", fun = function(x) stop("intentional_fail"), args_list = list(1), resources = resource_spec(1L, 1L)),
    slurm_stage("s_ok_dep", fun = function(x) "afterok_ran", args_list = list(1), resources = resource_spec(1L, 1L), depends_on = "s_fail", dependency_type = "afterok"),
    slurm_stage("s_recover", fun = function(x) "recovered", args_list = list(1), resources = resource_spec(1L, 1L), depends_on = "s_fail", dependency_type = "afternotok"),
    slurm_stage("s_cleanup", fun = function(x) "cleaned", args_list = list(1), resources = resource_spec(1L, 1L), depends_on = "s_ok_dep", dependency_type = "afterany")
  )
  run_stop <- slurm_pipeline_run(p_fail, backend = be, wait = TRUE, poll_interval = 0.05, stop_on_failure = TRUE)
  expect_equal(run_stop$stage_states[["s_fail"]], "FAILED")
  expect_equal(run_stop$stage_states[["s_ok_dep"]], "SKIPPED")
  expect_equal(run_stop$stage_states[["s_recover"]], "COMPLETED")
  expect_equal(run_stop$stage_states[["s_cleanup"]], "COMPLETED")

  # 2b. stop_on_failure = FALSE: allows downstream afterok stage to continue with partial/NULL upstream
  run_cont <- slurm_pipeline_run(p_fail, backend = be, wait = TRUE, poll_interval = 0.05, stop_on_failure = FALSE)
  expect_equal(run_cont$stage_states[["s_fail"]], "FAILED")
  expect_equal(run_cont$stage_states[["s_ok_dep"]], "COMPLETED")
  expect_equal(run_cont$stage_states[["s_recover"]], "COMPLETED")
  expect_equal(run_cont$stage_states[["s_cleanup"]], "COMPLETED")

  # 3. Dynamic args_from_upstream returning 0 tasks marks stage SKIPPED cleanly
  p_empty <- slurm_pipeline(
    name = "m2_empty_dynamic",
    slurm_stage("s1", fun = function(x) x, args_list = list(1), resources = resource_spec(1L, 1L)),
    slurm_stage(
      "s_zero",
      fun = function(x) x,
      args_from_upstream = function(up) list(),
      depends_on = "s1"
    ),
    slurm_stage(
      "s_after",
      fun = function(x) "done",
      args_list = list(1),
      resources = resource_spec(1L, 1L),
      depends_on = "s_zero",
      dependency_type = "afterany"
    )
  )
  run_empty <- slurm_pipeline_run(p_empty, backend = be, wait = TRUE, poll_interval = 0.05)
  expect_equal(run_empty$stage_states[["s1"]], "COMPLETED")
  expect_equal(run_empty$stage_states[["s_zero"]], "SKIPPED")
  expect_equal(run_empty$results[["s_zero"]], list())
  expect_equal(run_empty$stage_states[["s_after"]], "COMPLETED")
})

test_that("M3: slurm_efficiency_report handles missing chunk_id, Inf metrics, zero median wall, and 100%-failed jobs", {
  res <- resource_spec(n_tasks = 4L, chunk_size = 2L, mem_mb = 1024, time_minutes = 10)

  # 1. Missing chunk_id synthesized automatically
  df_noid <- data.frame(
    state = c("COMPLETED", "COMPLETED"),
    wall_sec = c(10, 20),
    peak_rss_mb = c(100, 120)
  )
  eff_noid <- slurm_efficiency_report(df_noid, resources = res)
  expect_equal(eff_noid$chunks$chunk_id, c(1L, 2L))

  # 2. Inf values sanitized so base plot never crashes
  df_inf <- data.frame(
    chunk_id = 1:2,
    state = c("COMPLETED", "COMPLETED"),
    wall_sec = c(Inf, 10),
    peak_rss_mb = c(100, Inf)
  )
  eff_inf <- slurm_efficiency_report(df_inf, resources = res)
  expect_true(is.finite(eff_inf$metrics$wall_max_sec))
  expect_true(is.finite(eff_inf$metrics$peak_rss_max_mb))
  tmp_pdf <- withr::local_tempfile(fileext = ".pdf")
  grDevices::pdf(tmp_pdf)
  on.exit(grDevices::dev.off(), add = TRUE)
  expect_no_error(plot(eff_inf, engine = "base"))

  # 3. Zero median with non-zero max yields Inf straggler ratio (not 1.0)
  df_zero <- data.frame(
    chunk_id = 1:3,
    state = rep("COMPLETED", 3L),
    wall_sec = c(0, 0, 10),
    peak_rss_mb = c(100, 100, 100)
  )
  eff_zero <- slurm_efficiency_report(df_zero, resources = res)
  expect_true(is.infinite(eff_zero$metrics$straggler_ratio))

  # 4. 100%-failed non-OOM/non-TIMEOUT job classified as "failed", never "efficient"
  df_fail <- data.frame(
    chunk_id = 1:2,
    state = c("FAILED", "FAILED"),
    wall_sec = c(NA_real_, NA_real_),
    peak_rss_mb = c(NA_real_, NA_real_)
  )
  eff_fail <- slurm_efficiency_report(df_fail, resources = res)
  expect_equal(eff_fail$classification, "failed")
})

test_that("M4: cran_repo rejects $VAR expansion and empty apt_packages produces valid %post", {
  env <- scan_project_env(extra_packages = "jsonlite")
  expect_error(
    build_apptainer_def(env, cran_repo = "https://example.com/$PATH/repo"),
    "shell|metacharacter|Unsafe|invalid",
    ignore.case = TRUE
  )

  env$apt_packages <- character(0L)
  def <- build_apptainer_def(env)
  expect_false(any(grepl("apt-get install", def$recipe, fixed = TRUE)))
  expect_false(any(grepl("apt-get update", def$recipe, fixed = TRUE)))
})

test_that("M5: bounded array expansion, fast squeue parsing, and sacct signal exit codes", {
  # Unbounded range rejected before allocating memory
  expect_error(
    parse_slurm_array_spec("1-100000000"),
    "max_indices",
    ignore.case = TRUE
  )
  expect_error(
    parse_slurm_array_spec("1-50", max_indices = 10L),
    "max_indices",
    ignore.case = TRUE
  )

  # Vectorized parse_squeue_output handles 2000-element array quickly
  t0 <- proc.time()[["elapsed"]]
  sq <- parse_squeue_output("12345_[1-2000]|PENDING|0:00||None")
  dt <- proc.time()[["elapsed"]] - t0
  expect_equal(nrow(sq), 2000L)
  expect_lt(dt, 1.0)

  # Signal exit codes in parse_sacct_output preserved via 128 + signal
  sa <- parse_sacct_output(c(
    "12345_1|OUT_OF_MEMORY|00:01:05|2048M|0:125",
    "12345_2|FAILED|00:00:10|512M|0:9",
    "12345_3|FAILED|00:00:05|256M|1:0",
    "12345_4|COMPLETED|00:00:05|256M|0:0"
  ))
  expect_equal(sa$exit_code, c(253L, 137L, 1L, 0L))
})

test_that("M6: mod_hpc_submit_server catches empty or failing args_builder without crashing Shiny session", {
  skip_if_not_installed("shiny")
  skip_if_not_installed("bslib")

  be <- mock_slurm_backend(max_workers = 1L)
  withr::defer(unlink(be$root_dir, recursive = TRUE, force = TRUE))

  # Empty args_builder
  expect_no_error(
    shiny::testServer(
      mod_hpc_submit_server,
      args = list(
        backend = be,
        fun = function(x) x,
        args_builder = function(n) list(),
        async_pilot = FALSE
      ),
      {
        session$setInputs(
          job_name = "m6_empty",
          n_tasks = 5L,
          n_pilot = 2L,
          max_chunk_size = 2L,
          cpus_per_task = 1L,
          mem_safety = 1.35,
          time_safety = 1.50
        )
        session$setInputs(run_pilot = 1L)
        expect_false(is_piloting_rv())
        expect_true(grepl("non-empty", pilot_msg_rv(), ignore.case = TRUE))

        session$setInputs(submit_job = 1L)
        expect_null(job_rv())
        expect_true(grepl("non-empty", pilot_msg_rv(), ignore.case = TRUE))
        html_out <- as.character(output$pilot_summary$html)
        expect_true(grepl("alert-danger", html_out, fixed = TRUE))
      }
    )
  )

  # Throwing args_builder
  expect_no_error(
    shiny::testServer(
      mod_hpc_submit_server,
      args = list(
        backend = be,
        fun = function(x) x,
        args_builder = function(n) stop("upstream source unavailable"),
        async_pilot = FALSE
      ),
      {
        session$setInputs(job_name = "m6_err", n_tasks = 4L, max_chunk_size = 2L, cpus_per_task = 1L)
        session$setInputs(submit_job = 1L)
        expect_null(job_rv())
        expect_true(grepl("upstream source unavailable", pilot_msg_rv(), fixed = TRUE))
      }
    )
  )
})

test_that("M7: scan_project_env ignores external symlinks escaping project root", {
  skip_on_os("windows")
  proj <- withr::local_tempdir()
  ext <- withr::local_tempdir()

  writeLines("library(jsonlite)", file.path(proj, "local.R"))
  ext_script <- file.path(ext, "external.R")
  writeLines("library(cmdstanr)", ext_script)
  file.symlink(ext_script, file.path(proj, "linked.R"))

  ext_desc <- file.path(ext, "DESCRIPTION")
  writeLines(c("Package: fake", "Imports: rjags"), ext_desc)
  file.symlink(ext_desc, file.path(proj, "DESCRIPTION"))

  env <- scan_project_env(path = proj)
  expect_true("jsonlite" %in% env$packages$package)
  expect_false("cmdstanr" %in% env$packages$package)
  expect_false("rjags" %in% env$packages$package)
})

test_that("M8: slurm_collect(simplify = TRUE) safely union-binds heterogeneous data frames", {
  be <- mock_slurm_backend(max_workers = 1L)
  withr::defer(unlink(be$root_dir, recursive = TRUE, force = TRUE))

  j <- slurm_submit(
    backend = be,
    fun = function(i) if (i == 1L) data.frame(a = 1, stringsAsFactors = FALSE) else data.frame(b = "two", stringsAsFactors = FALSE),
    args_list = list(1L, 2L),
    resources = resource_spec(2L, 2L)
  )
  st <- slurm_wait(j, poll_interval = 0.05)
  expect_equal(st$state, "COMPLETED")

  tbl <- slurm_collect(j, simplify = TRUE)
  expect_s3_class(tbl, "tbl_df")
  expect_equal(nrow(tbl), 2L)
  expect_equal(names(tbl), c("a", "b"))
  expect_equal(tbl$a, c(1, NA))
  expect_equal(tbl$b, c(NA_character_, "two"))
})

test_that("L1: standalone worker.R ignores ambient SLURMPILOT_MOCK_FAULT unless SLURMPILOT_BACKEND=mock", {
  d <- withr::local_tempdir()
  sp_stage_job_bundle(
    d,
    slurm_job_spec(function(x) x + 10L, list(1L), resource_spec(1L, 1L))
  )

  # Production run (no SLURMPILOT_BACKEND=mock): ambient SLURMPILOT_MOCK_FAULT=OOM is ignored
  env_prod <- Sys.getenv()
  env_prod <- env_prod[names(env_prod) != "SLURMPILOT_BACKEND"]
  env_prod[["SLURMPILOT_MOCK_FAULT"]] <- "OOM"

  r_prod <- processx::run(
    file.path(R.home("bin"), "Rscript"),
    args = c(file.path(d, "worker.R"), "--work-dir", d, "--chunk-id", "1"),
    env = env_prod,
    error_on_status = FALSE
  )
  expect_equal(r_prod$status, 0L)
  expect_true(file.exists(file.path(d, "results", "chunk_0001.rds")))

  # Mock backend run (SLURMPILOT_BACKEND=mock): SLURMPILOT_MOCK_FAULT=OOM triggers simulated 137 exit
  d2 <- withr::local_tempdir()
  sp_stage_job_bundle(
    d2,
    slurm_job_spec(function(x) x + 10L, list(1L), resource_spec(1L, 1L))
  )
  env_mock <- env_prod
  env_mock[["SLURMPILOT_BACKEND"]] <- "mock"
  r_mock <- processx::run(
    file.path(R.home("bin"), "Rscript"),
    args = c(file.path(d2, "worker.R"), "--work-dir", d2, "--chunk-id", "1"),
    env = env_mock,
    error_on_status = FALSE
  )
  expect_equal(r_mock$status, 137L)
})

test_that("L2: LPT chunking scales cleanly for both standard and >2048 chunk counts", {
  # 1. Standard SLURM array size (1000 chunks, 20k tasks)
  t0 <- proc.time()[["elapsed"]]
  p_std <- plan_chunks(20000L, chunk_size = 20L, strategy = "lpt", task_weights = seq_len(20000L))
  dt <- proc.time()[["elapsed"]] - t0
  expect_equal(nrow(p_std), 1000L)
  expect_equal(sum(p_std$n_tasks), 20000L)
  expect_lt(max(p_std$estimated_weight) / min(p_std$estimated_weight), 1.01)
  expect_lt(dt, 1.5)

  # 2. Very large chunk count (>2048 chunks) exercises binary min-heap branch
  p_heap <- plan_chunks(5000L, chunk_size = 2L, strategy = "lpt", task_weights = seq_len(5000L))
  expect_equal(nrow(p_heap), 2500L)
  expect_equal(sum(p_heap$n_tasks), 5000L)
  expect_equal(sort(unlist(p_heap$task_indices, use.names = FALSE)), seq_len(5000L))
  expect_lt(max(p_heap$estimated_weight) / min(p_heap$estimated_weight), 1.01)

  # 3. scale_resources preserves LPT chunk assignments without re-partitioning
  r_lpt <- resource_spec(8L, chunk_size = 2L, strategy = "lpt", task_weights = c(100, 90, 80, 10, 10, 10, 5, 5))
  r_bumped <- scale_resources(r_lpt, mem_multiplier = 2)
  expect_identical(r_bumped$chunks, r_lpt$chunks)
  expect_equal(r_bumped$strategy, "lpt")
})
