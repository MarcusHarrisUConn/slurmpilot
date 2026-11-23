# Apptainer / Singularity container definition recipe generator

#' Build a Reproducible Apptainer/Singularity `.def` Recipe
#'
#' Generates an HPC-ready Apptainer (formerly Singularity) container definition
#' file from a [scan_project_env()] manifest (or project directory path).
#' Automatically includes minimal Debian/Ubuntu system libraries for detected
#' compiled toolchains (`Rcpp`, `cmdstanr`, `RTMB`, `TMB`, `JAGS`, `sf`, etc.),
#' thread-safe BLAS/OpenMP defaults, `renv::restore()` or pinned CRAN installs,
#' optional CmdStan installation, and container smoke tests (`%test`).
#'
#' @param env A `slurmpilot_env` object from [scan_project_env()], or a path to
#'   a project directory to scan automatically.
#' @param base_image Optional Docker base image (defaults to
#'   `"rocker/r-ver:<r_version>"`).
#' @param r_version Optional R version string overriding `env$r_version`.
#' @param output_path Optional file path to write the `.def` recipe to disk.
#' @param install_cmdstan Optional logical controlling whether to build CmdStan
#'   inside `/opt/cmdstan`. Defaults to `"cmdstan" %in% env$toolchains`.
#' @param cmdstan_version Character CmdStan version when `install_cmdstan` is
#'   `TRUE`. Default `"2.35.0"`.
#' @param renv_restore Optional logical; if `TRUE`, copies `renv.lock` via
#'   `%files` and runs `renv::restore()`. Defaults to `env$has_renv_lock`.
#' @param cran_repo CRAN/Posit Package Manager repository URL used inside
#'   `%post`.
#' @param image_name Target `.sif` filename used in the suggested build command.
#'   Default `"slurmpilot_env.sif"`.
#' @param labels Optional named list of extra `%labels` entries.
#' @param extra_apt Optional character vector of extra Debian/Ubuntu apt
#'   packages.
#' @param extra_post Optional character vector of extra shell lines appended to
#'   `%post` before apt cache cleanup.
#'
#' @return An S3 object of class `"slurmpilot_apptainer_def"` containing
#'   `recipe` (character vector of lines), `text` (single string), `path`,
#'   `base_image`, `image_name`, `build_command`, and `env`.
#'
#' @seealso [scan_project_env()], [render_sbatch_script()]
#' @export
#' @examples
#' env <- scan_project_env(extra_packages = c("lme4", "Rcpp", "RTMB"))
#' def <- build_apptainer_def(env)
#' cat(def$text)
build_apptainer_def <- function(
  env,
  base_image = NULL,
  r_version = NULL,
  output_path = NULL,
  install_cmdstan = NULL,
  cmdstan_version = "2.35.0",
  renv_restore = NULL,
  cran_repo = "https://packagemanager.posit.co/cran/__linux__/jammy/latest",
  image_name = "slurmpilot_env.sif",
  labels = list(),
  extra_apt = character(),
  extra_post = character()
) {
  if (is.character(env) && length(env) == 1L) {
    env <- scan_project_env(path = env)
  }
  checkmate::assert_class(env, "slurmpilot_env")
  if (!is.null(base_image)) checkmate::assert_string(base_image, min.chars = 1L)
  if (!is.null(r_version)) checkmate::assert_string(r_version, min.chars = 1L)
  if (!is.null(output_path)) checkmate::assert_string(output_path, min.chars = 1L)
  if (!is.null(install_cmdstan)) checkmate::assert_flag(install_cmdstan)
  checkmate::assert_string(cmdstan_version, min.chars = 1L)
  if (!is.null(renv_restore)) checkmate::assert_flag(renv_restore)
  checkmate::assert_string(cran_repo, min.chars = 1L)
  checkmate::assert_string(image_name, min.chars = 1L)
  checkmate::assert_list(labels)
  checkmate::assert_character(extra_apt, any.missing = FALSE)
  checkmate::assert_character(extra_post, any.missing = FALSE)

  r_ver <- r_version %||% env$r_version
  sp_assert_safe_version(r_ver, arg = "r_version")
  from_img <- base_image %||% paste0("rocker/r-ver:", r_ver)
  sp_assert_safe_docker_image(from_img, arg = "base_image")
  sp_assert_safe_version(cmdstan_version, arg = "cmdstan_version")
  sp_assert_safe_url(cran_repo, arg = "cran_repo")
  sp_assert_safe_relpath(image_name, arg = "image_name")
  if (!is.null(output_path)) {
    sp_assert_no_control_chars(output_path, arg = "output_path")
    if (grepl("(^|[/\\\\])\\.\\.([/\\\\]|$)", output_path)) {
      cli::cli_abort("Path traversal ('..') is forbidden in {.arg output_path}: {.val {output_path}}.")
    }
  }
  if (nrow(env$packages) > 0L) {
    sp_assert_safe_r_package(env$packages$package, arg = "env$packages")
  }
  if (length(extra_apt) > 0L) {
    sp_assert_safe_apt_package(extra_apt, arg = "extra_apt")
  }
  if (length(extra_post) > 0L) {
    sp_assert_safe_apptainer_post(extra_post, arg = "extra_post")
  }
  if (length(labels) > 0L) {
    checkmate::assert_named(labels, type = "unique")
    sp_assert_safe_env_name(names(labels), arg = "labels")
    for (nm in names(labels)) {
      sp_assert_no_control_chars(as.character(labels[[nm]]), arg = paste0("labels$", nm))
    }
  }
  if (length(env$env_vars) > 0L) {
    sp_assert_safe_env_name(names(env$env_vars), arg = "env$env_vars")
    for (nm in names(env$env_vars)) {
      sp_assert_no_control_chars(as.character(env$env_vars[[nm]]), arg = paste0("env$env_vars$", nm))
    }
  }

  do_cmdstan <- if (is.null(install_cmdstan)) "cmdstan" %in% env$toolchains else isTRUE(install_cmdstan)
  do_renv <- if (is.null(renv_restore)) isTRUE(env$has_renv_lock) else isTRUE(renv_restore)

  apt_all <- sort(unique(c(env$apt_packages, extra_apt)))
  if (do_cmdstan) {
    apt_all <- sort(unique(c(apt_all, "build-essential", "g++", "make", "libtbb-dev", "curl")))
  }
  sp_assert_safe_apt_package(apt_all, arg = "apt_packages")

  # Header
  lines <- c(
    "Bootstrap: docker",
    paste0("From: ", from_img),
    ""
  )

  # Labels
  all_labels <- utils::modifyList(
    list(
      GeneratedBy = "slurmpilot",
      RVersion = r_ver,
      Toolchains = if (length(env$toolchains) > 0L) paste(env$toolchains, collapse = ",") else "base",
      EnvHash = env$env_hash
    ),
    labels
  )
  lines <- c(lines, "%labels")
  for (nm in names(all_labels)) {
    lines <- c(lines, sprintf("    %s %s", nm, as.character(all_labels[[nm]])))
  }
  lines <- c(lines, "")

  # Files (when restoring renv.lock)
  if (do_renv) {
    lock_src <- if (!is.null(env$renv_lock_path)) basename(env$renv_lock_path) else "renv.lock"
    sp_assert_safe_relpath(lock_src, arg = "renv_lock_path")
    lines <- c(
      lines,
      "%files",
      sprintf("    %s /opt/slurmpilot/renv.lock", lock_src),
      ""
    )
  }

  # Environment
  env_map <- utils::modifyList(
    list(
      LC_ALL = "C.UTF-8",
      LANG = "C.UTF-8",
      OMP_NUM_THREADS = "1",
      OPENBLAS_NUM_THREADS = "1",
      MKL_NUM_THREADS = "1",
      R_REMOTES_NO_ERRORS_FROM_WARNINGS = "true"
    ),
    env$env_vars
  )
  if (do_cmdstan) {
    env_map$CMDSTAN <- "/opt/cmdstan"
  }
  sp_assert_safe_env_name(names(env_map), arg = "environment")
  lines <- c(lines, "%environment")
  for (nm in names(env_map)) {
    val_str <- as.character(env_map[[nm]])
    sp_assert_no_control_chars(val_str, arg = paste0("environment$", nm))
    formatted_val <- if (grepl("^[A-Za-z0-9_./:-]+$", val_str)) val_str else sp_sh_quote(val_str)
    lines <- c(lines, sprintf("    export %s=%s", nm, formatted_val))
  }
  lines <- c(lines, "")

  # Post installation
  lines <- c(
    lines,
    "%post",
    "    set -eu",
    "    export DEBIAN_FRONTEND=noninteractive",
    "    apt-get update && apt-get install -y --no-install-recommends \\"
  )
  for (i in seq_along(apt_all)) {
    suffix <- if (i < length(apt_all)) " \\" else ""
    lines <- c(lines, paste0("        ", apt_all[[i]], suffix))
  }
  lines <- c(lines, "")

  if (isTRUE(env$needs_makevars) || do_cmdstan) {
    lines <- c(
      lines,
      "    mkdir -p /root/.R",
      "    cat <<'EOF' > /root/.R/Makevars",
      "CXX17 = g++",
      "CXX17FLAGS = -O3 -fPIC",
      "CXX17STD = -std=c++17",
      "EOF",
      ""
    )
  }

  if (do_renv) {
    lines <- c(
      lines,
      "    mkdir -p /opt/slurmpilot",
      sprintf(
        "    Rscript -e \"install.packages('renv', repos = '%s')\"",
        cran_repo
      ),
      "    Rscript -e \"renv::restore(lockfile = '/opt/slurmpilot/renv.lock', prompt = FALSE)\"",
      ""
    )
  } else if (nrow(env$packages) > 0L) {
    pkgs_install <- setdiff(env$packages$package, "cmdstanr")
    if (length(pkgs_install) > 0L) {
      pkg_vec <- paste(sprintf("'%s'", pkgs_install), collapse = ", ")
      lines <- c(
        lines,
        sprintf(
          "    Rscript -e \"install.packages(c(%s), repos = '%s', Ncpus = max(1L, parallel::detectCores() - 1L))\"",
          pkg_vec, cran_repo
        ),
        ""
      )
    }
    if ("cmdstanr" %in% env$packages$package || do_cmdstan) {
      lines <- c(
        lines,
        sprintf(
          "    Rscript -e \"install.packages('cmdstanr', repos = c('https://stan-dev.r-universe.dev', '%s'))\"",
          cran_repo
        ),
        ""
      )
    }
  }

  if (do_cmdstan) {
    lines <- c(
      lines,
      "    mkdir -p /opt/cmdstan",
      sprintf(
        "    Rscript -e \"cmdstanr::install_cmdstan(dir = '/opt/cmdstan', version = '%s', cores = max(1L, parallel::detectCores() - 1L), overwrite = TRUE)\"",
        cmdstan_version
      ),
      "    chmod -R a+rX /opt/cmdstan",
      ""
    )
  }

  if (length(extra_post) > 0L) {
    lines <- c(lines, paste0("    ", extra_post), "")
  }

  lines <- c(
    lines,
    "    apt-get clean",
    "    rm -rf /var/lib/apt/lists/*",
    ""
  )

  # Test section
  test_pkgs <- head(env$packages$package, 10L)
  lines <- c(lines, "%test", "    Rscript -e \"cat('R:', R.version.string, '\\n')\"")
  if (length(test_pkgs) > 0L) {
    pkg_vec <- paste(sprintf("'%s'", test_pkgs), collapse = ", ")
    lines <- c(
      lines,
      sprintf(
        "    Rscript -e \"stopifnot(all(vapply(c(%s), requireNamespace, logical(1L), quietly = TRUE)))\"",
        pkg_vec
      )
    )
  }
  if (do_cmdstan) {
    lines <- c(
      lines,
      "    Rscript -e \"cmdstanr::set_cmdstan_path('/opt/cmdstan'); cat('CmdStan:', cmdstanr::cmdstan_version(), '\\n')\""
    )
  }
  lines <- c(lines, "", "%runscript", "    exec Rscript \"$@\"")

  def_name <- if (!is.null(output_path)) basename(output_path) else sub("\\.sif$", ".def", image_name)
  if (!grepl("\\.def$", def_name)) {
    def_name <- paste0(def_name, ".def")
  }
  build_cmd <- sprintf("apptainer build %s %s", image_name, def_name)

  if (!is.null(output_path)) {
    sp_write_lines_atomic(lines, output_path)
  }

  structure(
    list(
      recipe = lines,
      text = paste(lines, collapse = "\n"),
      path = output_path,
      base_image = from_img,
      image_name = image_name,
      build_command = build_cmd,
      install_cmdstan = do_cmdstan,
      renv_restore = do_renv,
      env = env
    ),
    class = "slurmpilot_apptainer_def"
  )
}

#' @export
as.character.slurmpilot_apptainer_def <- function(x, ...) {
  x$text
}

#' @export
print.slurmpilot_apptainer_def <- function(x, ...) {
  cli::cli_h3("slurmpilot Apptainer Definition")
  cli::cli_bullets(c(
    "*" = "Base image: {x$base_image}",
    "*" = "Packages: {nrow(x$env$packages)} | renv restore: {x$renv_restore} | CmdStan: {x$install_cmdstan}",
    "*" = "Lines: {length(x$recipe)} | Build: {.code {x$build_command}}"
  ))
  if (!is.null(x$path)) {
    cli::cli_bullets(c("v" = "Written to: {.path {x$path}}"))
  }
  invisible(x)
}
