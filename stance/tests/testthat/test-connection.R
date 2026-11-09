# The connection check and the labeling path, against the mock.

fav <- stance_scheme("favor")

test_that("a good key passes the check", {
  res <- stance_check(ep())
  expect_true(res$ok)
  expect_match(res$message, "^Connected to opus-test")
  expect_true(is.numeric(res$secs))
})

test_that("a bad key gives 401 with the provider's message, and never the key", {
  res <- stance_check(ep(BAD))
  expect_false(res$ok)
  expect_match(res$message, "The key was refused.*401.*invalid x-api-key")
  expect_false(grepl(BAD, res$message, fixed = TRUE))  # the mock echoes it; it is scrubbed
})

test_that("an unknown model gives 404", {
  res <- stance_check(ep(model = "no-such-model"))
  expect_false(res$ok)
  expect_match(res$message, "The model or the URL was not found.*404.*no-such-model")
})

test_that("an unreachable host is named as such", {
  res <- stance_check(ep(url = "http://127.0.0.1:9/v1"))  # nothing listens on port 9
  expect_false(res$ok)
  expect_match(res$message, "The host could not be reached")
})

test_that("requests carry no temperature, thinking off, and a 20-token reply", {
  mock_reset()
  stance_check(ep())
  log <- mock_log()[[1]]
  expect_equal(log$temperature, "")  # the mock refuses a temperature, like Opus
  expect_equal(log$thinking, "disabled")  # with thinking on, the mock's reply is empty
  expect_equal(log$max_tokens, 20)
})

test_that("each passage is its own conversation from the system prompt", {
  mock_reset()
  stance_label_all(passage(c("favor", "oppose", "neutral")), "THE PROMPT", ep(), fav, 2)
  log <- mock_log()
  expect_equal(purrr::map_int(log, "n_messages"), c(1L, 1L, 1L))
  expect_equal(unique(purrr::map_chr(log, "system")), "THE PROMPT")
})

test_that("duplicates are sent once and labels come back in input order", {
  mock_reset()
  texts <- passage(c("favor", "oppose", "favor", "irrelevant", "oppose", "neutral"),
                   c(1, 2, 1, 3, 2, 4))
  lab <- stance_label_all(texts, "P", ep(), fav, workers = 3)
  expect_equal(as.vector(lab), c("favor", "oppose", "favor", "irrelevant", "oppose", "neutral"))
  expect_length(mock_log(), 4)  # 4 unique texts
  expect_true(all(is.na(attr(lab, "why"))))
})

test_that("a reply with no label is left NA with its reason, never guessed", {
  lab <- stance_label_all(passage(c("favor", "agree", "oppose")), "P", ep(), fav)
  expect_equal(as.vector(lab), c("favor", NA, "oppose"))
  expect_equal(attr(lab, "why")[2], "no label in reply: \"label: agree.\"")
})

test_that("a run that cannot start stops at the probe with the reason", {
  expect_error(stance_label_all(passage("favor"), "P", ep(BAD), fav),
               "could not be reached or did not answer: HTTP 401")
  expect_error(stance_label_all(passage("agree"), "P", ep(), fav), "none of the labels")
})

test_that("no window ever holds more requests than the limit", {
  # 5 a second stands for 300 a minute; the rule is the same
  withr::local_options(stance.window_secs = 1)
  mock_reset()
  texts <- passage(rep("favor", 17))
  t0 <- Sys.time()
  lab <- stance_label_all(texts, "P", ep(rpm = 5), fav, workers = 4)
  took <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  t <- sort(purrr::map_dbl(mock_log(), "t"))
  expect_length(t, 17)
  expect_lte(max(purrr::map_int(t, function(s) sum(t >= s & t < s + 1))), 5)
  expect_gte(took, 3)  # 17 requests at 5 a second cannot take less than 3 seconds
  expect_true(all(lab == "favor"))
})

test_that("no key, no endpoint, whatever the environment holds", {
  withr::local_envvar(ANTHROPIC_API_KEY = GOOD, STANCE_KEY = GOOD)
  expect_error(stance_endpoint(NULL, mock$url("/v1"), "opus-test"), "No API key")
  expect_error(stance_endpoint("", mock$url("/v1"), "opus-test"), "No API key")
  # ellmer is handed the (empty) key and does not fall back to ANTHROPIC_API_KEY
  bare <- list(base_url = mock$url("/v1"), model = "opus-test", key = "", rpm = 300)
  res <- stance_check(bare)
  expect_false(res$ok)
  expect_match(res$message, "401")
})

test_that("the app reads no environment variable and sets none", {
  files <- c(file.path(stance_dir, "app.R"),
             list.files(file.path(stance_dir, "R"), "\\.R$", full.names = TRUE))
  # code only: comments may name these functions to say they are not used
  code <- unlist(purrr::map(files, function(f) sub("#.*", "", readLines(f))))
  expect_false(any(grepl("Sys.setenv|Sys.getenv", code)))
})
