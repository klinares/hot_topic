# test-app.R: the app as a user drives it. The key, the connection, a first
# batch of labels, more labels, coming back another day with the file, the
# downloads, the hand-coded check, app.R itself, and stance.qmd.

upload <- function(path) list(datapath = path, name = basename(path))
start <- function(session, path, n = 9, prop = "The proposal should be adopted by the council.") {
  session$setInputs(file = upload(path), text_col = "text", time_col = "period", doc_col = "id",
                    scheme = "favor", prop = prop, kind = "comments", n = n)
}
connect <- function(session, key = GOOD) {
  session$setInputs(key = key)
  session$setInputs(use_key = 1)
  session$setInputs(connect = 1)
}

test_that("nothing runs without a checked key, and the server's keys are never read", {
  local_app_options()
  withr::local_envvar(STANCE_KEY = GOOD, OPENAI_API_KEY = GOOD, ANTHROPIC_API_KEY = GOOD)
  mock_reset()
  testServer(mod_stance_server, args = list(id = "stance"), {
    start(session, write_upload(60))
    session$setInputs(go = 1)
    expect_null(run())
    session$setInputs(connect = 1)
    expect_false(conn_msg()$ok)
    expect_length(mock_log(), 0)  # no request left the app
    connect(session, BAD)
    expect_null(conn())
    expect_false(grepl(BAD, conn_msg()$message, fixed = TRUE))
    connect(session)
    expect_false(is.null(conn()))
    session$setInputs(forget_key = 1)
    expect_null(conn())
    session$setInputs(go = 2)
    expect_null(run())
  })
})

test_that("labels come in rounds, add up, and a later visit continues from the file", {
  local_app_options(solo_n = 3)
  mock_reset()
  path <- write_upload(1200, periods = 2015:2024)
  truth <- readr::read_csv(path, show_col_types = FALSE)$truth
  saved_file <- tempfile(fileext = ".csv")
  chat <- c("sonnet-test", "opus-test", "gemma-test", "llama-test")
  asked <- function() purrr::map_int(chat, function(m) length(mock_log(m)))
  testServer(mod_stance_server, args = list(id = "stance"), {
    start(session, path, n = 9)  # 9 requests each: sonnet 6 of ten and 3 alone
    connect(session)
    session$setInputs(go = 1)
    r <- run()
    expect_equal(r$counts$labeled, 60)
    expect_equal(r$counts$helper, 270)
    expect_equal(asked(), rep(1L + 9L, 4))  # the check, then the round
    expect_equal(sum(purrr::map_int(mock_log("embed-test"), "n_inputs")), 1 + 1201)
    expect_equal(unname(used()), rep(10, 4))
    got <- !is.na(r$labeled$stance_label)
    expect_equal(r$labeled$stance_label[got], truth[got])
    expect_equal(sum(r$labeled$stance_weight, na.rm = TRUE), 1200)
    expect_equal(r$static$quantity, c("salience", "favor", "neutral", "oppose"))
    expect_false(r$counts$assisted)  # 60 read by both is too few to use the helpers
    expect_equal(nrow(r$sheet), 60)
    expect_false(any(c("stance", "stance_label", "stance_helper") %in% names(r$sheet)))
    first <- r$labeled$stance_row[got]

    session$setInputs(n = 15, go = 2)  # more, same claim: adds to the sample
    r <- run()
    expect_equal(r$counts$labeled, 60 + 120)
    expect_equal(asked(), rep(1L + 9L + 15L, 4))
    expect_equal(sum(purrr::map_int(mock_log("embed-test"), "n_inputs")), 1202)  # not screened again
    expect_true(all(first %in% r$labeled$stance_row[!is.na(r$labeled$stance_label)]))
    expect_true(r$counts$assisted)
    expect_true(all(r$static$lo < r$static$share & r$static$share < r$static$hi))
    expect_true(stance_has_trend(r$trends))
    expect_equal(dplyr::n_distinct(r$labeled$stance_run), 1)
    expect_setequal(r$checks$reading, c("the same model, one passage per request", chat[-1]))
    expect_lt(r$checks$agree[r$checks$reading == "llama-test"], 1)
    # the key is in nothing the app hands back
    expect_false(grepl(GOOD, all_text(r$labeled, r$estimates, r$sheet), fixed = TRUE))
    expect_true(all(r$estimates$model == "sonnet-test"))
    expect_true(all(r$estimates$assisted))
    readr::write_excel_csv(r$labeled, saved_file, na = "")
  })

  mock_reset()
  testServer(mod_stance_server, args = list(id = "stance"), {  # another day
    session$setInputs(file = upload(saved_file), text_col = "text", time_col = "period",
                      doc_col = "id", scheme = "favor", kind = "comments", n = 6,
                      prop = "The proposal should be adopted by the council.")
    expect_equal(saved()$columns, c("text", "period", "id"))
    connect(session)
    session$setInputs(go = 1)
    r <- run()
    expect_equal(r$counts$labeled, 180 + 40)
    expect_equal(r$counts$helper, 270 + 450 + 180)
    expect_equal(asked(), rep(1L + 6L, 4))  # only the new requests
    expect_length(mock_log("embed-test"), 1)  # the connection check; no screening
    expect_equal(names(r$labeled)[1:4], c("id", "period", "text", "truth"))  # no doubled columns
    got <- !is.na(r$labeled$stance_label)
    expect_equal(r$labeled$stance_label[got], truth[got])

    session$setInputs(prop = "A different claim about something else entirely.", go = 2)
    r2 <- run()  # a new claim is a new sample
    expect_equal(r2$counts$labeled, 40)
    expect_false(identical(r2$labeled$stance_run[1], r$labeled$stance_run[1]))
  })
})

test_that("a file small enough is labeled whole, without the screen or the helpers' help", {
  local_app_options(models = test_models(helpers = list()))
  mock_reset()
  testServer(mod_stance_server, args = list(id = "stance"), {
    start(session, write_upload(24), n = 30)
    connect(session)
    session$setInputs(go = 1)
    r <- run()
    expect_equal(r$counts$labeled, 24)
    expect_length(mock_log("embed-test"), 1)  # the connection check only
    expect_true(all(r$labeled$stance_weight == 1))
    expect_false(r$counts$assisted)
    expect_equal(r$groups$similarity, NA_character_)
  })
})

test_that("the hand check matches a sheet to its run, weights it, and refuses another run's", {
  local_app_options(models = test_models(helpers = list()), solo_n = 0)
  path <- write_upload(200)
  testServer(mod_stance_server, args = list(id = "stance"), {
    start(session, path, n = 6)
    connect(session)
    session$setInputs(go = 1)
    r <- run()
    lf <- tempfile(fileext = ".csv"); hf <- tempfile(fileext = ".csv"); other <- tempfile(fileext = ".csv")
    readr::write_excel_csv(r$labeled, lf, na = "")
    sheet <- r$sheet
    sheet$hand_label <- r$labeled$truth[sheet$stance_row]
    sheet$hand_label[1:6] <- "neutral"  # the coder disagrees on six
    readr::write_excel_csv(sheet, hf, na = "")
    session$setInputs(labeled = upload(lf), hand = upload(hf))
    a <- check()
    expect_equal(a$n, 60)
    expect_lt(a$agree, 1)
    expect_equal(sum(diag(a$confusion)), 60 - sum(r$labeled$truth[sheet$stance_row[1:6]] != "neutral"))
    readr::write_excel_csv(dplyr::mutate(sheet, stance_run = "run-other"), other, na = "")
    expect_error(stance_match(readr::read_csv(lf, show_col_types = FALSE),
                              readr::read_csv(other, show_col_types = FALSE)), "different runs")
  })
})

test_that("app.R builds its pages, and refuses to start on placeholders", {
  dir <- withr::local_tempdir()
  file.copy(file.path(stance_dir, c("app.R", "R")), dir, recursive = TRUE)
  dir.create(file.path(dir, "logo"))
  withr::local_dir(dir)
  expect_error(source("app.R", local = new.env()), "Paste the base URL and the model IDs")
  src <- readLines("app.R")
  src <- sub("https://YOUR-ENDPOINT/v1", mock$url("/v1"), src, fixed = TRUE)
  ids <- c("EMBED-ID" = "embed-test", "SONNET-ID" = "sonnet-test", "OPUS-ID" = "opus-test",
           "GEMMA-ID" = "gemma-test", "LLAMA-ID" = "llama-test")
  src <- purrr::reduce(names(ids), function(x, id) sub(id, ids[[id]], x, fixed = TRUE), .init = src)
  writeLines(src, "app.R")
  e <- new.env()
  withr::with_options(list(stance.base_url = NULL, stance.models = NULL), {
    source("app.R", local = e)
    html <- as.character(e$ui)
  })
  expect_match(html, "UNCLASSIFIED")
  expect_match(html, "Office logo")
  expect_true(all(purrr::map_lgl(c("Start here", "Detect stance", "Check the labels",
                                   "The prompt", "Writing a good claim", "Label passages"),
                                 function(x) grepl(x, html, fixed = TRUE))))
  expect_true(regexpr("UNCLASSIFIED", html) < regexpr("Office logo", html))
})

test_that("stance.qmd runs against the endpoint, saves its sample, and adds to it", {
  root <- withr::local_tempdir()
  file.create(file.path(root, ".here"))
  dir.create(file.path(root, "stance", "inputs"), recursive = TRUE)
  file.copy(file.path(stance_dir, c("stance.qmd", "R")), file.path(root, "stance"), recursive = TRUE)
  file.copy(write_upload(300, periods = 2015:2024), file.path(root, "stance", "inputs", "c.csv"))
  qmd <- readLines(file.path(root, "stance", "stance.qmd"))
  set <- function(q, from, to) {
    expect_true(any(grepl(from, q, fixed = TRUE)), info = from)
    sub(from, to, q, fixed = TRUE)
  }
  qmd <- qmd |>
    set('file = "comments_periods.csv"', 'file = "c.csv"') |>
    set('"https://YOUR-ENDPOINT/v1"', paste0('"', mock$url("/v1"), '"')) |>
    set("EMBED-ID", "embed-test") |> set("SONNET-ID", "sonnet-test") |> set("OPUS-ID", "opus-test") |>
    set("GEMMA-ID", "gemma-test") |> set("LLAMA-ID", "llama-test") |>
    set("solo_n = 10L", "solo_n = 3L") |>
    set("n_label = 200L", "n_label = 60L")
  render <- function(q) {
    writeLines(q, file.path(root, "stance", "stance.qmd"))
    script <- file.path(root, "stance", "stance.R")
    knitr::purl(file.path(root, "stance", "stance.qmd"), script, quiet = TRUE)
    withr::with_dir(root, withr::with_envvar(c(STANCE_KEY = GOOD), {
      e <- new.env()
      utils::capture.output(source(script, local = e))
      e
    }))
  }
  mock_reset()
  e <- render(qmd)
  expect_equal(nrow(e$coded), 60)
  expect_equal(length(mock_log("sonnet-test")), 6 + 3)
  expect_null(e$assist)
  out <- file.path(root, "stance", "outputs")
  expect_true(all(file.exists(file.path(out, paste0("stance_", c("labels", "estimates", "handcode"),
                                                    "_world_role.csv")))))
  expect_false(any(grepl(GOOD, unlist(purrr::map(list.files(out, full.names = TRUE), readLines)),
                         fixed = TRUE)))
  e <- render(qmd)  # rendering again sends nothing
  expect_equal(length(mock_log("sonnet-test")), 9)
  e <- render(set(qmd, "n_label = 60L", "n_label = 200L"))  # a larger total adds the difference
  expect_equal(nrow(e$coded), 200)
  expect_equal(length(mock_log("sonnet-test")), 9 + 14 + 3)
  expect_false(is.null(e$assist))
  expect_true(stance_has_trend(e$trends))
  expect_equal(nrow(e$checks), 4)
  expect_error(render(set(qmd, "active role", "smaller role")), "Delete")  # a changed claim is refused
  # so is a labels file left by an earlier version of the script
  writeLines(c("stance_row,label", "4,irrelevant"), file.path(out, "stance_labels_old.csv"))
  expect_error(suppressWarnings(render(set(qmd, 'name = "world_role"', 'name = "old"'))), "Delete")
})
