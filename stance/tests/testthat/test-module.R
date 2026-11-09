# The Detect stance and Check the labels pages, driven through
# shiny::testServer against the mock.

claim <- "The proposed rule should be withdrawn now."

# Sets the inputs a user fills in before a run.
fill_in <- function(session, csv)
  session$setInputs(file = list(datapath = csv, name = "upload.csv"),
                    text_col = "text", time_col = "period", doc_col = "id",
                    scheme = "favor", prop = claim, kind = "short text passages")

test_that("no run without a passed check, and a key alone is not enough", {
  local_app_options()
  csv <- write_upload()
  testServer(mod_stance_server, {
    fill_in(session, csv)
    session$setInputs(go = 1)
    expect_null(run())
    session$setInputs(connect = 1)  # no key yet
    expect_false(conn_msg()$ok)
    expect_match(conn_msg()$message, "Paste your API key")
    session$setInputs(key = GOOD, use_key = 1)
    expect_equal(key(), GOOD)
    session$setInputs(go = 2)
    expect_null(run())
    session$setInputs(connect = 2)
    expect_true(conn_msg()$ok)
    session$setInputs(go = 3)
    expect_false(is.null(run()))
  })
})

test_that("a failed check keeps the run locked", {
  local_app_options()
  csv <- write_upload()
  testServer(mod_stance_server, {
    fill_in(session, csv)
    session$setInputs(key = BAD, use_key = 1, connect = 1)
    expect_false(conn_msg()$ok)
    expect_null(conn())
    expect_false(grepl(BAD, conn_msg()$message, fixed = TRUE))
    session$setInputs(go = 1)
    expect_null(run())
  })
})

test_that("a new key or Forget it clears the connection", {
  local_app_options()
  testServer(mod_stance_server, {
    session$setInputs(key = GOOD, use_key = 1, connect = 1)
    expect_false(is.null(conn()))
    session$setInputs(key = GOOD, use_key = 2)
    expect_null(conn())
    session$setInputs(connect = 2)
    expect_false(is.null(conn()))
    session$setInputs(forget_key = 1)
    expect_null(key())
    expect_null(conn())
    expect_null(conn_msg())
  })
})

test_that("with keys in the environment and none pasted, nothing checks or runs", {
  withr::local_envvar(ANTHROPIC_API_KEY = GOOD, STANCE_KEY = GOOD)
  local_app_options()
  csv <- write_upload()
  testServer(mod_stance_server, {
    fill_in(session, csv)
    session$setInputs(connect = 1, go = 1)
    expect_null(conn())
    expect_null(run())
  })
})

# A full run on a small file, then its three downloads.
run_and_download <- function(labels = c("favor", "neutral", "oppose", "irrelevant")) {
  csv <- write_upload(n = 48, periods = 2021:2022, labels = labels)
  truth <- readr::read_csv(csv, show_col_types = FALSE)$truth
  out <- NULL
  testServer(mod_stance_server, {
    fill_in(session, csv)
    session$setInputs(key = GOOD, use_key = 1, connect = 1, go = 1)
    read <- function(id) readr::read_csv(output[[id]], show_col_types = FALSE,
                                         col_types = readr::cols(.default = "c"))
    out <<- list(run = run(), labeled = read("dl_data"), estimates = read("dl_est"),
                 sheet = read("dl_sheet"), message = conn_msg()$message,
                 summary = as.character(output$summary$html))
  })
  c(out, list(truth = truth))
}

test_that("a full run gives the expected labels, estimates and downloads", {
  local_app_options()
  x <- run_and_download()
  expect_equal(x$labeled$stance, x$truth)
  expect_equal(unique(x$labeled$stance_model), "opus-test")
  expect_match(unique(x$labeled$stance_run), "-opus-test$")
  expect_equal(unique(x$estimates$model), "opus-test")
  expect_equal(unique(x$sheet$stance_run), unique(x$labeled$stance_run))
  # static (2 periods), salience = 1 - irrelevant share
  est <- x$estimates
  expect_equal(unique(est$estimate), "static")
  expect_equal(as.numeric(est$fit[est$quantity == "salience"]), mean(x$truth != "irrelevant"))
  expect_equal(sum(as.numeric(est$fit[est$quantity != "salience"])), 1)
  expect_equal(nrow(x$sheet), 48)
  expect_true(all(x$sheet$hand_label %in% c(NA, "")))
  expect_false("stance" %in% names(x$sheet))
  # the key is in no download and no message
  expect_false(grepl(GOOD, all_text(x$labeled, x$estimates, x$sheet, x$message), fixed = TRUE))
})

test_that("passages that got no label are counted, explained, and kept out of the estimates", {
  local_app_options()
  # "agree" is not a label of the favor scheme, so those replies hold no label
  x <- run_and_download(labels = c("favor", "oppose", "agree"))
  miss <- x$truth == "agree"
  expect_equal(x$run$counts$coded, sum(!miss))
  expect_length(x$run$unlabeled, sum(miss))
  expect_true(all(is.na(x$labeled$stance[miss])))
  expect_true(all(grepl("^no label in reply", x$labeled$stance_excluded[miss])))
  expect_equal(as.numeric(x$run$static$n[1]), sum(!miss))
  expect_match(x$summary, sprintf("%d passage\\(s\\) got no label", sum(miss)))
})

test_that("Check the labels matches a run's files and refuses another run's sheet", {
  local_app_options()
  a <- run_and_download()
  b <- run_and_download()
  # code the sheet by hand: agree with the truth except on 4 rows
  sheet <- a$sheet
  sheet$hand_label <- a$truth[as.integer(sheet$stance_row)]
  sheet$hand_label[1:4] <- ifelse(sheet$hand_label[1:4] == "neutral", "favor", "neutral")
  f_lab <- tempfile(fileext = ".csv")
  f_sheet <- tempfile(fileext = ".csv")
  f_other <- tempfile(fileext = ".csv")
  readr::write_csv(a$labeled, f_lab)
  readr::write_csv(sheet, f_sheet)
  readr::write_csv(dplyr::mutate(b$sheet, hand_label = "favor"), f_other)
  testServer(mod_stance_server, {
    session$setInputs(labeled = list(datapath = f_lab), hand = list(datapath = f_sheet))
    k <- check()
    expect_equal(k$n, 48)
    expect_equal(k$model, "opus-test")
    expect_lt(k$agree, 1)
    expect_gt(k$agree, 0.85)
    session$setInputs(hand = list(datapath = f_other))
    expect_null(check())  # another run: refused
  })
})
