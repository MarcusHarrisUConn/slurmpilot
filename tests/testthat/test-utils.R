test_that("SLURM time formatting and parsing round-trip cleanly", {
  expect_equal(format_slurm_time(0), "00:00:00")
  expect_equal(format_slurm_time(65), "00:01:05")
  expect_equal(format_slurm_time(3665), "01:01:05")
  expect_equal(format_slurm_time(90061), "1-01:01:01")

  expect_equal(
    parse_slurm_time(c("05:30", "01:15:00", "2-03:00:10", "1-12:00", "UNLIMITED", "")),
    c(330, 4500, 2 * 86400 + 3 * 3600 + 10, 86400 + 12 * 3600, NA_real_, NA_real_)
  )
  expect_equal(parse_slurm_time(character()), numeric())
})

test_that("SLURM memory formatting and parsing work across units", {
  expect_equal(format_slurm_mem(512), "512M")
  expect_equal(format_slurm_mem(1024), "1G")
  expect_equal(format_slurm_mem(1536), "1536M")
  expect_equal(format_slurm_mem(4096), "4G")

  parsed <- parse_slurm_mem(c("0", "1048576B", "524288K", "1024M", "2G", "0.5T", "NA", ""))
  expect_equal(parsed[1:6], c(0, 1, 512, 1024, 2048, 524288))
  expect_true(all(is.na(parsed[7:8])))
})

test_that("SLURM array index compression and expansion are inverses", {
  expect_equal(format_slurm_array_indices(c(1, 2, 3, 5, 8, 9, 10)), "1-3,5,8-10")
  expect_equal(format_slurm_array_indices(c(7, 2, 2, 3), max_concurrent = 2), "2-3,7%2")
  expect_equal(format_slurm_array_indices(4L), "4")

  expect_equal(sp_expand_slurm_array_expr("[1-3,5,8-10%4]"), c(1L, 2L, 3L, 5L, 8L, 9L, 10L))
  expect_equal(sp_expand_slurm_array_expr("2-6:2"), c(2L, 4L, 6L))
})

test_that("SLURM state normalization and aggregate state derivation work", {
  expect_equal(sp_normalize_slurm_state("PD"), "PENDING")
  expect_equal(sp_normalize_slurm_state("R"), "RUNNING")
  expect_equal(sp_normalize_slurm_state("CD"), "COMPLETED")
  expect_equal(sp_normalize_slurm_state("OOM"), "OUT_OF_MEMORY")
  expect_equal(sp_normalize_slurm_state("TO"), "TIMEOUT")
  expect_equal(sp_normalize_slurm_state("CANCELLED by 1042"), "CANCELLED")
  expect_equal(sp_normalize_slurm_state("NODE_FAIL+"), "FAILED")

  expect_equal(sp_aggregate_job_state(c("COMPLETED", "RUNNING")), "RUNNING")
  expect_equal(sp_aggregate_job_state(c("COMPLETED", "PENDING")), "PENDING")
  expect_equal(sp_aggregate_job_state(c("COMPLETED", "COMPLETED")), "COMPLETED")
  expect_equal(sp_aggregate_job_state(c("CANCELLED", "CANCELLED")), "CANCELLED")
  expect_equal(sp_aggregate_job_state(c("COMPLETED", "OUT_OF_MEMORY")), "PARTIAL_FAILURE")
  expect_equal(sp_aggregate_job_state(c("FAILED", "TIMEOUT")), "FAILED")
})
