# llm_source.R ----------------------------------------------------------------
# Shared functions for 01_preprocess.qmd, 02_topics.qmd, and 03_stance.qmd:
#   (1) Prompts and the per-step router
#   (2) Census classification: sequential calls, sleep at the quota window
#   (3) Estimation: era proportions, cluster-robust trend, recovery curve
#   (4) QC and documentation: agreement, class metrics, data-dict.yaml
#   (5) Table printing that paginates under Typst
#   (6) Paragraph linkage: blocks, gating, embeddings, calibrated merging
#   (7) Parse sensitivity: topic matching across refits
#   (8) Fingerprint guards between scripts
#   (9) Topic dashboard: one self-contained HTML file
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
  # Separation: when the outcome is perfectly predicted over part of the year
  # range (every relevant paragraph after some year is "favor", say), the
  # logistic coefficients diverge, fitted values pin to 0 or 1, and the
  # interval balloons to [0, 1]. R warns about this for binomial but not for
  # quasibinomial, so it is checked directly. A separated fit is refused
  # rather than drawn: its curve and interval are artifacts, not estimates.
  mu <- stats::fitted(m)
  if (!m$converged || any(mu < 1e-8 | mu > 1 - 1e-8))
    stop("separation: the outcome is (nearly) perfectly predicted over part ",
         "of the year range, so no stable curve can be estimated")
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

# Minimum support before a spline trend is attempted for one class: enough
# positives and negatives to estimate df_spline + 1 coefficients, and
# positives spread over more distinct years than the spline has degrees of
# freedom. Returns NULL when supported, otherwise the reason in plain words.
class_support <- function(y, year, df_spline, min_n) {
  if (sum(y) < min_n) return(glue::glue("{sum(y)} paragraphs (need {min_n})"))
  if (sum(1 - y) < min_n)
    return(glue::glue("only {sum(1 - y)} paragraphs outside the class (need {min_n})"))
  if (dplyr::n_distinct(year[y == 1]) <= df_spline)
    return(glue::glue("positives in only {dplyr::n_distinct(year[y == 1])} years"))
  NULL
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
      # Small subsamples often separate even when the census does not; such a
      # replicate is skipped, and the count of usable replicates is reported.
      cur <- tryCatch(trend_curve(sub, outcome, "atom_id", df_spline),
                      error = function(e) NULL)
      if (is.null(cur)) return(NULL)
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
    "# Generated by 03_stance.qmd; edit the script, not this file.\n",
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

# ---- (6) Paragraph linkage ------------------------------------------------------
# Blocks are the text between newline runs. Where authors wrote real
# paragraphs, blocks already are paragraphs; where they put a blank line after
# every sentence, blocks are orphan sentences. Linkage merges adjacent blocks,
# most similar pair first, until every unit reaches the size floor. It is the
# PSU-formation move of combining small units with a contiguous neighbor until
# the minimum measure of size is met, with semantic similarity choosing which
# neighbor. Contiguity is never broken, so reading order survives.

# Hard-wrapped text (a line break every few words) splits one sentence into
# several blocks. A block is a FRAGMENT when the block before it ends without
# terminal punctuation and it starts with a lowercase letter; fragments are
# joined back to that block before anything else runs. The rule is deliberately
# conservative: a wrap before a capitalized word ("I", a name) is left for the
# embedding linkage to repair, and headings, which are followed by capitalized
# text, are never absorbed here.
split_blocks <- function(corpus) {
  raw <- corpus |>
    dplyr::mutate(block = str_split(body_english, "\\r?\\n+")) |>
    dplyr::select(atom_id, Year, block) |>
    tidyr::unnest(block) |>
    dplyr::mutate(block = str_squish(block)) |>
    dplyr::filter(block != "")
  out <- raw |>
    dplyr::group_by(atom_id) |>
    dplyr::mutate(fragment = !str_detect(dplyr::lag(block, default = "."),
                                         "[.!?:;][\"')\\]]*$") &
                    str_detect(block, "^[a-z]"),
                  block_id = cumsum(!fragment)) |>
    dplyr::group_by(atom_id, Year, block_id) |>
    dplyr::summarise(block = str_c(block, collapse = " "),
                     n_lines = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(n_tokens = str_count(block, "\\S+"),
                  # sentence-ending punctuation followed by space or end;
                  # a heuristic (abbreviations can overcount), used only to
                  # find author-formed multi-sentence paragraphs
                  n_sent = pmax(1L, str_count(block, "[.!?]+(\\s|$)")))
  attr(out, "rejoin") <- tibble::tibble(
    lines_in = nrow(raw), blocks_out = nrow(out),
    fragments_joined = nrow(raw) - nrow(out),
    median_chars_in = stats::median(nchar(raw$block)),
    median_chars_out = stats::median(nchar(out$block)),
    share_no_end_punct = mean(!str_detect(raw$block, "[.!?:;][\"')\\]]*$")))
  out
}

# Which documents need linkage, and what length to aim for. A document is
# UNPARAGRAPHED when its median block is a single sentence: the author put a
# break after (nearly) every sentence. Paragraphed documents pass through
# untouched, since their blocks already are the author's paragraphs. The target
# length is the median of ALL blocks in paragraphed documents, i.e. how long
# this corpus's authors make a paragraph when they do make one. Stops by name
# when too few author paragraphs exist to anchor that median.
plan_linkage <- function(blocks, min_anchor) {
  doc <- blocks |>
    dplyr::group_by(atom_id) |>
    dplyr::summarise(paragraphed = stats::median(n_sent) > 1, .groups = "drop")
  anchor <- blocks |>
    dplyr::semi_join(dplyr::filter(doc, paragraphed), by = "atom_id")
  if (nrow(anchor) < min_anchor)
    stop("Only ", nrow(anchor), " paragraphs found in documents with paragraph ",
         "markup; at least ", min_anchor, " are needed to anchor the target ",
         "length. This corpus has no internal paragraph anchor.")
  list(doc = doc, target = stats::median(anchor$n_tokens),
       n_anchor = nrow(anchor), quartiles = stats::quantile(anchor$n_tokens,
                                                            c(.25, .75)))
}

# Embedding endpoint for the embed step: URL, key, and model. The OpenAI
# embeddings format is served by OpenRouter and by OpenAI-compatible gateways.
embed_endpoint <- function(cfg_steps, home = FALSE) {
  cfg <- cfg_steps[cfg_steps$step == "embed", ]
  if (nrow(cfg) != 1) stop("No unique 'embed' row in the steps table.")
  if (isTRUE(home)) return(embed_endpoint_home(cfg$model))
  url <- Sys.getenv(cfg$base_url_env); key <- Sys.getenv(cfg$api_key_env)
  if (!nzchar(url) || !nzchar(key))
    stop("Set ", cfg$base_url_env, " and ", cfg$api_key_env, " in .Renviron.")
  list(url = url, key = key, model = unname(cfg$model))
}

# One document's blocks as one request. Only model and input are sent, so
# strict providers that reject extra fields (Mistral, HTTP 422) accept it.
# Transient failures (429, 503) are retried with backoff; any other HTTP
# error carries the provider's own message.
embed_request <- function(txt, ep) {
  httr2::request(ep$url) |>
    httr2::req_url_path_append("embeddings") |>
    httr2::req_auth_bearer_token(ep$key) |>
    httr2::req_body_json(list(model = ep$model, input = as.list(txt))) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_error(body = function(resp)
      if (httr2::resp_has_body(resp)) httr2::resp_body_string(resp))
}

# Response to a matrix, one row per block in input order.
embed_parse <- function(resp) {
  d <- httr2::resp_body_json(resp)$data
  d <- d[order(purrr::map_int(d, "index"))]
  do.call(rbind, purrr::map(d, function(x) unlist(x$embedding)))
}

# Embed every comment's blocks, one request per comment. Each window sends up
# to window_n requests in parallel, then rests window_wait seconds, so no
# minute ever sees more than window_n calls (set window_n below the provider's
# per-minute limit). The cache is a list keyed by atom_id and is saved after
# every window, so an interrupted run resumes without re-sending anything.
embed_census <- function(blocks, cache_path, cfg_steps, home, window_n,
                         window_wait, max_active = window_n) {
  ep <- embed_endpoint(cfg_steps, home)
  model <- unname(cfg_steps$model[cfg_steps$step == "embed"])
  cache <- if (file.exists(cache_path)) readRDS(cache_path) else
    list(model = model, vec = list(), errors = character())
  if (!identical(unname(cache$model), model))
    stop("Embedding cache was built with model '", cache$model, "'. Delete ",
         basename(cache_path), " to re-embed with the configured model.")
  # A cached vector is reused only if its row count still matches the
  # document's blocks; a changed parse re-sends that document.
  n_blk <- table(blocks$atom_id)
  stale <- names(cache$vec)[purrr::map_lgl(names(cache$vec), function(id)
    id %in% names(n_blk) && nrow(cache$vec[[id]]) != n_blk[[id]])]
  cache$vec[stale] <- NULL
  todo <- setdiff(unique(blocks$atom_id), names(cache$vec))
  n_win <- ceiling(length(todo) / window_n)
  run_window <- function(ids, cache, w) {
    if (length(ids) == 0) return(cache)
    take <- utils::head(ids, window_n)
    message(glue::glue("window {w} of {n_win}: sending {length(take)} requests"))
    reqs <- purrr::map(take, function(id)
      embed_request(blocks$block[blocks$atom_id == id], ep))
    resps <- httr2::req_perform_parallel(reqs, on_error = "continue",
                                         max_active = max_active,
                                         progress = TRUE)
    res <- purrr::map(resps, function(r)
      if (inherits(r, "httr2_response"))
        tryCatch(embed_parse(r), error = function(e) conditionMessage(e))
      else conditionMessage(r)) |>
      purrr::set_names(take)
    ok <- purrr::map_lgl(res, is.matrix)
    cache$vec <- c(cache$vec, res[ok])
    cache$errors <- c(cache$errors[setdiff(names(cache$errors), take[ok])],
                      unlist(res[!ok]))
    saveRDS(cache, cache_path)
    message(glue::glue("window {w}: {sum(ok)} ok, {sum(!ok)} failed; ",
                       "{length(cache$vec)} documents cached"))
    rest <- setdiff(ids, take)
    if (length(rest) == 0) return(cache)
    purrr::walk(seq_len(window_wait), function(s) Sys.sleep(1),
                .progress = glue::glue("resting {window_wait}s"))
    run_window(rest, cache, w + 1L)
  }
  cache <- run_window(todo, cache, 1L)
  # Failures are never dropped silently: a document without a vector cannot
  # be linked, and quietly omitting it would remove it from the corpus.
  missing <- setdiff(unique(blocks$atom_id), names(cache$vec))
  if (length(missing))
    stop(length(missing), " of ", dplyr::n_distinct(blocks$atom_id),
         " documents could not be embedded. First error: ",
         cache$errors[[missing[1]]] %||% "unknown",
         ". Fix the cause and re-run this chunk; documents already embedded ",
         "are cached and will not be re-sent.")
  cache
}

cosine <- function(a, b) sum(a * b) / sqrt(sum(a^2) * sum(b^2))

# Link one document's blocks. Among adjacent pairs where at least one block is
# below the floor, merge the most similar pair; its vector becomes the
# token-weighted mean of the two (an approximation to re-embedding the merged
# text, at zero extra calls). Repeat until no block is below the floor or one
# block remains. Ties resolve to the earlier pair. Deterministic by design:
# this defines the document unit, so a rerun must reproduce it exactly.
# Implemented as purrr::reduce over at most m - 1 merge steps carrying a state
# list, so long documents cannot exhaust the stack the way per-merge recursion
# does. Adjacent similarities are carried in the state and only the two
# touching the merged unit are recomputed, so each merge costs O(1) cosines.
merge_step <- function(st, i) {
  m <- length(st$txt)
  if (m == 1L || all(st$n >= st$floor)) return(st)          # done: no-op
  eligible <- st$n[-m] < st$floor | st$n[-1L] < st$floor
  k <- which.max(replace(st$sims, !eligible, -Inf))
  w <- st$n[k:(k + 1L)] / sum(st$n[k:(k + 1L)])
  st$E[k, ] <- w[1] * st$E[k, ] + w[2] * st$E[k + 1L, ]
  st$txt[k] <- str_c(st$txt[k], " ", st$txt[k + 1L])
  st$n[k] <- st$n[k] + st$n[k + 1L]
  st$b[k] <- st$b[k] + st$b[k + 1L]
  st$log <- c(st$log, st$sims[k])
  st$txt <- st$txt[-(k + 1L)]; st$n <- st$n[-(k + 1L)]; st$b <- st$b[-(k + 1L)]
  st$E <- st$E[-(k + 1L), , drop = FALSE]
  st$sims <- st$sims[-k]                          # pair (k, k+1) is gone
  if (k > 1L) st$sims[k - 1L] <- cosine(st$E[k - 1L, ], st$E[k, ])
  if (k < length(st$txt)) st$sims[k] <- cosine(st$E[k, ], st$E[k + 1L, ])
  st
}

link_comment <- function(txt, n, E, floor) {
  m <- length(txt)
  sims <- if (m > 1L) purrr::map_dbl(seq_len(m - 1L),
                                     ~ cosine(E[.x, ], E[.x + 1L, ])) else numeric()
  st <- purrr::reduce(seq_len(max(0L, m - 1L)), merge_step,
                      .init = list(txt = txt, n = n, b = rep(1L, m), E = E,
                                   floor = floor, sims = sims, log = numeric()))
  list(text = st$txt, n = st$n, n_blocks = st$b,
       log = tibble::tibble(sim = st$log))
}

# Apply linkage across the corpus. Paragraphed documents pass through
# untouched; unparagraphed ones are linked at `floor`. Needs only cached
# vectors, so it reruns at any floor with no API calls, which is what makes
# floor calibration and the sensitivity test free.
link_corpus <- function(blocks, vec, floor, doc) {
  keep <- doc$atom_id[doc$paragraphed]
  no_vec <- setdiff(unique(blocks$atom_id), c(keep, names(vec)))
  if (length(no_vec))
    stop(length(no_vec), " unparagraphed document(s) have no embedding, ",
         "e.g. ", no_vec[1], ". Linking without them would drop them from ",
         "the corpus; re-run the embed chunk.")
  blocks |>
    dplyr::group_split(atom_id) |>
    purrr::map(function(b) {
      id <- b$atom_id[1]
      out <- if (id %in% keep)
        list(text = b$block, n = b$n_tokens, n_blocks = rep(1L, nrow(b)),
             log = tibble::tibble(sim = numeric()))
      else link_comment(b$block, b$n_tokens, vec[[id]], floor)
      u <- length(out$text)
      # the document's merge similarities ride on its FIRST unit only, so
      # unlist() over units counts each merge exactly once
      tibble::tibble(atom_id = id, Year = b$Year[1], text = out$text,
                     n_tokens = out$n, n_blocks = out$n_blocks,
                     relinked = !id %in% keep,
                     merge_sim = c(list(out$log$sim),
                                   rep(list(numeric()), u - 1L)))
    }) |>
    purrr::list_rbind() |>
    dplyr::group_by(atom_id) |>
    dplyr::mutate(para_id = dplyr::row_number(),
                  para_uid = str_c(atom_id, "-", sprintf("%02d", para_id))) |>
    dplyr::ungroup()
}

# The floor is CALIBRATED, not chosen: merging stops once a unit reaches the
# floor, so linked units land between one and two floors and their median sits
# above the floor itself. Bisection finds the floor at which the median length
# of relinked units matches the target (the author-paragraph median). The
# output median is nondecreasing in the floor, so bisection is valid; `iters`
# halvings of (0, target] resolve the floor to target / 2^iters tokens.
calibrate_floor <- function(blocks, vec, doc, target, iters = 8L) {
  sub <- blocks |> dplyr::semi_join(dplyr::filter(doc, !paragraphed),
                                    by = "atom_id")
  if (nrow(sub) == 0) return(list(floor = target, median_out = NA_real_))
  med <- function(f) stats::median(link_corpus(sub, vec, f, doc)$n_tokens)
  step <- function(lo, hi, i) {
    mid <- (lo + hi) / 2
    if (i == 0L) return(mid)
    if (med(mid) < target) step(mid, hi, i - 1L) else step(lo, mid, i - 1L)
  }
  f <- step(0, target, iters)
  list(floor = f, median_out = med(f))
}

# ---- (7) Parse sensitivity -------------------------------------------------------
# Does the size floor drive the topics? Relink at each multiple of the floor
# (cached vectors, no API calls), fit STM at the same K, and match every
# topic to its best counterpart in the baseline fit by the cosine of the
# topic-word distributions over the shared vocabulary, one-to-one via the
# Hungarian algorithm. Reported as similarities, with no invented pass mark.
beta_matrix <- function(fit) {
  b <- exp(fit$beta$logbeta[[1]])
  colnames(b) <- fit$vocab
  b
}

match_topics <- function(b_ref, b_alt) {
  v <- intersect(colnames(b_ref), colnames(b_alt))
  norm_rows <- function(m) m / sqrt(rowSums(m^2))
  S <- norm_rows(b_ref[, v, drop = FALSE]) %*%
    t(norm_rows(b_alt[, v, drop = FALSE]))
  assign <- clue::solve_LSAP(S, maximum = TRUE)
  tibble::tibble(topic = seq_len(nrow(S)),
                 matched = as.integer(assign),
                 cosine = S[cbind(seq_len(nrow(S)), as.integer(assign))],
                 shared_vocab = length(v))
}

# ---- (8) Fingerprint guards between scripts ---------------------------------------
# Caches track files, not code, and with three scripts the classic failure is
# rerunning an upstream script and reloading a downstream cache built from the
# old inputs. Every guarded output carries a sidecar, <output>.inputs.csv,
# listing the md5 of each input file it was built from. md5 rather than
# modification time, because a re-render that writes identical content must
# not trip the guard.

fingerprint <- function(inputs) {
  missing <- inputs[!file.exists(inputs)]
  if (length(missing))
    stop("Input file(s) not found: ", str_c(basename(missing), collapse = ", "),
         ". Render the upstream script first.")
  tibble::tibble(file = basename(inputs), md5 = unname(tools::md5sum(inputs)))
}

# Stop by name when an existing output was built from different inputs.
# strict = FALSE tolerates a missing sidecar (a file you created by hand).
check_fingerprint <- function(output, inputs, strict = TRUE) {
  side <- str_c(output, ".inputs.csv")
  if (!file.exists(output)) return(invisible(TRUE))
  if (!file.exists(side)) {
    if (strict) stop(basename(output), " has no input fingerprint, so its ",
                     "provenance is unknown. Delete it once and re-render.")
    return(invisible(TRUE))
  }
  old <- readr::read_csv(side, show_col_types = FALSE)
  new <- fingerprint(inputs)
  changed <- new$file[!new$md5 %in% old$md5[match(new$file, old$file)]]
  if (length(changed))
    stop(str_c(changed, collapse = ", "), " changed since ", basename(output),
         " was built. Delete ", basename(output), " (and anything built from ",
         "it) once, then re-render.")
  invisible(TRUE)
}

write_fingerprint <- function(output, inputs)
  readr::write_csv(fingerprint(inputs), str_c(output, ".inputs.csv"))

# Checkpoint that refuses to reload a stale cache. Compute once, save with its
# fingerprint, reload thereafter; stop if any input has changed since.
cache_guarded <- function(path, inputs, expr) {
  check_fingerprint(path, inputs)
  if (file.exists(path))
    return(if (str_detect(path, "\\.csv$"))
      readr::read_csv(path, show_col_types = FALSE) else readRDS(path))
  x <- force(expr)
  if (str_detect(path, "\\.csv$")) readr::write_csv(x, path) else saveRDS(x, path)
  write_fingerprint(path, inputs)
  x
}

# ---- (9) Topic dashboard ---------------------------------------------------------
# One self-contained HTML file: no server, no internet, opens from disk or
# GitHub Pages. The data travel as one JSON block inside the page. It embeds
# the full corpus text, so publishing the file republishes every document.
# `stance` is an optional named vector, para_uid -> label, from 03_stance.qmd.
write_dashboard <- function(path, template, paragraph_theta, codebook, trends,
                            stance = NULL, title = "Topic dashboard") {
  paras <- paragraph_theta |>
    dplyr::arrange(atom_id, para_id) |>
    dplyr::transmute(uid = para_uid, atom = atom_id, year = as.integer(Year),
                     topic = as.integer(topic), theta = round(theta_max, 3),
                     text)
  topics <- codebook |>
    dplyr::select(dplyr::any_of(c("topic", "label", "description",
                                  "proposition", "prevalence", "avepp",
                                  "frex"))) |>
    dplyr::mutate(topic = as.integer(topic)) |>
    dplyr::arrange(dplyr::desc(prevalence))
  tr <- trends |>
    dplyr::group_split(topic) |>
    purrr::map(~ list(Year = .x$Year, fit = round(.x$fit, 4),
                      lo = round(.x$lo, 4), hi = round(.x$hi, 4))) |>
    purrr::set_names(purrr::map_chr(dplyr::group_split(trends, topic),
                                    ~ as.character(.x$topic[1])))
  # Paragraphs travel as columns (compact); topics as one object per topic,
  # which is the shape the page iterates over.
  data <- list(built = format(Sys.Date()), topics = purrr::pmap(topics, list),
               paras = paras,
               trends = tr,
               stance = if (length(stance)) as.list(stance) else NULL)
  # "</" inside the JSON would close the <script> block early; "<\/" is the
  # same string to the JSON parser and harmless to the HTML parser.
  json <- jsonlite::toJSON(data, dataframe = "columns", auto_unbox = TRUE,
                           null = "null", na = "null", digits = NA) |>
    as.character() |>
    str_replace_all(stringr::fixed("</"), "<\\\\/")
  html <- readr::read_file(template) |>
    str_replace_all(stringr::fixed("{{TITLE}}"), title) |>
    str_replace(stringr::fixed("{{DATA}}"), json)
  readr::write_file(html, path)
  invisible(path)
}
