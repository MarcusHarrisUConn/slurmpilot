# HPC environment scanning and compiled toolchain detection

sp_base_packages <- function() {
  c(
    "R", "base", "compiler", "datasets", "graphics", "grDevices", "grid",
    "methods", "parallel", "splines", "stats", "stats4", "tcltk", "tools",
    "translations", "utils"
  )
}

#' Built-In Compiled Toolchain and System Dependency Registry
#'
#' Returns the curated mapping of R packages to compiled toolchains (`cpp`,
#' `cmdstan`, `rstan`, `tmb`, `jags`, `linear_algebra`, `spatial`, `http_ssl`,
#' `graphics`, `arrow`), Debian/Ubuntu `apt` system packages, and container
#' environment variables used by [scan_project_env()] and
#' [build_apptainer_def()].
#'
#' @return A named list of toolchain specification entries.
#' @export
#' @examples
#' reg <- toolchain_registry()
#' names(reg)
toolchain_registry <- function() {
  list(
    cpp = list(
      description = "C/C++ compilation toolchain (Rcpp/cpp11)",
      packages = c("Rcpp", "RcppArmadillo", "RcppEigen", "cpp11", "BH", "RcppParallel", "inline"),
      apt = c("build-essential", "g++", "gfortran", "cmake", "make"),
      env_vars = list(),
      needs_makevars = TRUE
    ),
    cmdstan = list(
      description = "CmdStan C++17 & Intel TBB toolchain",
      packages = c("cmdstanr"),
      apt = c("build-essential", "g++", "make", "libtbb-dev", "curl"),
      env_vars = list(CMDSTAN = "/opt/cmdstan"),
      needs_makevars = TRUE
    ),
    rstan = list(
      description = "rstan / StanHeaders / brms toolchain",
      packages = c("rstan", "StanHeaders", "brms", "rstanarm", "posterior"),
      apt = c("build-essential", "g++", "make", "libtbb-dev", "libv8-dev"),
      env_vars = list(),
      needs_makevars = TRUE
    ),
    tmb = list(
      description = "TMB / RTMB automatic differentiation C++ toolchain",
      packages = c("TMB", "RTMB", "glmmTMB", "sdmTMB"),
      apt = c("build-essential", "g++", "make", "libopenblas-dev", "liblapack-dev"),
      env_vars = list(),
      needs_makevars = TRUE
    ),
    jags = list(
      description = "JAGS Gibbs sampler runtime & headers",
      packages = c("rjags", "R2jags", "runjags", "jagsUI"),
      apt = c("jags", "libjags-dev"),
      env_vars = list(),
      needs_makevars = FALSE
    ),
    linear_algebra = list(
      description = "OpenBLAS / LAPACK / NLopt numerical libraries",
      packages = c("lme4", "Matrix", "nloptr", "minqa", "mgcv", "lavaan", "blavaan"),
      apt = c("libopenblas-dev", "liblapack-dev", "libnlopt-dev"),
      env_vars = list(),
      needs_makevars = FALSE
    ),
    spatial = list(
      description = "GDAL / GEOS / PROJ geospatial stack",
      packages = c("sf", "terra", "lwgeom", "stars", "s2"),
      apt = c("libgdal-dev", "libgeos-dev", "libproj-dev", "libudunits2-dev", "libsqlite3-dev"),
      env_vars = list(),
      needs_makevars = FALSE
    ),
    http_ssl = list(
      description = "libcurl / OpenSSL / libxml2 networking stack",
      packages = c("curl", "httr", "httr2", "openssl", "xml2", "gert", "git2r"),
      apt = c("libcurl4-openssl-dev", "libssl-dev", "libxml2-dev"),
      env_vars = list(),
      needs_makevars = FALSE
    ),
    graphics = list(
      description = "Modern font & raster graphics libraries",
      packages = c("ragg", "svglite", "systemfonts", "textshaping", "Cairo"),
      apt = c(
        "libfreetype6-dev", "libpng-dev", "libtiff5-dev", "libjpeg-dev",
        "libfontconfig1-dev", "libharfbuzz-dev", "libfribidi-dev"
      ),
      env_vars = list(),
      needs_makevars = FALSE
    ),
    arrow = list(
      description = "Arrow / DuckDB / data.table compression & OpenMP",
      packages = c("arrow", "duckdb", "data.table"),
      apt = c("zlib1g-dev", "libomp-dev"),
      env_vars = list(),
      needs_makevars = FALSE
    )
  )
}

sp_parse_renv_lock <- function(lock_path) {
  raw <- jsonlite::fromJSON(lock_path, simplifyVector = FALSE)
  r_version <- raw$R$Version %||% as.character(getRversion())
  pkgs_raw <- raw$Packages %||% list()

  if (length(pkgs_raw) == 0L) {
    pkgs <- tibble::tibble(
      package = character(),
      version = character(),
      source = character(),
      remote = character()
    )
  } else {
    rows <- lapply(pkgs_raw, function(entry) {
      pkg <- as.character(entry$Package %||% "")
      ver <- as.character(entry$Version %||% NA_character_)
      src <- as.character(entry$Source %||% "Repository")
      rem <- if (!is.null(entry$RemoteUsername) && !is.null(entry$RemoteRepo)) {
        paste0(
          entry$RemoteUsername, "/", entry$RemoteRepo,
          if (!is.null(entry$RemoteRef)) paste0("@", entry$RemoteRef) else ""
        )
      } else {
        NA_character_
      }
      tibble::tibble(
        package = pkg,
        version = ver,
        source = paste0("renv:", src),
        remote = rem
      )
    })
    pkgs <- do.call(rbind, rows)
    pkgs <- pkgs[nzchar(pkgs$package) & !(pkgs$package %in% sp_base_packages()), , drop = FALSE]
  }

  list(
    r_version = as.character(r_version),
    packages = pkgs
  )
}

sp_parse_description_file <- function(desc_path, include_suggests = FALSE) {
  dcf <- read.dcf(desc_path)
  if (nrow(dcf) == 0L) {
    return(character())
  }
  fields <- c("Depends", "Imports", "LinkingTo")
  if (isTRUE(include_suggests)) {
    fields <- c(fields, "Suggests")
  }
  found <- character()
  for (fld in fields) {
    if (fld %in% colnames(dcf)) {
      val <- dcf[1L, fld]
      if (!is.na(val) && nzchar(trimws(val))) {
        items <- strsplit(val, ",", fixed = TRUE)[[1L]]
        items <- trimws(sub("\\(.*\\)", "", items))
        items <- items[nzchar(items)]
        found <- c(found, items)
      }
    }
  }
  unique(setdiff(found, sp_base_packages()))
}

sp_parse_script_packages <- function(script_paths) {
  found <- character()
  for (sp in script_paths) {
    if (!file.exists(sp)) next
    lines <- tryCatch(readLines(sp, warn = FALSE), error = function(e) character())
    # Strip comments conservatively
    lines <- sub("#.*$", "", lines)
    text <- paste(lines, collapse = "\n")

    # library(pkg) / require(pkg) / requireNamespace("pkg")
    m1 <- gregexpr(
      "(?:library|require|requireNamespace)\\s*\\(\\s*['\"]?([A-Za-z][A-Za-z0-9.]+)['\"]?",
      text,
      perl = TRUE
    )
    matches1 <- regmatches(text, m1)[[1L]]
    if (length(matches1) > 0L) {
      pkgs1 <- sub(
        "^(?:library|require|requireNamespace)\\s*\\(\\s*['\"]?([A-Za-z][A-Za-z0-9.]+)['\"]?.*$",
        "\\1",
        matches1,
        perl = TRUE
      )
      found <- c(found, pkgs1)
    }

    # pkg::fn or pkg:::fn
    m2 <- gregexpr("\\b([A-Za-z][A-Za-z0-9.]+):{2,3}[A-Za-z._]", text, perl = TRUE)
    matches2 <- regmatches(text, m2)[[1L]]
    if (length(matches2) > 0L) {
      pkgs2 <- sub("^([A-Za-z][A-Za-z0-9.]+):{2,3}.*$", "\\1", matches2, perl = TRUE)
      found <- c(found, pkgs2)
    }
  }
  unique(setdiff(found, sp_base_packages()))
}

#' Scan an R Project for Package Dependencies and Compiled HPC Toolchains
#'
#' Inspects `renv.lock`, `DESCRIPTION`, and R/Rmd/Quarto source scripts to build
#' a unified manifest of R packages, R version, compiled toolchains (`Rcpp`,
#' `cmdstanr`, `RTMB`, `TMB`, `rstan`, `JAGS`, `sf`, etc.), and required
#' Debian/Ubuntu system libraries for container packaging via
#' [build_apptainer_def()].
#'
#' @param path Optional project root directory to scan automatically.
#' @param renv_lock Optional explicit path to an `renv.lock` file.
#' @param description Optional explicit path to a `DESCRIPTION` file.
#' @param scripts Optional character vector of `.R`, `.Rmd`, or `.qmd` script
#'   paths to scan for package imports.
#' @param extra_packages Character vector of additional R packages to include
#'   explicitly.
#' @param include_suggests Logical; if `TRUE`, also includes `Suggests` from
#'   `DESCRIPTION`. Default `FALSE`.
#'
#' @return An S3 object of class `"slurmpilot_env"` containing `r_version`,
#'   `packages` (a tibble), `toolchains`, `apt_packages`, `env_vars`,
#'   `needs_makevars`, `has_renv_lock`, `renv_lock_path`, `sources_scanned`,
#'   and `env_hash`.
#'
#' @seealso [toolchain_registry()], [build_apptainer_def()]
#' @export
#' @examples
#' env <- scan_project_env(extra_packages = c("lme4", "cmdstanr", "Rcpp"))
#' print(env)
scan_project_env <- function(
  path = NULL,
  renv_lock = NULL,
  description = NULL,
  scripts = NULL,
  extra_packages = character(),
  include_suggests = FALSE
) {
  if (!is.null(path)) {
    checkmate::assert_directory_exists(path)
    if (is.null(renv_lock)) {
      cand <- file.path(path, "renv.lock")
      if (file.exists(cand)) renv_lock <- cand
    }
    if (is.null(description)) {
      cand <- file.path(path, "DESCRIPTION")
      if (file.exists(cand)) description <- cand
    }
    if (is.null(scripts)) {
      all_files <- list.files(
        path,
        pattern = "\\.(R|r|Rmd|qmd)$",
        recursive = TRUE,
        full.names = TRUE
      )
      # Exclude noisy directories
      keep <- !grepl("(^|/)(\\.git|renv|packrat|docs|_site|\\.Rcheck)(/|$)", all_files)
      scripts <- all_files[keep]
    }
  }

  checkmate::assert_character(extra_packages, any.missing = FALSE)
  checkmate::assert_flag(include_suggests)

  sources_scanned <- character()
  r_version <- as.character(getRversion())
  pkg_table <- tibble::tibble(
    package = character(),
    version = character(),
    source = character(),
    remote = character()
  )

  has_renv <- FALSE
  if (!is.null(renv_lock)) {
    checkmate::assert_file_exists(renv_lock)
    parsed_lock <- sp_parse_renv_lock(renv_lock)
    r_version <- parsed_lock$r_version
    pkg_table <- rbind(pkg_table, parsed_lock$packages)
    has_renv <- TRUE
    sources_scanned <- c(sources_scanned, paste0("renv.lock:", basename(renv_lock)))
  }

  if (!is.null(description)) {
    checkmate::assert_file_exists(description)
    desc_pkgs <- sp_parse_description_file(description, include_suggests = include_suggests)
    if (length(desc_pkgs) > 0L) {
      pkg_table <- rbind(
        pkg_table,
        tibble::tibble(
          package = desc_pkgs,
          version = NA_character_,
          source = "DESCRIPTION",
          remote = NA_character_
        )
      )
    }
    sources_scanned <- c(sources_scanned, paste0("DESCRIPTION:", basename(description)))
  }

  if (!is.null(scripts) && length(scripts) > 0L) {
    script_pkgs <- sp_parse_script_packages(scripts)
    if (length(script_pkgs) > 0L) {
      pkg_table <- rbind(
        pkg_table,
        tibble::tibble(
          package = script_pkgs,
          version = NA_character_,
          source = "script",
          remote = NA_character_
        )
      )
    }
    sources_scanned <- c(sources_scanned, sprintf("scripts(%d)", length(scripts)))
  }

  extra_clean <- unique(setdiff(trimws(extra_packages), c("", sp_base_packages())))
  if (length(extra_clean) > 0L) {
    sp_assert_safe_r_package(extra_clean, arg = "extra_packages")
    pkg_table <- rbind(
      pkg_table,
      tibble::tibble(
        package = extra_clean,
        version = NA_character_,
        source = "explicit",
        remote = NA_character_
      )
    )
    sources_scanned <- c(sources_scanned, "explicit")
  }

  # Deduplicate preserving first (highest-priority) source
  if (nrow(pkg_table) > 0L) {
    pkg_table <- pkg_table[!duplicated(pkg_table$package), , drop = FALSE]
    pkg_table <- pkg_table[order(pkg_table$package), , drop = FALSE]
  }

  reg <- toolchain_registry()
  detected_toolchains <- character()
  apt_pkgs <- c("ca-certificates")
  env_vars <- list()
  needs_makevars <- FALSE

  pkg_names <- pkg_table$package
  for (tc_name in names(reg)) {
    spec <- reg[[tc_name]]
    if (any(pkg_names %in% spec$packages)) {
      detected_toolchains <- c(detected_toolchains, tc_name)
      apt_pkgs <- c(apt_pkgs, spec$apt)
      if (length(spec$env_vars) > 0L) {
        env_vars <- utils::modifyList(env_vars, spec$env_vars)
      }
      if (isTRUE(spec$needs_makevars)) {
        needs_makevars <- TRUE
      }
    }
  }

  apt_pkgs <- sort(unique(apt_pkgs))
  env_hash <- substr(
    digest::digest(list(
      r_version = r_version,
      packages = pkg_table$package,
      versions = pkg_table$version,
      toolchains = detected_toolchains,
      apt_packages = apt_pkgs
    ), algo = "sha256"),
    1L, 12L
  )

  structure(
    list(
      r_version = r_version,
      packages = pkg_table,
      toolchains = detected_toolchains,
      apt_packages = apt_pkgs,
      env_vars = env_vars,
      needs_makevars = needs_makevars,
      has_renv_lock = has_renv,
      renv_lock_path = renv_lock,
      sources_scanned = sources_scanned,
      env_hash = env_hash
    ),
    class = "slurmpilot_env"
  )
}

#' @export
print.slurmpilot_env <- function(x, ...) {
  cli::cli_h3("slurmpilot HPC Environment Manifest")
  tc_str <- if (length(x$toolchains) > 0L) paste(x$toolchains, collapse = ", ") else "none (pure R)"
  cli::cli_bullets(c(
    "*" = "R version: {x$r_version} (env hash: {x$env_hash})",
    "*" = "Packages detected: {nrow(x$packages)} (renv.lock: {x$has_renv_lock})",
    "*" = "Compiled toolchains: {tc_str}",
    "*" = "System apt packages ({length(x$apt_packages)}): {paste(head(x$apt_packages, 8L), collapse = ', ')}{if (length(x$apt_packages) > 8L) ', ...' else ''}"
  ))
  invisible(x)
}
