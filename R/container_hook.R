# Zero-dependency Apptainer / rcapsule container integration hook

#' Attach a Validated Apptainer or `rcapsule` Container to a SLURM Job Spec
#'
#' Provides a zero-hard-dependency handoff between reproducible container
#' builders (such as `rcapsule` manifests/specs, [build_apptainer_def()]
#' recipes, or pre-built `.sif` / `.def` file paths) and [slurm_job_spec()].
#' Strictly validates all container paths and `--bind` mounts against traversal
#' and shell/option injection, records provenance metadata (`digest`,
#' `r_version`, `def_path`, `source`), and injects `SLURMPILOT_CONTAINER_DIGEST`
#' into the job environment when a cryptographic digest is supplied.
#'
#' @param spec Optional `slurmpilot_job_spec` object to update. When `NULL`,
#'   returns a standalone validated `"slurmpilot_container_spec"` object.
#' @param container Container descriptor: either (a) a character path to an
#'   Apptainer `.sif` image or `.def` recipe, (b) a `slurmpilot_apptainer_def`
#'   object from [build_apptainer_def()], or (c) a duck-typed `rcapsule` spec
#'   or manifest list containing fields such as `apptainer_sif` / `sif_path` /
#'   `image`, `apptainer_def` / `def_path` / `recipe_path`, `content_digest` /
#'   `capsule_hash` / `env_hash`, `r_version`, `binds`, or nested
#'   `targets$apptainer` / `manifest`.
#' @param binds Optional character vector of extra Apptainer `--bind` mounts
#'   (e.g. `"/data:/data:ro"`).
#' @param check_exists Logical; if `TRUE`, asserts that any resolved local
#'   `.sif` or `.def` path exists on disk. Default `FALSE` (cluster paths often
#'   exist only on the remote HPC filesystem).
#'
#' @return Updated `slurmpilot_job_spec` (when `spec` is supplied) or a
#'   `"slurmpilot_container_spec"` object (when `spec` is `NULL`).
#' @seealso [slurm_job_spec()], [build_apptainer_def()], [render_sbatch_script()]
#' @export
#' @examples
#' spec <- slurm_job_spec(
#'   fun = function(x) x + 1,
#'   args_list = list(1, 2),
#'   resources = resource_spec(2L)
#' )
#' capsule <- list(
#'   sif_path = "/scratch/containers/analysis.sif",
#'   def_path = "/scratch/containers/analysis.def",
#'   content_digest = "a1b2c3d4e5f6",
#'   r_version = "4.4.1",
#'   binds = c("/scratch/data:/data:ro")
#' )
#' spec2 <- use_rcapsule_container(spec, capsule)
#' spec2$container_sif
use_rcapsule_container <- function(
  spec = NULL,
  container,
  binds = character(),
  check_exists = FALSE
) {
  if (!is.null(spec)) {
    checkmate::assert_class(spec, "slurmpilot_job_spec")
  }
  sp_assert_safe_apptainer_bind(binds, arg = "binds")
  checkmate::assert_flag(check_exists)

  sif_path <- NULL
  def_path <- NULL
  source_kind <- "path"
  digest_val <- NULL
  r_ver <- NULL
  base_img <- NULL
  build_cmd <- NULL
  extra_binds <- character(0L)

  if (is.character(container) && length(container) == 1L) {
    sp_assert_safe_path(container, arg = "container", allow_tilde = FALSE, allow_relative = FALSE)
    if (grepl("\\.def$", container, ignore.case = TRUE)) {
      def_path <- container
      sif_path <- sub("\\.def$", ".sif", container, ignore.case = TRUE)
      source_kind <- "apptainer_def_path"
    } else if (grepl("\\.(sif|simg)$", container, ignore.case = TRUE)) {
      sif_path <- container
      source_kind <- "apptainer_sif_path"
    } else {
      cli::cli_abort("Character {.arg container} path must end with {.val .sif}, {.val .simg}, or {.val .def}: {.val {container}}.")
    }
  } else if (inherits(container, "slurmpilot_apptainer_def")) {
    source_kind <- "slurmpilot_apptainer_def"
    def_path <- container$path
    sif_path <- if (!is.null(def_path)) {
      file.path(dirname(def_path), container$image_name)
    } else {
      paste0("/opt/containers/", container$image_name)
    }
    digest_val <- container$env$env_hash
    r_ver <- container$env$r_version
    base_img <- container$base_image
    build_cmd <- container$build_command
  } else if (is.list(container)) {
    # Duck-typed rcapsule / container manifest object (zero hard dependency)
    source_kind <- if (inherits(container, "rcapsule") || inherits(container, "rcapsule_manifest") ||
                       inherits(container, "rcapsule_apptainer")) {
      "rcapsule"
    } else {
      "duck_typed_container"
    }
    ap_sub <- if (is.list(container$targets) && is.list(container$targets$apptainer)) {
      container$targets$apptainer
    } else {
      list()
    }
    man_sub <- if (is.list(container$manifest)) container$manifest else list()

    sif_path <- container$apptainer_sif %||% container$sif_path %||% container$image_path %||%
      ap_sub$sif_path %||% ap_sub$image_path %||% container$image
    def_path <- container$apptainer_def %||% container$def_path %||% container$recipe_path %||%
      ap_sub$def_path %||% ap_sub$path

    if (is.null(sif_path) && !is.null(def_path)) {
      sif_path <- sub("\\.def$", ".sif", def_path, ignore.case = TRUE)
    }
    if (is.null(sif_path)) {
      cli::cli_abort("Container object must supply at least one of {.field sif_path}, {.field apptainer_sif}, {.field def_path}, or {.field apptainer_def}.")
    }

    digest_val <- container$content_digest %||% container$capsule_hash %||% container$env_hash %||%
      man_sub$content_digest %||% man_sub$env_digest %||% ap_sub$digest
    r_ver <- container$r_version %||% man_sub$r_version %||% ap_sub$r_version
    base_img <- container$base_image %||% ap_sub$base_image
    build_cmd <- container$build_command %||% ap_sub$build_command
    if (!is.null(container$binds)) extra_binds <- as.character(container$binds)
    if (!is.null(ap_sub$binds)) extra_binds <- c(extra_binds, as.character(ap_sub$binds))
  } else {
    cli::cli_abort("{.arg container} must be a path string, {.cls slurmpilot_apptainer_def}, or duck-typed container list.")
  }

  # Strictly validate all resolved paths, binds, digest, and metadata
  sp_assert_safe_path(sif_path, arg = "sif_path", allow_tilde = FALSE, allow_relative = FALSE)
  if (!is.null(def_path)) {
    sp_assert_safe_path(def_path, arg = "def_path", allow_tilde = FALSE, allow_relative = FALSE)
  }
  all_binds <- unique(c(extra_binds, binds))
  sp_assert_safe_apptainer_bind(all_binds, arg = "binds")

  if (!is.null(digest_val)) {
    digest_val <- as.character(digest_val[[1L]])
    sp_assert_no_control_chars(digest_val, arg = "digest")
    if (!grepl("^[A-Za-z0-9:._-]{4,128}$", digest_val)) {
      cli::cli_abort("Invalid container provenance digest: {.val {digest_val}}.")
    }
  }
  if (!is.null(r_ver)) {
    sp_assert_safe_version(as.character(r_ver[[1L]]), arg = "r_version")
    r_ver <- as.character(r_ver[[1L]])
  }
  if (!is.null(base_img)) {
    sp_assert_safe_docker_image(as.character(base_img[[1L]]), arg = "base_image")
    base_img <- as.character(base_img[[1L]])
  }

  if (isTRUE(check_exists)) {
    target_check <- if (file.exists(sif_path)) sif_path else def_path
    if (is.null(target_check) || !file.exists(target_check)) {
      cli::cli_abort("Container artifact not found on disk: {.path {sif_path}}.")
    }
  }

  meta <- structure(
    list(
      sif_path = sif_path,
      def_path = def_path,
      binds = all_binds,
      source = source_kind,
      digest = digest_val,
      r_version = r_ver,
      base_image = base_img,
      build_command = build_cmd %||% if (!is.null(def_path)) sprintf("apptainer build %s %s", sif_path, def_path) else NULL
    ),
    class = "slurmpilot_container_spec"
  )

  if (is.null(spec)) {
    return(meta)
  }

  spec$container_sif <- meta$sif_path
  spec$container_binds <- unique(c(spec$container_binds %||% character(), meta$binds))
  spec$container_meta <- meta
  if (!is.null(meta$digest)) {
    ev <- spec$env_vars %||% list()
    ev$SLURMPILOT_CONTAINER_DIGEST <- meta$digest
    spec$env_vars <- ev
  }
  spec
}

#' @export
print.slurmpilot_container_spec <- function(x, ...) {
  cli::cli_h3("slurmpilot Container Specification ({x$source})")
  cli::cli_bullets(c(
    "*" = "Image (.sif): {.path {x$sif_path}}",
    "*" = "Recipe (.def): {if (is.null(x$def_path)) 'none' else x$def_path}",
    "*" = "Binds: {if (length(x$binds) > 0L) paste(x$binds, collapse = ', ') else 'work_dir only'}",
    "*" = "Provenance digest: {x$digest %||% 'none'} | R version: {x$r_version %||% 'unspecified'}"
  ))
  invisible(x)
}
