# helper.R: loads the stance functions and starts a local mock of an
# OpenAI-compatible endpoint (/v1/embeddings and /v1/chat/completions), so no
# test touches the network or needs a real key.
# Run with testthat::test_dir("stance/tests/testthat").

library(shiny)
stance_dir <- normalizePath("../..", winslash = "/")
here_env <- environment()
purrr::walk(file.path(stance_dir, "R", c("stance_core.R", "stance_app.R")),
            function(f) sys.source(f, envir = here_env))

GOOD <- "sk-test-GOOD-7f3a9"  # the only key the mock accepts
BAD <- "sk-test-BAD-c41d2"

# ---- the mock ----------------------------------------------------------------
# Each passage carries its label as "LABEL=x" and its closeness to the claim as
# "SIM=x". A chat model is sent numbered texts and replies one line each,
# "3: FAVOR", so the parser has to cope with case. The embedding model returns a vector whose
# cosine with the claim's (a text with no SIM) is the passage's SIM. The model
# ID picks a behavior. Every request is logged and GET /log returns the log, so
# tests can count what reached the server. The handlers run in a separate R
# process, so they use base R only.

mock_app <- function() {
  `%||%` <- function(x, y) if (is.null(x)) y else x  # base R has it only from 4.4
  app <- webfakes::new_app()
  app$use(webfakes::mw_json())
  app$locals$log <- list()
  app$get("/log", function(req, res) res$send_json(req$app$locals$log, auto_unbox = TRUE))
  app$post("/reset", function(req, res) {
    req$app$locals$log <- list()
    res$send_json(list(ok = TRUE), auto_unbox = TRUE)
  })
  # logs the request, then returns NULL if it may proceed or sends the refusal
  app$locals$gate <- function(req, res, known, n_inputs = 1L) {
    b <- req$json
    loc <- req$app$locals
    n <- sum(vapply(loc$log, function(x) identical(x$model, b$model), logical(1)))
    loc$log[[length(loc$log) + 1]] <- list(
      t = as.numeric(Sys.time()), model = b$model, n_inputs = n_inputs,
      temperature = b$temperature %||% "", reasoning_effort = b$reasoning_effort %||% "",
      thinking = b$thinking$type %||% "", max_tokens = b$max_tokens %||% "")
    err <- function(status, msg)
      res$set_status(status)$send_json(
        list(error = list(message = msg, type = "invalid_request_error")), auto_unbox = TRUE)
    auth <- req$get_header("Authorization") %||% ""
    if (!identical(auth, "Bearer sk-test-GOOD-7f3a9"))  # echoes the key, as a careless server might
      return(err(401, paste("Incorrect API key provided:", sub("^Bearer ", "", auth))))
    if (!b$model %in% known) return(err(404, sprintf("The model `%s` does not exist", b$model)))
    # like Claude models: refuses a temperature
    if (grepl("^(sonnet|opus)", b$model) && !is.null(b$temperature))
      return(err(400, "temperature is not supported for this model"))
    # answers 5, then refuses every request
    if (startsWith(b$model, "gemma-limited") && n >= 5) {
      res$set_header("Retry-After", if (b$model == "gemma-limited") "0" else "3600")
      return(err(429, "Rate limit reached for requests"))
    }
    NULL
  }
  app$post("/v1/embeddings", function(req, res) {
    b <- req$json
    if (!is.null(req$app$locals$gate(req, res, "embed-test", length(b$input)))) return()
    vec <- function(txt) {
      s <- regmatches(txt, regexpr("SIM=[0-9.]+", txt))
      x <- if (length(s)) as.numeric(sub("SIM=", "", s)) else 1
      c(x, sqrt(1 - x^2))
    }
    res$send_json(list(object = "list", model = b$model, data = lapply(seq_along(b$input), function(i)
      list(object = "embedding", index = i - 1L, embedding = vec(b$input[[i]])))),
      auto_unbox = TRUE, digits = NA)
  })
  app$post("/v1/chat/completions", function(req, res) {
    b <- req$json
    known <- c("sonnet-test", "opus-test", "gemma-test", "llama-test", "gemma-limited",
               "gemma-limited-long")
    user <- b$messages[[length(b$messages)]]$content
    texts <- strsplit(user, "\n\n(?=Text [0-9]+: )", perl = TRUE)[[1]]
    if (!is.null(req$app$locals$gate(req, res, known, length(texts)))) return()
    # the label each numbered text carries; llama reads every neutral as favor,
    # and a model sent several texts at once ("-crowded") reads oppose as neutral
    lab <- vapply(texts, function(t) {
      l <- regmatches(t, regexpr("LABEL=[a-z]+", t))
      l <- if (length(l)) sub("LABEL=", "", l) else "irrelevant"
      if (b$model == "llama-test" && l == "neutral") l <- "favor"
      l
    }, "")
    num <- sub("^Text ([0-9]+):.*$", "\\1", texts)
    reply <- paste0(num, ": ", toupper(lab), collapse = "\n")
    # like Claude models: think, and so return no text, unless told not to
    if (grepl("^(sonnet|opus)", b$model) && !identical(b$thinking$type, "disabled")) reply <- ""
    res$send_json(list(id = "c1", object = "chat.completion", model = b$model,
                       choices = list(list(index = 0, finish_reason = "stop",
                                           message = list(role = "assistant", content = reply)))),
                  auto_unbox = TRUE)
  })
  app
}
# The mock's closures must not capture this file's environment, which holds the
# mock process itself, so the builder is rebased onto the global environment.
environment(mock_app) <- globalenv()
mock <- webfakes::new_app_process(mock_app())

mock_log <- function(model = NULL) {
  log <- httr2::request(mock$url("/log")) |> httr2::req_perform() |> httr2::resp_body_json()
  if (is.null(model)) log else purrr::keep(log, function(x) x$model == model)
}
mock_reset <- function()
  invisible(httr2::request(mock$url("/reset")) |> httr2::req_method("POST") |> httr2::req_perform())

# ---- test settings -----------------------------------------------------------

claude <- function(id) chat_model(id, thinking = list(type = "disabled"))
open_model <- function(id) chat_model(id, temperature = 0)
test_models <- function(label = claude("sonnet-test"),
                        helpers = list(claude("opus-test"), open_model("gemma-test"),
                                       open_model("llama-test")))
  stance_models("embed-test", label, helpers)

# The endpoint as the app builds it, pointed at the mock.
ep <- function(key = GOOD, models = test_models(), url = mock$url("/v1"))
  stance_endpoint(key, url, models)

local_app_options <- function(models = test_models(), per_request = 10, solo_n = 10,
                              .env = parent.frame())
  withr::local_options(stance.base_url = mock$url("/v1"), stance.models = models,
                       stance.per_request = per_request, stance.solo_n = solo_n,
                       stance.workers = 4, .local_envir = .env)

# Passages that address the claim sit close to it, the others far; the small
# step by row makes every similarity different, so ranks are certain.
passage <- function(label, i = seq_along(label),
                    sim = ifelse(label == "irrelevant", 0.2, 0.9) - i / 1e4)
  sprintf("Passage %d says plainly what the writer thinks LABEL=%s SIM=%.4f", i, label, sim)

# An upload: n passages over periods and documents. A quarter address the
# claim, most of them close to it and a few far from it.
write_upload <- function(n = 40, periods = 2021:2022, seed = 1, path = tempfile(fileext = ".csv")) {
  lab <- withr::with_seed(seed, sample(c("favor", "neutral", "oppose", "irrelevant"), n,
                                       replace = TRUE, prob = c(.12, .05, .08, .75)))
  readr::write_csv(tibble::tibble(
    id = paste0("doc", (seq_len(n) - 1) %/% 4 + 1),
    period = rep_len(periods, n),
    text = passage(lab, sim = withr::with_seed(seed, ifelse(
      lab == "irrelevant", runif(n, 0, .6), runif(n, .3, 1)))), truth = lab), path)
  path
}

# Every file a run writes, as text, to search for the key.
all_text <- function(...) paste(unlist(purrr::map(list(...), function(x)
  if (is.data.frame(x)) readr::format_csv(x) else as.character(x))), collapse = "\n")

# A frame with the truth as each passage's label, for tests that need no model.
truth_frame <- function(n = 2000, seed = 1) {
  set.seed(seed)
  sim <- runif(n)
  rel <- rbinom(n, 1, plogis(-4 + 6 * sim))
  tibble::tibble(stance_row = seq_len(n), text = paste("passage", seq_len(n)),
                 cluster = paste0("d", sample(n %/% 5, n, TRUE)),
                 truth = ifelse(rel == 1, sample(c("favor", "neutral", "oppose"), n, TRUE), "irrelevant"),
                 truth_sim = sim) |>
    dplyr::bind_cols(stance_frame(sim, seed))
}
