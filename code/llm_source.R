# llm_source.R ----------------------------------------------------------------
# Functions for llm_stance.qmd. Four sections:
#   (1) Prompts and the per-step router
#   (2) Census classification: sequential calls, sleep at the quota window,
#       incremental label store
#   (3) Estimation: era proportions, cluster-robust trend, recovery curve
#   (4) QC and documentation: agreement, class metrics, data-dict.yaml
# Conventions: native |>, no loops (purrr), dplyr namespaced, ellmer namespaced.

# ---- (1) Prompts and router --------------------------------------------------

# Every prompt has the same four parts, in this order:
#   role   expertise framing, so the model reads as the right kind of analyst
#   task   what to do and how to self-check before answering
#   rules  guardrails against invention and drift (anti-hallucination slot)
#   output what to return; paired with a schema that enforces the shape
build_prompt <- function(role, task, rules, output) {
  str_c("ROLE\n", role,
        "\n\nTASK\n", task,
        "\n\nRULES\n", str_c("- ", rules, collapse = "\n"),
        "\n\nOUTPUT\n", output)
}

# One chat per step. st$steps maps each step to the NAME of the environment
# variable holding its base URL, plus its model string, so different steps can
# point at different gateways and no URL or key ever appears in the script.
# Home uses the OpenRouter helper; work uses the OpenAI-compatible endpoint.
make_chat <- function(step, system_prompt, cfg_steps, home = FALSE) {
  cfg <- cfg_steps[cfg_steps$step == step, ]
  if (nrow(cfg) != 1)
    stop("No unique config row for step '", step, "' in the steps table.")
  if (isTRUE(home)) return(make_chat_home(cfg$model, system_prompt))

  url <- Sys.getenv(cfg$base_url_env)
  key <- Sys.getenv(cfg$api_key_env)
  if (!nzchar(url)) stop("Environment variable ", cfg$base_url_env,
                         " is empty; set it in .Renviron for step '", step, "'.")
  if (!nzchar(key)) stop("Environment variable ", cfg$api_key_env,
                         " is empty; set it in .Renviron for step '", step, "'.")
  # NOTE: ellmer has ignored api_key= in some versions, so the key is ALSO
  # exported under the standard name for the duration of this call. If your
  # ellmer names the argument differently, this is the ONE line to change.
  withr::with_envvar(c(OPENAI_API_KEY = key), {
    ellmer::chat_openai_compatible(
      model = cfg$model, base_url = url, api_key = key,
      system_prompt = system_prompt,
      params = ellmer::params(temperature = 0), echo = "none")
  })
}

# ---- (2) Census classification ------------------------------------------------

# One structured call. The chat is clone()d so each call starts from a fresh
# conversation: without it ellmer appends turns and later paragraphs are judged
# with earlier ones in context. NULL on failure instead of aborting the run.
call_one <- function(chat, prompt, schema) {
  tryCatch(chat$clone()$chat_structured(prompt, type = schema),
           error = function(e) NULL)
}

# Classify a character vector sequentially, sleeping when the quota window is
# spent. Budget is per model, so `window_n` calls then `window_wait` seconds.
# Recursion, not a loop: each block of window_n is one call to this function.
# Failures inside a block are left as NA and retried by the caller's rerun,
# because the incremental store means a re-render re-sends only what is missing.
classify_census <- function(chat, prompts, ids, schema, window_n, window_wait,
                            done = 0L) {
  take   <- seq_len(min(window_n, length(prompts)))
  res    <- purrr::map(prompts[take], call_one, chat = chat, schema = schema)
  block  <- tibble::tibble(
    id    = ids[take],
    label = purrr::map_chr(res, ~ .x$label %||% NA_character_))
  done   <- done + length(take)
  if (length(prompts) <= length(take)) return(block)
  message(glue::glue("classified {done} of {done + length(prompts) - \\
                      length(take)}; sleeping {window_wait}s for the quota \\
                      window to reset"))
  Sys.sleep(window_wait)
  dplyr::bind_rows(block,
    classify_census(chat, prompts[-take], ids[-take], schema,
                    window_n, window_wait, done))
}

# ---- (3) Estimation ------------------------------------------------------------

# Cluster-robust standard errors on the comment: paragraphs from one author are
# correlated, so the naive glm SE is too small. This is the sandwich estimator
# with the comment as the cluster, implemented directly to avoid a dependency.
# It is a superpopulation (analytic) statement: the corpus is treated as one
# realization of a comment-generating process. A purely descriptive claim about
# THIS corpus needs no interval at all, since every paragraph was classified.
cluster_robust_vcov <- function(model, cluster) {
  X   <- model.matrix(model)
  u   <- residuals(model, type = "working") * weights(model, "working")
  bread <- summary(model)$cov.unscaled
  meat  <- purrr::map(split(seq_along(cluster), cluster), function(i) {
    s <- crossprod(X[i, , drop = FALSE], u[i])
    tcrossprod(s)
  }) |> purrr::reduce(`+`)
  G  <- dplyr::n_distinct(cluster)
  adj <- G / (G - 1)
  bread %*% meat %*% bread * adj
}

# Fitted P(outcome) by year with cluster-robust 95 percent intervals.
trend_curve <- function(d, outcome, cluster, df_spline = 3L) {
  d   <- dplyr::mutate(d, .y = as.integer(.data[[outcome]]))
  bs  <- splines::ns(d$Year, df = df_spline)
  colnames(bs) <- str_c("yr", seq_len(ncol(bs)))
  dd  <- dplyr::bind_cols(d, tibble::as_tibble(bs))
  f   <- as.formula(str_c(".y ~ ", str_c(colnames(bs), collapse = " + ")))
  m   <- glm(f, data = dd, family = quasibinomial())
  V   <- cluster_robust_vcov(m, dd[[cluster]])
  grid <- sort(unique(d$Year))
  Xg   <- cbind(1, predict(bs, newx = grid))
  lp   <- as.numeric(Xg %*% coef(m))
  se   <- sqrt(rowSums((Xg %*% V) * Xg))
  # Clustering diagnostic: the ratio of robust to naive standard errors. NOT
  # the quasibinomial dispersion, which is unidentified for 0/1 outcomes (the
  # Bernoulli variance is fixed by the mean) and sits near 1 even under heavy
  # clustering. A ratio near 1 means clustering costs little; 2 means the
  # naive interval would have been half as wide as it should be.
  se_ratio <- mean(sqrt(diag(V)) / sqrt(diag(summary(m)$cov.scaled)))
  tibble::tibble(Year = grid, fit = plogis(lp),
                 lo = plogis(lp - 1.96 * se), hi = plogis(lp + 1.96 * se),
                 se_ratio = se_ratio)
}

# Recovery curve: how many paragraphs would have sufficed? Subsamples the
# census at increasing sizes, refits the trend, and measures the mean absolute
# deviation from the full-census curve. Costs no API calls, because every
# paragraph is already labeled. Comments are sampled, not paragraphs, so the
# subsample has the same clustered shape as a real collection would.
recovery_curve <- function(d, outcome, sizes, reps, df_spline = 3L, seed = 1L) {
  full <- trend_curve(d, outcome, "atom_id", df_spline)
  set.seed(seed)
  purrr::map(sizes, function(n) {
    purrr::map(seq_len(reps), function(r) {
      cl  <- unique(d$atom_id)
      per <- max(1, round(n / (nrow(d) / length(cl))))
      sub <- d |> dplyr::filter(atom_id %in% sample(cl, min(per, length(cl))))
      if (dplyr::n_distinct(sub$Year) < df_spline + 1) return(NULL)
      cur <- trend_curve(sub, outcome, "atom_id", df_spline)
      tibble::tibble(n_target = n, rep = r, n_actual = nrow(sub),
                     mad = mean(abs(cur$fit - full$fit[match(cur$Year,
                                                             full$Year)])))
    }) |> purrr::list_rbind()
  }) |> purrr::list_rbind()
}

# ---- (4) QC and documentation --------------------------------------------------

# Cohen's kappa with raw agreement and the confusion table. Kappa has no
# validated interpretive thresholds, so all three are reported and none is
# translated into an adjective.
agreement <- function(a, b, dnn = c("a", "b")) {
  keep <- !is.na(a) & !is.na(b)
  a <- as.character(a[keep]); b <- as.character(b[keep])
  lev <- sort(union(a, b))
  po  <- mean(a == b)
  pe  <- sum(purrr::map_dbl(lev, ~ mean(a == .x) * mean(b == .x)))
  list(n = length(a), raw = po, kappa = (po - pe) / (1 - pe),
       confusion = table(a, b, dnn = dnn))
}

# Per-class precision, recall, F1 and macro-F1 against a reference vector.
# Macro-F1 is the headline under class imbalance; accuracy is not.
class_metrics <- function(pred, ref) {
  keep <- !is.na(pred) & !is.na(ref)
  pred <- pred[keep]; ref <- ref[keep]
  per <- purrr::map(sort(union(pred, ref)), function(cl) {
    tp <- sum(pred == cl & ref == cl); fp <- sum(pred == cl & ref != cl)
    fn <- sum(pred != cl & ref == cl)
    pr <- if (tp + fp > 0) tp / (tp + fp) else NA_real_
    rc <- if (tp + fn > 0) tp / (tp + fn) else NA_real_
    tibble::tibble(class = cl, precision = pr, recall = rc,
                   f1 = if (!is.na(pr) && !is.na(rc) && pr + rc > 0)
                          2 * pr * rc / (pr + rc) else NA_real_,
                   support = sum(ref == cl))
  }) |> purrr::list_rbind()
  list(per_class = per, macro_f1 = mean(per$f1, na.rm = TRUE),
       accuracy = mean(pred == ref))
}

# Emit a data-dict.yaml describing the tables written, following the
# data-dict.yaml specification (Posit). Generated from the objects themselves
# so it cannot drift from what was written. NOTE: the spec assumes parquet or
# database tables; these outputs are CSV by project convention, so the document
# is spec-shaped but the data-dict CLI validator may not run against it.
emit_data_dict <- function(path, name, description, tables, glossary) {
  q <- function(x) str_c('"', str_replace_all(x, '"', "'"), '"')
  var_block <- function(df, descs) {
    purrr::map_chr(names(df), function(v) str_c(
      "      - name: ", v,
      "\n        type: ", dplyr::case_when(
        is.numeric(df[[v]]) &&
          isTRUE(all(df[[v]] == round(df[[v]]), na.rm = TRUE)) ~ "integer",
        is.numeric(df[[v]]) ~ "double",
        is.logical(df[[v]]) ~ "boolean", TRUE ~ "string"),
      "\n        description: ", q(descs[[v]] %||% "undocumented"))) |>
      str_c(collapse = "\n")
  }
  writeLines(str_c(
    "# data-dict.yaml (spec: https://data-dict.tidyverse.org/)\n",
    "# Generated by llm_stance.qmd; edit the script, not this file.\n",
    "name: ", name, "\ndescription: ", q(description),
    "\nversion: ", format(Sys.Date()), "\ntables:\n",
    purrr::map_chr(tables, function(t) str_c(
      "  - name: ", t$name, "\n    path: ", t$path,
      "\n    description: ", q(t$description),
      "\n    rows: ", nrow(t$data),
      "\n    variables:\n", var_block(t$data, t$vars))) |>
      str_c(collapse = "\n"),
    "\nglossary:\n",
    purrr::map_chr(names(glossary), function(g) str_c(
      "  - term: ", q(g), "\n    definition: ", q(glossary[[g]]))) |>
      str_c(collapse = "\n"), "\n"), path)
  invisible(path)
}

# ---- (5) Table printing -------------------------------------------------------
# Typst does not paginate a captioned table: kable + caption becomes a #figure,
# and figures do not break across pages, so a long table is clipped no matter
# what column widths or show rules are set. The fix is to never hand Typst a
# table taller than a page. tbl_paged() splits the rows into blocks, truncates
# long character columns, and emits each block as its own pipe table.
# The chunk MUST carry results: asis. writeLines is used rather than print(),
# which silently swallows kable output under results: asis.
tbl_paged <- function(df, caption = NULL, rows = 20L, max_chars = 60L,
                      digits = 3L) {
  d <- df |>
    dplyr::mutate(dplyr::across(dplyr::where(is.numeric), ~ round(.x, digits)),
                  dplyr::across(dplyr::where(is.character),
                                ~ str_trunc(.x, max_chars)))
  pages <- split(d, (seq_len(nrow(d)) - 1L) %/% rows)
  purrr::iwalk(pages, function(p, i) {
    n <- as.integer(i) + 1L
    head <- if (is.null(caption)) NULL else if (n == 1L) caption else
      str_c(caption, " (continued, ", n, " of ", length(pages), ")")
    if (!is.null(head)) writeLines(c("", str_c("**", head, "**"), ""))
    writeLines(knitr::kable(p, format = "pipe"))
    writeLines("")
  })
  invisible(df)
}

# Long free text does not belong in a table at all: any column width that fits
# the page makes the text unreadable, and any width that fits the text overflows.
# tbl_records() prints one short block per row instead, which wraps naturally.
tbl_records <- function(df, title_col, body_cols, caption = NULL) {
  if (!is.null(caption)) writeLines(c("", str_c("**", caption, "**"), ""))
  purrr::pwalk(df, function(...) {
    r <- list(...)
    writeLines(str_c("**", r[[title_col]], "**"))
    writeLines(purrr::map_chr(body_cols, ~ str_c("- ", .x, ": ", r[[.x]])))
    writeLines("")
  })
  invisible(df)
}
