# unga_source.R: shared functions for topics.qmd and stance.R.
# Only function definitions live here; nothing runs when it is sourced.
#   1. Paths and model calls
#   2. Output guard (manifest.csv)
#   3. Topic model helpers
#   4. Shares and trends
#   5. Tables for Typst

# ---- 1. Paths and model calls ------------------------------------------------

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
# The repo root is hot_topic; everything for this project lives under unga/.
# If unga becomes its own repo, drop "unga" from these two lines.
p_in <- function(f) here::here("unga", "input", f)
p_out <- function(...) here::here("unga", "outputs", ...)

# Every prompt has the same four parts, so each one reads the same way.
build_prompt <- function(role, task, rules, output) {
  str_c("ROLE\n", role, "\n\nTASK\n", task, "\n\nRULES\n",
        str_c("- ", rules, collapse = "\n"), "\n\nOUTPUT\n", output)
}

# One chat object per step. The steps table holds the NAMES of the
# .Renviron variables for the URL and key, never the values.
make_chat <- function(step, system_prompt, steps, home = FALSE) {
  cfg <- steps[steps$step == step, ]
  if (nrow(cfg) != 1) stop("No unique '", step, "' row in the steps table.")
  if (isTRUE(home)) return(make_chat_home(cfg$model, system_prompt))
  if (utils::packageVersion("ellmer") < "0.4.0")
    stop("ellmer 0.4.0 or later is needed (credentials argument).")
  url <- Sys.getenv(cfg$base_url_env)
  key <- Sys.getenv(cfg$api_key_env)
  if (!nzchar(url) || !nzchar(key))
    stop("Set ", cfg$base_url_env, " and ", cfg$api_key_env, " in .Renviron.")
  ellmer::chat_openai_compatible(
    base_url = url, model = cfg$model, system_prompt = system_prompt,
    credentials = function() key,
    params = ellmer::params(temperature = 0), echo = "none")
}

# Many prompts through one chat, in parallel. One row per prompt; a failed
# call is NA.
ask_many <- function(chat, prompts, type, rpm = 300L, max_active = 10L) {
  ellmer::parallel_chat_structured(chat, as.list(prompts), type = type,
                                   rpm = rpm, max_active = max_active,
                                   on_error = "continue")
}

# ---- 2. Output guard (manifest.csv) ------------------------------------------
# A cached output must not outlive the inputs it was built from. manifest.csv
# records the md5 of each input when an output is written; if an input has
# changed since, the next render stops and names the file to delete.

md5_of <- function(inputs) {
  miss <- inputs[!file.exists(inputs)]
  if (length(miss))
    stop("Missing input: ", str_c(basename(miss), collapse = ", "),
         ". Run the earlier step first.")
  unname(tools::md5sum(inputs))
}

manifest_read <- function() {
  f <- p_out("manifest.csv")
  if (!file.exists(f)) return(tibble::tibble(output = character(),
                                             input = character(),
                                             md5 = character()))
  readr::read_csv(f, show_col_types = FALSE, col_types = "ccc")
}

check_inputs <- function(output, inputs) {
  if (!file.exists(output)) return(invisible(TRUE))
  old <- dplyr::filter(manifest_read(), output == basename(!!output))
  now <- tibble::tibble(input = basename(inputs), md5_now = md5_of(inputs))
  changed <- dplyr::inner_join(old, now, by = "input") |>
    dplyr::filter(md5 != md5_now)
  if (nrow(changed))
    stop(str_c(changed$input, collapse = ", "), " changed since ",
         basename(output), " was built. Delete ", basename(output),
         " and re-render.")
  invisible(TRUE)
}

record_inputs <- function(output, inputs) {
  new <- tibble::tibble(output = basename(output), input = basename(inputs),
                        md5 = md5_of(inputs))
  manifest_read() |>
    dplyr::filter(output != basename(!!output)) |>
    dplyr::bind_rows(new) |>
    readr::write_csv(p_out("manifest.csv"))
}

# Compute once, reload afterwards, and refuse to reload a stale result.
cached <- function(path, inputs, expr) {
  check_inputs(path, inputs)
  if (file.exists(path)) return(readRDS(path))
  x <- force(expr)
  saveRDS(x, path)
  record_inputs(path, inputs)
  x
}

# ---- 3. Topic model helpers --------------------------------------------------

# Tokens for the topic model: lowercase, letters only, no stopwords, no month
# or weekday names (they would let topics encode the year), and no words in
# `drop` (boilerplate every speech shares).
clean_tokens <- function(paras, drop = character()) {
  temporal <- str_to_lower(c(month.name, month.abb, "monday", "tuesday",
                             "wednesday", "thursday", "friday", "saturday",
                             "sunday"))
  paras |>
    dplyr::select(para_uid, text) |>
    tidytext::unnest_tokens(word, text) |>
    dplyr::mutate(word = str_remove_all(word, "'")) |>
    dplyr::filter(str_detect(word, "^[a-z]{2,}$"),
                  !word %in% tidytext::get_stopwords()$word,
                  !word %in% temporal, !word %in% drop)
}

# Tokens to stm's input format: a vocabulary, and per paragraph a 2-row
# integer matrix of (word index, count). Words in fewer than min_docfreq
# paragraphs are dropped. Built directly because stm::readCorpus loses names.
stm_input <- function(tokens, min_docfreq) {
  counts <- tokens |>
    dplyr::count(para_uid, word) |>
    dplyr::add_count(word, name = "docfreq") |>
    dplyr::filter(docfreq >= min_docfreq)
  vocab <- sort(unique(counts$word))
  counts <- dplyr::mutate(counts, i = match(word, vocab)) |> dplyr::arrange(para_uid, i)
  documents <- split(counts, counts$para_uid) |>
    purrr::map(function(d) rbind(as.integer(d$i), as.integer(d$n)))
  list(documents = documents, vocab = vocab)
}

# ---- 4. Shares and trends ----------------------------------------------------

# Standard errors clustered on speech, since paragraphs from one speech are
# correlated (sandwich estimator written out to avoid a dependency).
cluster_vcov <- function(model, cluster) {
  X <- stats::model.matrix(model)
  u <- stats::residuals(model, type = "working") * stats::weights(model, "working")
  S <- rowsum(X * u, cluster)
  G <- nrow(S)
  bread <- summary(model)$cov.unscaled
  bread %*% crossprod(S) %*% bread * G / (G - 1)
}

# Expected share of topic k by year. A fractional logit (quasibinomial glm on
# the topic share; Papke and Wooldridge 1996) keeps every prediction between
# 0 and 1, unlike stm::estimateEffect. It is refit on each draw of theta and
# the draws are combined on the logit scale (mean, plus within- and
# between-draw variance), so the interval carries the topic model's own
# uncertainty as well as clustering by speech.
topic_trend <- function(draws, k, bs, grid, cluster) {
  X <- cbind(1, stats::predict(bs, newx = grid))
  fits <- purrr::map(draws, function(th) {
    m <- stats::glm(th[, k] ~ bs, family = stats::quasibinomial())
    V <- cluster_vcov(m, cluster)
    list(lp = as.numeric(X %*% stats::coef(m)), v = rowSums((X %*% V) * X))
  })
  lp <- do.call(cbind, purrr::map(fits, "lp"))
  v <- do.call(cbind, purrr::map(fits, "v"))
  est <- rowMeans(lp)
  se <- sqrt(rowMeans(v) + (1 + 1 / ncol(lp)) * apply(lp, 1, stats::var))
  tibble::tibble(year = grid, topic = k, fit = stats::plogis(est),
                 lo = stats::plogis(est - 1.96 * se),
                 hi = stats::plogis(est + 1.96 * se))
}

# Share of a 0/1 outcome with a 95% interval clustered by speech.
share_ci <- function(y, cluster) {
  if (!length(y)) return(tibble::tibble(n = 0L, share = NA_real_, lo = NA_real_, hi = NA_real_))
  p <- mean(y)
  z <- tapply(y - p, cluster, sum) / length(y)
  G <- length(z)
  se <- if (G > 1) sqrt(G / (G - 1) * sum(z^2)) else NA_real_
  tibble::tibble(n = length(y), share = p, lo = max(0, p - 1.96 * se),
                 hi = min(1, p + 1.96 * se))
}

# P(y = 1) by year: logistic regression on a year spline with 95% intervals
# clustered by speech. With fewer than 10 paragraphs on the smaller side the
# curve is a straight line in year; under min_n, or with separation, it stops.
# Predictions are only at years that have data, so a gap is never drawn as
# if observed.
trend_curve <- function(y, year, cluster, df_spline = 2L, min_n = 5L) {
  small <- min(sum(y), sum(1 - y))
  if (small < min_n)
    stop(glue::glue("too few paragraphs on one side ({sum(y)} vs {sum(1 - y)}; need {min_n})"))
  df <- if (small < 10 || dplyr::n_distinct(year) <= df_spline + 1) 1L else df_spline
  bs <- splines::ns(year, df = df)
  m <- stats::glm(y ~ bs, family = stats::quasibinomial())
  mu <- stats::fitted(m)
  if (!m$converged || any(mu < 1e-8 | mu > 1 - 1e-8))
    stop("separation: the outcome is (nearly) certain over part of the years")
  V <- cluster_vcov(m, cluster)
  grid <- sort(unique(year))
  X <- cbind(1, stats::predict(bs, newx = grid))
  lp <- as.numeric(X %*% stats::coef(m))
  se <- sqrt(rowSums((X %*% V) * X))
  tibble::tibble(year = grid, fit = stats::plogis(lp),
                 lo = stats::plogis(lp - 1.96 * se),
                 hi = stats::plogis(lp + 1.96 * se), df = df)
}

# ---- 5. Tables for Typst -----------------------------------------------------
# Typst will not break a captioned table across pages, so long tables are
# printed in blocks of `rows`. Chunks that call these need results: asis.

tbl_paged <- function(df, caption = NULL, rows = 20L, max_chars = 60L) {
  d <- df |>
    dplyr::mutate(dplyr::across(dplyr::where(is.numeric), function(x) round(x, 3)),
                  dplyr::across(dplyr::where(is.character),
                                function(x) str_trunc(x, max_chars)))
  if (!is.null(caption)) writeLines(c("", str_c("**", caption, "**"), ""))
  split(d, (seq_len(nrow(d)) - 1L) %/% rows) |>
    purrr::walk(function(p) writeLines(c(knitr::kable(p, format = "pipe"), "")))
  invisible(df)
}

tbl_records <- function(df, title_col, body_cols, caption = NULL) {
  if (!is.null(caption)) writeLines(c("", str_c("**", caption, "**"), ""))
  purrr::pwalk(df, function(...) {
    r <- list(...)
    writeLines(c(str_c("**", r[[title_col]], "**"),
                 str_c("- ", body_cols, ": ", unlist(r[body_cols])), ""))
  })
  invisible(df)
}
