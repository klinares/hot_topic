# helper-stance.R: loads the stance functions and starts a local mock of
# Anthropic's /v1/messages, so no test touches the network or needs a real key.
# Run with testthat::test_dir("stance/tests/testthat").

library(shiny)
stance_dir <- normalizePath("../..", winslash = "/")
here_env <- environment()
purrr::walk(list.files(file.path(stance_dir, "R"), "\\.R$", full.names = TRUE),
            function(f) sys.source(f, envir = here_env))

GOOD <- "sk-test-GOOD-7f3a9"  # the only key the mock accepts
BAD <- "sk-test-BAD-c41d2"

# ---- the mock ----------------------------------------------------------------
# Each passage carries its label as "LABEL=x"; the mock replies "Label: X." so
# the parser has to cope with case, punctuation, and extra words. The model ID
# picks a behavior. Every request is logged (time, model, settings) and GET /log
# returns the log, so tests can count what reached the server. The handlers run
# in a separate R process, so they use base R only.

mock_reply <- function(user) {
  lab <- regmatches(user, regexpr("LABEL=[a-z]+", user))
  if (grepl("^Text: ready$", user)) "ready" else
    if (length(lab)) paste0("Label: ", toupper(sub("LABEL=", "", lab)), ".") else "irrelevant"
}

anthropic_app <- function(reply) {
  app <- webfakes::new_app()
  app$use(webfakes::mw_json())
  app$locals$log <- list()
  app$locals$reply <- reply
  app$get("/log", function(req, res) res$send_json(req$app$locals$log, auto_unbox = TRUE))
  app$post("/reset", function(req, res) {
    req$app$locals$log <- list()
    res$send_json(list(ok = TRUE), auto_unbox = TRUE)
  })
  app$post("/v1/messages", function(req, res) {
    b <- req$json
    loc <- req$app$locals
    n <- sum(vapply(loc$log, function(x) identical(x$model, b$model), logical(1)))
    loc$log[[length(loc$log) + 1]] <- list(
      t = as.numeric(Sys.time()), model = b$model, temperature = b$temperature %||% "",
      thinking = b$thinking$type %||% "", max_tokens = b$max_tokens, system = b$system[[1]]$text,
      n_messages = length(b$messages))
    err <- function(status, type, msg)
      res$set_status(status)$send_json(
        list(type = "error", error = list(type = type, message = msg)), auto_unbox = TRUE)
    key <- req$get_header("x-api-key")
    if (!identical(key, "sk-test-GOOD-7f3a9"))  # echoes the key it got, as a careless server might
      return(err(401, "authentication_error", paste("invalid x-api-key:", key %||% "")))
    if (!b$model %in% c("opus-test", "opus-limited"))
      return(err(404, "not_found_error", paste0("model: ", b$model)))
    # like Opus: refuses temperature, and thinks (an empty reply) unless told not to
    if (!is.null(b$temperature))
      return(err(400, "invalid_request_error", "temperature is not supported for this model"))
    # answers 5, refuses the next 3 (asking for a 1-second wait), then answers again
    if (b$model == "opus-limited" && n >= 5 && n < 8) {
      res$set_header("retry-after", "1")
      return(err(429, "rate_limit_error", "Number of requests has exceeded your rate limit"))
    }
    msg <- b$messages[[length(b$messages)]]$content
    user <- if (is.character(msg)) msg else msg[[1]]$text
    thinks <- !identical(b$thinking$type, "disabled")
    res$send_json(list(id = "msg_1", type = "message", role = "assistant", model = b$model,
                       content = if (thinks) list() else list(list(type = "text", text = loc$reply(user))),
                       stop_reason = if (thinks) "max_tokens" else "end_turn",
                       usage = list(input_tokens = 10L, output_tokens = 2L)),
                  auto_unbox = TRUE)
  })
  app
}

# The mock's closures must not capture this file's environment, which holds the
# mock process itself, so they are rebased onto the global environment.
purrr::walk(c("mock_reply", "anthropic_app"), function(f) {
  g <- get(f, here_env)
  environment(g) <- globalenv()
  assign(f, g, here_env)
})
mock <- webfakes::new_app_process(anthropic_app(mock_reply))

mock_log <- function()
  httr2::request(mock$url("/log")) |> httr2::req_perform() |> httr2::resp_body_json()
mock_reset <- function()
  invisible(httr2::request(mock$url("/reset")) |> httr2::req_method("POST") |> httr2::req_perform())

# ---- test settings -----------------------------------------------------------

# The endpoint as the app builds it, pointed at the mock.
ep <- function(key = GOOD, model = "opus-test", url = mock$url("/v1"), rpm = 300)
  stance_endpoint(key, url, model, rpm)

local_app_options <- function(model = "opus-test", .env = parent.frame())
  withr::local_options(stance.base_url = mock$url("/v1"), stance.model = model,
                       stance.rpm = 300, stance.workers = 4, .local_envir = .env)

passage <- function(label, i = seq_along(label))
  sprintf("Passage %d says plainly what the writer thinks LABEL=%s", i, label)

# A small upload: n passages over periods and documents, labels drawn at random.
write_upload <- function(n = 40, periods = 2021:2022, seed = 1, path = tempfile(fileext = ".csv"),
                         labels = c("favor", "neutral", "oppose", "irrelevant")) {
  lab <- withr::with_seed(seed, sample(labels, n, replace = TRUE))
  readr::write_csv(tibble::tibble(
    id = paste0("doc", (seq_len(n) - 1) %/% 4 + 1),
    period = rep_len(periods, n),
    text = passage(lab), truth = lab), path)
  path
}

# Every file a run writes, as text, to search for the key.
all_text <- function(...) paste(unlist(purrr::map(list(...), function(x)
  if (is.data.frame(x)) readr::format_csv(x) else as.character(x))), collapse = "\n")
