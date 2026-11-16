# test-stance.R: the method. Screening, the sample, the weights, the estimates,
# the requests, and what happens when the endpoint refuses.

fav <- stance_scheme("favor")

# ---- passages ------------------------------------------------------------------

test_that("word bounds set passages aside with a reason", {
  s <- stance_screen(c("one two three four five", "too short", NA, paste(rep("w", 300), collapse = " ")))
  expect_equal(s$keep, c(TRUE, FALSE, FALSE, FALSE))
  expect_equal(s$why, c(NA, "under 5 words", "under 5 words", "over 250 words"))
})

test_that("prepare handles time and document columns, and their gaps", {
  raw <- tibble::tibble(txt = rep("this passage is long enough to count", 4),
                        yr = c("2020-03", "2021-11", NA, "2021-01"), doc = c("a", "a", "b", NA))
  p <- stance_prepare(raw, "txt", "yr", "doc")
  expect_equal(p$keep, c(TRUE, TRUE, FALSE, FALSE))
  expect_equal(p$why[3:4], c("no time value", "no document id"))
  expect_equal(p$time[1], 2020 + 2 / 12)
  expect_equal(stance_prepare(raw, "txt")$cluster, paste0("row ", 1:4))
  expect_error(stance_prepare(raw, "nope"), "No column named: nope")
  expect_error(stance_time(c("2020-13")), "month outside")
})

test_that("the parser reads one label per numbered text, and says what is missing", {
  codes <- stance_codes(fav)
  got <- stance_parse("1: FAVOR\n2: irrelevant\n3) Oppose.\n4 - **neutral**", 4, codes)
  expect_equal(as.vector(got), c("favor", "irrelevant", "oppose", "neutral"))
  got <- stance_parse("2: oppose\n1: favor\nI could not judge the third.", 3, codes)  # out of order, one missing
  expect_equal(as.vector(got), c("favor", "oppose", NA))
  expect_match(attr(got, "why")[3], "no label in reply")
  expect_equal(as.vector(stance_parse("It is irrelevant.", 1, codes)), "irrelevant")  # one text, bare label
  expect_true(all(is.na(stance_parse("", 2, codes))))
  expect_true(is.na(stance_parse("1: agree", 1, codes)))  # a label of another scheme
  expect_equal(as.vector(stance_parse("12: favor\n1: oppose", 2, codes)), c("oppose", NA))  # 12 is not 1 or 2
})

test_that("every scheme's prompt names its labels and the claim", {
  purrr::walk(stance_schemes, function(s) {
    p <- stance_prompt(s, "The rule should stay.", "comments")
    expect_true(all(purrr::map_lgl(stance_codes(s), function(l) grepl(paste0("- ", l, ":"), p, fixed = TRUE))))
    expect_match(p, "The rule should stay.", fixed = TRUE)
    expect_match(p, "Judge each text on its own")
  })
})

# ---- the sample ----------------------------------------------------------------

test_that("groups follow similarity, closest first, in the set shares", {
  sim <- seq(0, 1, length.out = 1000)
  s <- stance_strata(sim)
  expect_equal(as.vector(table(s)) / 1000, stance_defaults$strata, tolerance = 0.01)
  expect_true(all(diff(tapply(sim, s, mean)) < 0))
  expect_equal(unique(stance_strata(rep(NA_real_, 5))), 1L)
  expect_equal(length(unique(stance_strata(rep(0.5, 20)))), 1)  # ties share a group
})

test_that("a pick fills the groups evenly, in draw order, within the budget", {
  d <- truth_frame()
  pick <- stance_pick(d, 100)
  expect_length(pick, 100)
  expect_equal(as.vector(table(d$stratum[pick])), rep(25L, 4))
  # each group's sample is its lowest draws
  purrr::walk(1:4, function(h) {
    in_h <- which(d$stratum == h)
    expect_setequal(pick[d$stratum[pick] == h], in_h[rank(d$draw[in_h]) <= 25])
  })
  # sent in turns, so a run cut short leaves every group sampled
  expect_equal(sort(d$stratum[pick[1:4]]), 1:4)
})

test_that("asking twice is the same sample as asking once for the total", {
  d <- truth_frame()
  first <- stance_pick(d, 60)
  d2 <- d
  d2$label[first] <- d2$truth[first]
  expect_setequal(c(first, stance_pick(d2, 90)), stance_pick(d, 150))
})

test_that("a small group is labeled whole and the rest share what is left", {
  d <- truth_frame(200)
  pick <- stance_pick(d, 120)
  n_h <- table(d$stratum[pick])
  expect_equal(n_h[["1"]], sum(d$stratum == 1))  # 10 passages, all taken
  expect_equal(sum(n_h), 120)
  expect_length(stance_pick(d, 5000), 200)  # never more than there is
})

test_that("known texts cost nothing, and an unanswerable passage is not asked again", {
  d <- truth_frame(400)
  d$text[d$draw <= 50] <- "the same words"  # 50 copies across the file
  first <- stance_pick(d, 40)
  expect_equal(dplyr::n_distinct(d$text[first]), 40)  # 40 requests, however many rows
  d$label[first] <- d$truth[first]
  bad <- stance_pick(d, 1)[1]
  d$why[bad] <- "no label in reply: \"hm\""
  expect_false(bad %in% stance_pick(d, 50))
  # a helper's picks follow the same order, so they cover the labeler's first
  expect_setequal(stance_pick(d, 41, read = !is.na(d$helper))[1:40], c(first, bad)[1:40])
})

test_that("weights add up to the file, group by group", {
  d <- truth_frame()
  pick <- stance_pick(d, 200)
  d$label[pick] <- d$truth[pick]
  w <- stance_weights(d)
  expect_equal(sum(w, na.rm = TRUE), nrow(d))
  expect_equal(as.vector(tapply(w, d$stratum, sum, na.rm = TRUE)), as.vector(table(d$stratum)))
  expect_true(all(is.na(w[is.na(d$label)])))
})

# ---- the estimates -------------------------------------------------------------

estimate <- function(d, n) {
  pick <- stance_pick(d, n)
  d$label[pick] <- d$truth[pick]
  d$w <- stance_weights(d)
  stance_static(d[!is.na(d$label), ], fav)
}

test_that("with every passage labeled the estimates are the plain shares", {
  d <- truth_frame()
  st <- estimate(d, nrow(d))
  rel <- d$truth != "irrelevant"
  expect_equal(st$share[1], mean(rel))
  expect_equal(st$share[2], mean(d$truth[rel] == "favor"))
  expect_equal(sum(st$share[2:4]), 1)
  expect_true(all(st$lo > 0 & st$hi < 1 & st$lo < st$share & st$hi > st$share))
})

test_that("a sample is unbiased and its intervals hold the truth about 95% of the time", {
  pop <- truth_frame(4000, seed = 7)
  truth <- mean(pop$truth != "irrelevant")
  runs <- purrr::map(1:300, function(i) {
    pop$draw <- withr::with_seed(i, sample.int(nrow(pop)))
    estimate(pop, 200)[1, ]
  }) |> purrr::list_rbind()
  expect_equal(mean(runs$share), truth, tolerance = 0.03)  # relative
  expect_gt(mean(runs$lo <= truth & runs$hi >= truth), 0.92)
  # the screen earns its keep: narrower than 200 labels drawn without it
  pop$stratum <- 1L
  plain <- purrr::map_dbl(1:300, function(i) {
    pop$draw <- withr::with_seed(i, sample.int(nrow(pop)))
    estimate(pop, 200)$share[1]
  })
  expect_lt(stats::sd(runs$share), stats::sd(plain))
})

test_that("thin groups borrow a neighbor, and one document gives no interval", {
  expect_equal(merge_thin(c(1, 1, 2, 3, 3)), c(1, 1, 2, 2, 2))
  expect_equal(merge_thin(c(1, 1, 2, 2, 3)), c(1, 1, 2, 2, 2))
  expect_equal(merge_thin(c(4)), 1)
  d <- transform(truth_frame(50), cluster = "one", label = truth, w = 1)
  expect_true(all(is.na(stance_static(d, fav)$share)))
})

test_that("a trend needs enough labels and periods, and follows a real change", {
  d <- truth_frame(3000, seed = 3)
  d$time <- sample(2001:2020, nrow(d), TRUE)
  d$period <- as.character(d$time)
  d$truth[d$time > 2010 & d$similarity > 0.6] <- "favor"  # salience rises after 2010
  pick <- stance_pick(d, 300)
  d$label[pick] <- d$truth[pick]
  d$w <- stance_weights(d)
  coded <- d[!is.na(d$label), ]
  tr <- stance_trends(coded, fav)
  sal <- tr[tr$quantity == "salience", ]
  expect_equal(nrow(sal), 20)
  expect_gt(sal$fit[sal$time == 2020], sal$fit[sal$time == 2001])
  expect_true(all(sal$lo < sal$fit & sal$fit < sal$hi))
  few <- stance_trends(coded[1:40, ], fav)
  expect_false(stance_has_trend(few))
  expect_match(attr(few, "notes")[1], "no trend")
  obs <- stance_observed(coded, fav)
  expect_lte(max(obs$bin), 8)
  expect_true(all(obs$share >= 0 & obs$share <= 1))
})

test_that("agreement is weighted, and exact agreement is kappa 1", {
  h <- c(rep("favor", 10), rep("irrelevant", 10))
  expect_equal(stance_agreement(h, h, seq_along(h), fav)$kappa, 1)
  m <- h
  m[11:15] <- "favor"  # the model is wrong on half the irrelevant
  plain <- stance_agreement(h, m, seq_along(h), fav)
  heavy <- stance_agreement(h, m, seq_along(h), fav, w = rep(c(1, 9), each = 10))
  expect_equal(plain$agree, 0.75)
  expect_equal(heavy$agree, (10 + 5 * 9) / 100)  # the irrelevant stand for more of the file
  expect_equal(sum(plain$confusion), 20)
})

# ---- helpers ---------------------------------------------------------------

# The labeler reads n passages and a helper, wrong on `err` of them and leaning
# to "favor" when wrong, reads n_help in the same order.
with_helper <- function(d, n, n_help, err = 0.15, seed = 1) {
  codes <- stance_codes(fav)
  says <- withr::with_seed(seed, ifelse(runif(nrow(d)) < err, sample(codes, nrow(d), TRUE, c(.6, .1, .1, .2)), d$truth))
  pick <- stance_pick(d, n)
  d$label[pick] <- d$truth[pick]
  h <- stance_pick(d, n_help, read = !is.na(d$helper))
  d$helper[h] <- says[h]
  d$helper_model[h] <- "helper"
  d$w <- stance_weights(d)
  d
}
assisted <- function(d) {
  a <- stance_assist(d, fav)
  stance_static(d[a$both, ], fav, c(a, list(cluster = d$cluster[a$rows])))
}

test_that("helpers are used only when they cover the labeler's passages", {
  d <- truth_frame()
  expect_null(stance_assist(with_helper(d, 80, 300), fav))  # too few read by both
  short <- with_helper(d, 400, 200)                         # helpers read half of the labeler's
  expect_null(stance_assist(short, fav))
  a <- stance_assist(with_helper(d, 300, 900), fav)
  expect_length(a$both, 300)
  expect_equal(nrow(a$M), 900)
  expect_equal(unname(rowSums(a$M)), rep(1, 900))
  expect_equal(sum(a$W), nrow(d))  # the helpers' passages stand for the file
  expect_equal(sum(a$w), nrow(d))  # and so do the passages both read
})

test_that("a helper that leans the wrong way does not bias the shares, and narrows them", {
  pop <- truth_frame(4000, seed = 7)
  truth <- mean(pop$truth != "irrelevant")
  runs <- purrr::map(1:200, function(i) {
    pop$draw <- withr::with_seed(i, sample.int(nrow(pop)))
    d <- with_helper(pop, 300, 4000, err = 0.2, seed = i)
    h <- assisted(d)[1, ]
    tibble::tibble(alone = stance_static(d[!is.na(d$label), ], fav)$share[1], helped = h$share,
                   lo = h$lo, hi = h$hi, taken = mean(d$helper != "irrelevant"))  # the helper at its word
  }) |> purrr::list_rbind()
  expect_gt(mean(runs$taken), truth * 1.2)                  # the helper overstates salience
  expect_equal(mean(runs$helped), truth, tolerance = 0.03)  # the estimate does not
  expect_gt(mean(runs$lo <= truth & runs$hi >= truth), 0.92)
  expect_lt(stats::sd(runs$helped), stats::sd(runs$alone))
})

test_that("helped shares are shares: inside 0 to 1, and the labels add to one", {
  st <- assisted(with_helper(truth_frame(3000), 400, 1200))
  expect_equal(sum(st$share[2:4]), 1)
  expect_true(all(st$lo > 0 & st$hi < 1 & st$lo < st$share & st$hi > st$share))
})

# ---- the model ---------------------------------------------------------------

test_that("the check passes with a good key and names what is wrong otherwise", {
  mock_reset()
  expect_true(stance_check(ep())$ok)
  expect_length(mock_log(), 5)  # the embedding model and four chat models, once each
  bad <- stance_check(ep(BAD))
  expect_false(bad$ok)
  expect_match(bad$message, "The key was refused")
  expect_false(grepl(BAD, bad$message, fixed = TRUE))  # the mock echoes the key; we do not
  expect_match(stance_check(ep(models = test_models(label = claude("nope"))))$message, "was not found")
  expect_match(stance_check(ep(url = "http://127.0.0.1:9/v1"))$message, "could not be reached")
  expect_error(stance_endpoint(""), "No API key")
  # a Claude model left thinking answers with nothing, and the check says so
  expect_match(stance_check(ep(models = test_models(label = chat_model("sonnet-test"), helpers = list())))$message,
               "empty reply")
})

upload_frame <- function(n, endpoint = ep(), screen = TRUE) {
  txt <- readr::read_csv(write_upload(n), show_col_types = FALSE)
  sim <- if (screen) stance_similarity(txt$text, "The claim is this one.", endpoint, workers = 4) else NA_real_
  dplyr::bind_cols(stance_row = seq_len(n), text = txt$text, truth = txt$truth, stance_frame(rep_len(sim, n)))
}
sent <- function(model) sum(purrr::map_int(mock_log(model), "n_inputs"))

test_that("a round sends each model its requests, ten passages each, and labels correctly", {
  mock_reset()
  d <- upload_frame(2000)
  expect_equal(sent("embed-test"), 2001)  # the claim and each passage
  expect_equal(length(unique(d$stratum)), 4)
  d <- stance_run(d, 15, "P", ep(), fav, per_request = 10, solo_n = 5, workers = 4)
  calls <- attr(d, "calls")
  expect_equal(calls[["sonnet-test"]], 15)  # 10 requests of ten, 5 passages alone
  expect_true(all(calls[c("opus-test", "gemma-test", "llama-test")] == 15))
  expect_equal(purrr::map_int(c("sonnet-test", "opus-test", "gemma-test", "llama-test"),
                              function(m) length(mock_log(m))), rep(15L, 4))
  expect_equal(sum(!is.na(d$label)), 100)
  expect_equal(d$label[!is.na(d$label)], d$truth[!is.na(d$label)])
  expect_equal(sum(!is.na(d$solo)), 5)
  expect_equal(sum(!is.na(d$helper)), 450)                # three helpers, 150 passages each
  expect_true(all(!is.na(d$helper[!is.na(d$label)])))    # they cover the labeler's passages
  expect_equal(as.vector(table(d$helper_model)), rep(150L, 3))
  # each helper read a fair share of the labeler's passages
  expect_true(all(table(d$helper_model[!is.na(d$label)]) > 20))
  expect_null(attr(d, "notes"))
  # a second round adds; nothing is read twice
  d2 <- stance_run(d, 15, "P", ep(), fav, per_request = 10, solo_n = 5, workers = 4)
  expect_equal(sum(!is.na(d2$label)), 200)
  expect_equal(sum(!is.na(d2$helper)), 900)
  expect_equal(sent("sonnet-test"), 200 + 10)
  expect_true(all(d2$label[!is.na(d$label)] == d$label[!is.na(d$label)]))
  # each model got the settings it needs
  expect_true(all(purrr::map_chr(mock_log("sonnet-test"), "thinking") == "disabled"))
  expect_true(all(purrr::map(mock_log("gemma-test"), "temperature") == 0))
  # the checks: sonnet agrees with itself alone; llama, which reads neutral as favor, does not fully
  ch <- stance_checks(d2, fav)
  expect_equal(ch$reading[1], "the same model, one passage per request")
  expect_equal(ch$agree[1], 1)
  expect_lt(ch$agree[ch$reading == "llama-test"], 1)
  expect_equal(ch$agree[ch$reading == "opus-test"], 1)
})

test_that("identical passages are sent once, and one passage per request still works", {
  mock_reset()
  d <- tibble::tibble(stance_row = 1:30, text = rep(passage(c("favor", "oppose", "irrelevant"), 1:3), 10))
  d <- dplyr::bind_cols(d, stance_frame(rep(NA_real_, 30)))
  d <- stance_run(d, 30, "P", ep(models = test_models(helpers = list())), fav, per_request = 1)
  expect_equal(length(mock_log("sonnet-test")), 3)
  expect_equal(d$label, rep(c("favor", "oppose", "irrelevant"), 10))
  expect_true(all(is.na(d$solo)))  # nothing to compare when every passage already goes alone
  expect_error(stance_run(d, 5, "P", ep(), fav), "already has a label")
})

test_that("when the labeler starts refusing, labels stop, nothing is invented, the sample stays usable", {
  mock_reset()
  d <- truth_frame(400)
  d$text <- passage(d$truth, sim = d$similarity)
  limited <- ep(models = test_models(label = open_model("gemma-limited"), helpers = list()))
  d <- stance_run(d, 20, "P", limited, fav, per_request = 4, solo_n = 0, workers = 1)
  done <- !is.na(d$label)
  expect_equal(sum(done), 20)  # the mock answers 5 requests of 4
  expect_equal(d$label[done], d$truth[done])
  expect_true(all(grepl("HTTP 429|not sent: the rate limit", d$why[!done & !is.na(d$why)])))
  expect_equal(as.vector(table(d$stratum[done])), rep(5L, 4))  # every group evenly, up to the refusal
  expect_equal(sum(stance_weights(d), na.rm = TRUE), 400)
  expect_error(stance_run(d, 5, "P", limited, fav), "HTTP 429")  # a refused first request says why
})

test_that("a Retry-After of hours is not waited for", {
  mock_reset()
  t0 <- Sys.time()
  lab <- stance_label_all(passage(rep("favor", 12), 1:12), "P", ep(), open_model("gemma-limited-long"), fav)
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 20)
  expect_equal(sum(!is.na(lab)), 5)
})

test_that("a helper that fails costs nothing but a note", {
  mock_reset()
  d <- upload_frame(300)
  d <- stance_run(d, 6, "P", ep(models = test_models(helpers = list(open_model("nope"), open_model("gemma-test")))),
                  fav, solo_n = 0)
  expect_equal(sum(!is.na(d$label)), 60)
  expect_match(attr(d, "notes"), "nope did not run")
  expect_equal(unique(stats::na.omit(d$helper_model)), "gemma-test")
})
