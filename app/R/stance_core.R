# stance_core.R: stance coding and trends. One copy, used by the app's Stance
# tab and by code/stance.qmd (llm_source.R sources this file).
#
# The model is reached over a plain OpenAI-compatible endpoint, one paragraph
# per request, in order. Two environment variables name it, and both are
# written into every result so each estimate records what produced it:
#   STANCE_URL    base URL, e.g. http://gemma-host:8000/v1
#   STANCE_MODEL  model name as the server knows it
#   STANCE_KEY    optional; sent as a bearer token when set (not needed at work)

stance_labels <- c("favor", "neutral", "oppose", "irrelevant")

stance_endpoint <- function() {
  ep <- list(url = Sys.getenv("STANCE_URL"), model = Sys.getenv("STANCE_MODEL"),
             key = Sys.getenv("STANCE_KEY"))
  if (!nzchar(ep$url) || !nzchar(ep$model))
    stop("Set STANCE_URL and STANCE_MODEL (in .Renviron, or the app's environment variables on Posit Connect).")
  ep
}

stance_prompt <- function(proposition) paste0(
  "ROLE\nYou are a survey methodologist coding stance in public comments.\n\n",
  "TASK\nDecide the author's position toward this proposition: \"", proposition, "\". ",
  "First decide whether the text addresses the proposition at all; if not, the ",
  "label is irrelevant. Otherwise decide favor, oppose, or neutral.\n\n",
  "RULES\n",
  "- Stance is measured only toward the proposition.\n",
  "- Stance is not tone: an angry passage can favor the proposition.\n",
  "- Judge only the text shown; use no outside knowledge.\n",
  "- If the text is ambiguous, choose neutral rather than guessing.\n\n",
  "OUTPUT\nReply with one word: favor, neutral, oppose, or irrelevant.")

# One paragraph, one request. Returns the label, or NA with the reason
# attached when the call fails or the reply holds no label.
code_one <- function(text, prompt, ep) {
  req <- httr2::request(ep$url) |>
    httr2::req_url_path_append("chat/completions") |>
    httr2::req_body_json(list(
      model = ep$model, temperature = 0, max_tokens = 20,
      messages = list(list(role = "system", content = prompt),
                      list(role = "user", content = paste("Text:", text))))) |>
    httr2::req_timeout(120) |>
    httr2::req_retry(max_tries = 3)
  if (nzchar(ep$key %||% "")) req <- httr2::req_auth_bearer_token(req, ep$key)
  resp <- tryCatch(httr2::req_perform(req),
    error = function(e) e)
  if (inherits(resp, "error")) return(structure(NA_character_, error = conditionMessage(resp)))
  reply <- tolower(httr2::resp_body_json(resp)$choices[[1]]$message$content %||% "")
  hit <- regmatches(reply, regexpr(paste(stance_labels, collapse = "|"), reply))
  if (length(hit)) hit else structure(NA_character_, error = paste0("no label in reply: \"", reply, "\""))
}

# Every paragraph in order. on_step(i, n) runs after each one, for a progress
# bar. The first paragraph is a probe: if it fails, the run stops with the
# reason rather than working through a corpus it cannot reach.
code_all <- function(text, proposition, ep, on_step = function(i, n) NULL) {
  prompt <- stance_prompt(proposition)
  n <- length(text)
  probe <- code_one(text[[1]], prompt, ep)
  if (is.na(probe) && !startsWith(attr(probe, "error"), "no label"))
    stop("The model could not be reached or did not answer: ", attr(probe, "error"))
  res <- purrr::imap(unname(text), function(t, i) {
    r <- if (i == 1L) probe else code_one(t, prompt, ep)
    on_step(i, n)
    r
  })
  lab <- purrr::map_chr(res, function(r) as.character(r))
  if (all(is.na(lab)))
    stop("No paragraph was labeled. First problem: ", attr(res[[1]], "error"))
  lab
}

# ---- Shares and trends -----------------------------------------------------

# Standard errors clustered on comment, since paragraphs from one comment are
# correlated (sandwich estimator written out to avoid a dependency).
cluster_vcov <- function(model, cluster) {
  X <- stats::model.matrix(model)
  u <- stats::residuals(model, type = "working") * stats::weights(model, "working")
  S <- rowsum(X * u, cluster)
  G <- nrow(S)
  bread <- summary(model)$cov.unscaled
  bread %*% crossprod(S) %*% bread * G / (G - 1)
}

# P(y = 1) by year: logistic regression on a year spline with 95% intervals
# clustered by comment. With fewer than 10 paragraphs on the smaller side the
# curve is a straight line in year; under min_n, or with separation, it stops.
trend_curve <- function(y, year, cluster, df_spline = 2L, min_n = 5L) {
  small <- min(sum(y), sum(1 - y))
  if (small < min_n)
    stop(sprintf("too few paragraphs on one side (%d vs %d; need %d)",
                 sum(y), sum(1 - y), min_n))
  df <- if (small < 10) 1L else df_spline
  bs <- splines::ns(year, df = df)
  m <- stats::glm(y ~ bs, family = stats::quasibinomial())
  mu <- stats::fitted(m)
  if (!m$converged || any(mu < 1e-8 | mu > 1 - 1e-8))
    stop("separation: the label is (nearly) certain over part of the years")
  V <- cluster_vcov(m, cluster)
  grid <- sort(unique(year))
  X <- cbind(1, stats::predict(bs, newx = grid))
  lp <- as.numeric(X %*% stats::coef(m))
  se <- sqrt(rowSums((X %*% V) * X))
  tibble::tibble(Year = grid, fit = stats::plogis(lp),
                 lo = stats::plogis(lp - 1.96 * se),
                 hi = stats::plogis(lp + 1.96 * se), df = df)
}

# Share of a 0/1 outcome with a 95% interval clustered by comment.
share_ci <- function(y, cluster) {
  p <- mean(y)
  z <- tapply(y - p, cluster, sum) / length(y)
  G <- length(z)
  se <- sqrt(G / (G - 1) * sum(z^2))
  tibble::tibble(share = p, lo = max(0, p - 1.96 * se), hi = min(1, p + 1.96 * se))
}

# One trend per label, each the label's share of ALL coded paragraphs in a
# year. A label too rare for a curve is left out, with the reason in
# attr(, "notes").
stance_trends <- function(label, year, cluster, df_spline = 2L, min_n = 5L) {
  fits <- purrr::map(stats::setNames(stance_labels, stance_labels), function(l)
    tryCatch(trend_curve(as.integer(label == l), year, cluster, df_spline, min_n),
             error = function(e) conditionMessage(e)))
  ok <- purrr::map_lgl(fits, is.data.frame)
  out <- purrr::list_rbind(purrr::imap(fits[ok], function(d, l) dplyr::mutate(d, label = l, .before = 1)))
  n_year <- dplyr::count(tibble::tibble(Year = year), Year, name = "paragraphs")
  out <- dplyr::left_join(out, n_year, by = "Year")
  attr(out, "notes") <- if (any(!ok)) paste0(names(fits)[!ok], ": no trend, ", unlist(fits[!ok]))
  out
}

# Overall share of each label, with intervals.
stance_overall <- function(label, cluster) {
  purrr::list_rbind(purrr::map(stance_labels, function(l)
    dplyr::mutate(share_ci(as.integer(label == l), cluster), label = l, .before = 1)))
}

# The yearly estimates with the record of what produced them: one CSV row per
# label and year.
stance_record <- function(trends, proposition, ep, n_coded) {
  dplyr::mutate(trends, proposition = proposition, model = ep$model,
                endpoint = ep$url, paragraphs_coded = n_coded,
                date = as.character(Sys.Date()))
}

stance_plot <- function(trends) {
  # one panel per label with its own scale: irrelevant is usually most of the
  # text and would flatten the others on a shared axis
  ggplot2::ggplot(trends, ggplot2::aes(Year, fit)) +
    ggplot2::geom_ribbon(ggplot2::aes(ymin = lo, ymax = hi), alpha = 0.2, fill = "#3b528b") +
    ggplot2::geom_line(linewidth = 0.9, color = "#3b528b") +
    ggplot2::facet_wrap(~ factor(label, stance_labels), scales = "free_y") +
    ggplot2::scale_y_continuous(labels = function(x) paste0(round(100 * x, 1), "%")) +
    ggplot2::labs(x = NULL, y = "share of all paragraphs") +
    ggplot2::theme_minimal(base_size = 13)
}
