# app.R as shipped: the startup guard, then the page itself.

app_src <- readLines(file.path(stance_dir, "app.R"))
filled_src <- sub("\"OPUS-ID\"", "\"opus-test\"",
                  sub("https://YOUR-ANTHROPIC-ENDPOINT/v1", "http://127.0.0.1:9/v1", app_src, fixed = TRUE),
                  fixed = TRUE)

# Sources app.R text in the stance folder and returns the environment it ran in.
# app.R sets options and sources R/ into the global environment, so options are
# put back afterwards.
run_app_src <- function(src) {
  old <- options()
  withr::defer(options(old))
  withr::local_dir(stance_dir)
  env <- new.env()
  env$app <- eval(parse(text = src), envir = env)
  env
}

test_that("the app will not start while a placeholder is left", {
  skip_if_not(any(grepl("YOUR-|\"[A-Z]+-ID\"", app_src)), "placeholders already filled in")
  expect_error(run_app_src(app_src), "Paste the base URL and model ID into app.R")
})

test_that("app.R builds the banner, the logo placeholder and the three tabs", {
  env <- run_app_src(filled_src)
  expect_s3_class(env$app, "shiny.appobj")
  html <- as.character(htmltools::renderTags(env$ui)$html)
  purrr::walk(c("UNCLASSIFIED", "Office logo", "Start here", "Detect stance", "Check the labels",
                "opus-test", "Use this key", "Forget it", "Check connection",
                "it takes no temperature setting"),
              function(x) expect_match(html, x, fixed = TRUE))
})

test_that("shipped: 300 requests a minute, 4 at a time", {
  old <- options()
  withr::defer(options(old))
  eval(parse(text = app_src[seq_len(grep("stance.workers = ", app_src)[1])]))
  expect_equal(getOption("stance.rpm"), 300)
  expect_equal(getOption("stance.workers"), 4)
})
