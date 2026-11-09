# stance.qmd's code, purled and run against the mock in a fresh R
# process. Its config is pointed at the mock and a made-up corpus, and its
# paths at a temporary folder, so the real inputs/ and outputs/ are untouched.

test_that("stance.qmd's code runs end to end against the mock", {
  tmp <- withr::local_tempdir()
  dir.create(file.path(tmp, "in"))
  dir.create(file.path(tmp, "out"))
  # 5 periods of 40 passages, enough for a trend
  n <- 200
  lab <- withr::with_seed(3, sample(c("favor", "neutral", "oppose", "irrelevant"), n, TRUE,
                                    c(.4, .2, .2, .2)))
  readr::write_csv(tibble::tibble(id = paste0("d", (seq_len(n) - 1) %/% 4), period = rep(2020:2024, 40),
                                  text = passage(lab)), file.path(tmp, "in", "corpus.csv"))
  script <- file.path(tmp, "stance.R")
  knitr::purl(file.path(stance_dir, "stance.qmd"), script, quiet = TRUE, documentation = 0)
  src <- readLines(script)
  set <- function(src, field, value) sub(paste0("^(\\s*", field, " = )[^,]+,"), paste0("\\1", value, ","), src)
  src <- set(src, "file", "\"corpus.csv\"")
  src <- set(src, "name", "\"test\"")
  src <- set(src, "url", deparse(mock$url("/v1")))
  src <- set(src, "model", "\"opus-test\"")
  src <- set(src, "workers", "3L")
  hook <- grep("source(here::here(\"stance\", \"stance_source.R\"))", src, fixed = TRUE)
  expect_length(hook, 1)
  src <- append(src, sprintf("p_in <- function(f) file.path(%s, f); p_out <- function(f) file.path(%s, f)",
                             deparse(file.path(tmp, "in")), deparse(file.path(tmp, "out"))), hook)
  writeLines(c("grDevices::pdf(NULL)  # plots go nowhere, not to Rplots.pdf", src), script)
  log <- file.path(tmp, "log.txt")
  status <- withr::with_dir(dirname(stance_dir), withr::with_envvar(
    c(STANCE_KEY = GOOD), system2(file.path(R.home("bin"), "Rscript"), shQuote(script),
                                  stdout = log, stderr = log)))
  expect_equal(status, 0, info = paste(readLines(log), collapse = "\n"))
  labels <- readr::read_csv(file.path(tmp, "out", "stance_labels_test.csv"), show_col_types = FALSE)
  expect_equal(nrow(labels), n)
  expect_equal(labels$label[order(labels$stance_row)], lab)
  est <- readr::read_csv(file.path(tmp, "out", "stance_estimates_test.csv"), show_col_types = FALSE)
  expect_equal(unique(est$model), "opus-test")
  expect_equal(unique(est$estimate), "trend")
  expect_false(any(grepl(GOOD, c(readLines(log), readLines(file.path(tmp, "out", "stance_prompt_test.txt"))),
                         fixed = TRUE)))
  # the real outputs were not touched
  expect_false(file.exists(file.path(stance_dir, "outputs", "stance_labels_test.csv")))
})
