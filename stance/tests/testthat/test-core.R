# The method's building blocks: screening, preparing a file, parsing replies,
# and the estimates. No requests are sent here.

test_that("stance_screen keeps 5 to 250 words and says why it drops the rest", {
  words <- function(n) paste(rep("w", n), collapse = " ")
  s <- stance_screen(c(words(4), words(5), words(250), words(251), NA, ""))
  expect_equal(s$n_words, c(4, 5, 250, 251, 0, 0))
  expect_equal(s$keep, c(FALSE, TRUE, TRUE, FALSE, FALSE, FALSE))
  expect_equal(s$why, c("under 5 words", NA, NA, "over 250 words", "under 5 words", "under 5 words"))
  # runs of spaces, tabs, and newlines are not words
  expect_equal(stance_screen("one  two\tthree\nfour   five")$n_words, 5)
})

test_that("stance_prepare works with and without time and document columns", {
  raw <- tibble::tibble(txt = c(passage(c("favor", "oppose", "favor")), "too short"),
                        doc = c("a", "a", NA, "b"), yr = c(2020, 2021, 2021, NA))
  p <- stance_prepare(raw, "txt")
  expect_equal(p$cluster, paste("row", 1:4))
  expect_false("time" %in% names(p))
  expect_equal(p$keep, c(TRUE, TRUE, TRUE, FALSE))

  p <- stance_prepare(raw, "txt", time_col = "yr", doc_col = "doc")
  expect_equal(p$cluster, c("a", "a", NA, "b"))
  expect_equal(p$time, c(2020, 2021, 2021, NA))
  expect_equal(p$period, c("2020", "2021", "2021", NA))
  expect_equal(p$keep, c(TRUE, TRUE, FALSE, FALSE))
  expect_equal(p$why, c(NA, NA, "no document id", "under 5 words"))

  months <- stance_prepare(tibble::tibble(t = passage("favor"), m = "2026-08"), "t", "m")
  expect_equal(months$time, 2026 + 7 / 12)
  expect_equal(months$period, "2026-08")
  expect_error(stance_prepare(raw, "nope"), "No column named: nope")
})

test_that("stance_parse finds the label in untidy replies, for every scheme", {
  purrr::walk(stance_schemes, function(s) {
    codes <- stance_codes(s)
    purrr::walk(codes, function(l) {
      expect_equal(as.character(stance_parse(l, codes)), l)
      expect_equal(as.character(stance_parse(toupper(l), codes)), l)
      expect_equal(as.character(stance_parse(paste0("Label: ", l, "."), codes)), l)
      expect_equal(as.character(stance_parse(paste0("**", l, "**\n"), codes)), l)
    })
    # the first label word wins
    expect_equal(as.character(stance_parse(paste(codes[2], "or", codes[1]), codes)), codes[2])
    empty <- stance_parse("", codes)
    expect_true(is.na(empty))
    expect_match(attr(empty, "why"), "^no label in reply")
    expect_true(is.na(stance_parse(NULL, codes)))
    expect_true(is.na(stance_parse(NA_character_, codes)))
  })
  # a label from another scheme is no label, and a label inside a word does not count
  fav <- stance_codes(stance_scheme("favor"))
  expect_true(is.na(stance_parse("agree", fav)))
  expect_true(is.na(stance_parse("disagree", stance_codes(stance_scheme("align")))))
  expect_true(is.na(stance_parse("unfavorable", fav)))
  failed <- stance_parse(simpleError("HTTP 500"), fav)
  expect_true(is.na(failed))
  expect_equal(attr(failed, "why"), "request failed: HTTP 500")
})

# A coded file with a known share of each label in each period.
coded_file <- function(periods = 2018:2023, per = 40, seed = 7) {
  n <- length(periods) * per
  withr::with_seed(seed, tibble::tibble(
    label = sample(c("favor", "neutral", "oppose", "irrelevant"), n, TRUE, c(.4, .2, .2, .2)),
    cluster = paste0("doc", sample.int(n %/% 3, n, TRUE)),
    time = rep(periods, each = per), period = as.character(time)))
}

test_that("salience is 1 - irrelevant, direction sums to 1, intervals stay in [0, 1]", {
  d <- coded_file()
  st <- stance_static(d, stance_scheme("favor"))
  expect_equal(st$quantity, c("salience", "favor", "neutral", "oppose"))
  sal <- st$share[st$quantity == "salience"]
  expect_equal(sal, 1 - mean(d$label == "irrelevant"))
  expect_equal(sum(st$share[st$quantity != "salience"]), 1)
  expect_equal(st$n, c(nrow(d), rep(sum(d$label != "irrelevant"), 3)))
  expect_true(all(st$lo >= 0 & st$lo <= st$share & st$share <= st$hi & st$hi <= 1))
  # a share of exactly 0 or 1 gets no interval rather than a broken one
  none <- stance_static(dplyr::mutate(d, label = "favor"), stance_scheme("favor"))
  expect_equal(none$share, c(1, 1, 0, 0))
  expect_true(all(is.na(none$lo)))
})

test_that("a trend needs 4 periods of at least 30 passages; otherwise it is static", {
  s <- stance_scheme("favor")
  # 60 a period, so the passages that address the claim also fill 30 a period
  tr <- stance_trends(coded_file(periods = 2018:2023, per = 60), s)
  expect_true(stance_has_trend(tr))
  expect_setequal(unique(tr$quantity), c("salience", s$labels))
  expect_true(all(tr$lo >= 0 & tr$hi <= 1 & tr$lo <= tr$fit & tr$fit <= tr$hi))

  # three dense periods: no trend, and the note says why
  three <- stance_trends(coded_file(periods = 2018:2020, per = 40), s)
  expect_false(stance_has_trend(three))
  expect_match(attr(three, "notes")[1], "3 period\\(s\\) with at least 30 passages \\(needs 4\\)")
  expect_equal(stance_table(stance_static(coded_file(2018:2020), s), three)$estimate[1], "static")

  # a 29-passage period is left out of the trend but stays in the static estimate
  d <- dplyr::bind_rows(coded_file(periods = 2018:2021, per = 40),
                        dplyr::mutate(coded_file(periods = 2022, per = 29), time = 2022))
  tr <- stance_trends(d, s)
  per <- attr(tr, "periods")$salience
  expect_equal(per$enough, c(TRUE, TRUE, TRUE, TRUE, FALSE))
  expect_false(2022 %in% tr$time)
  expect_equal(stance_static(d, s)$n[1], nrow(d))
})

test_that("the run id carries the model, so runs of two models never match", {
  a <- stance_run_id("claude-sonnet-4-5")
  b <- stance_run_id("gemma4:31b")
  expect_match(a, "^run-\\d{8}-\\d{6}-[0-9a-f]{4}-claude-sonnet-4-5$")
  expect_match(b, "-gemma4-31b$")
  labeled <- tibble::tibble(stance_run = a, stance_row = 1:2, stance = c("favor", "oppose"))
  sheet <- tibble::tibble(stance_run = b, stance_row = 1:2, hand_label = c("favor", "oppose"))
  expect_error(stance_match(labeled, sheet), "different runs.*claude-sonnet-4-5.*gemma4-31b")
})
