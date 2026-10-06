# topics_source.R: shared functions for preprocess.qmd and topics.qmd.
# Only function definitions live here; nothing runs when it is sourced.
#   1. Setup and model calls
#   2. Output guard (manifest.csv)
#   3. Paragraph units
#   4. Topic model helpers
#   5. Topic trends
#   6. Tables for Typst
#
# Stance lives in its own project (../stance) with its own functions; the two
# share nothing but the cluster-robust variance below, which is eight lines and
# not worth a dependency between two apps that deploy separately.

# ---- 1. Setup and model calls ------------------------------------------------

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x
# The raw corpus goes in topics/inputs; everything the scripts write goes in
# topics/outputs, which is also where the app reads it.
p_in <- function(f) here::here("topics", "inputs", f)
p_out <- function(f) here::here("topics", "outputs", f)

# Every prompt has the same four parts, so each one reads the same way.
build_prompt <- function(role, task, rules, output) {
  str_c("ROLE\n", role, "\n\nTASK\n", task, "\n\nRULES\n",
        str_c("- ", rules, collapse = "\n"), "\n\nOUTPUT\n", output)
}

# One chat object per pipeline step. The steps table holds the NAMES of the
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

# Many prompts through one chat, in parallel, under the provider's per-minute
# limit. Returns a data frame with one row per prompt; a failed call is NA.
ask_many <- function(chat, prompts, type, rpm = 300L, max_active = 10L) {
  ellmer::parallel_chat_structured(chat, as.list(prompts), type = type,
                                   rpm = rpm, max_active = max_active,
                                   on_error = "continue")
}

# ---- 2. Output guard (manifest.csv) ------------------------------------------
# A cached output must not outlive the inputs it was built from. manifest.csv
# records the md5 of each input when an output is written; if an input has
# changed since, the next render stops and names the file to delete.

manifest_read <- function() {
  f <- p_out("manifest.csv")
  if (!file.exists(f)) return(tibble::tibble(output = character(),
                                             input = character(),
                                             md5 = character()))
  readr::read_csv(f, show_col_types = FALSE, col_types = "ccc")
}

md5_of <- function(inputs) {
  miss <- inputs[!file.exists(inputs)]
  if (length(miss))
    stop("Missing input: ", str_c(basename(miss), collapse = ", "),
         ". Render the earlier script first.")
  unname(tools::md5sum(inputs))
}

check_inputs <- function(output, inputs) {
  if (!file.exists(output)) return(invisible(TRUE))
  old <- dplyr::filter(manifest_read(), output == basename(!!output))
  if (nrow(old) == 0) return(invisible(TRUE))
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
# Tables are cached as parquet; a model object (the STM fit) as .rds.
cached <- function(path, inputs, expr) {
  check_inputs(path, inputs)
  rds <- str_detect(path, "\\.rds$")
  if (file.exists(path))
    return(if (rds) readRDS(path) else tibble::as_tibble(arrow::read_parquet(path)))
  x <- force(expr)
  if (rds) saveRDS(x, path) else arrow::write_parquet(x, path)
  record_inputs(path, inputs)
  x
}

# ---- 3. Paragraph units ------------------------------------------------------

# Split each comment at line breaks, then rejoin hard-wrapped fragments: a line
# that follows a line without end punctuation and starts lowercase is the same
# sentence. A wrap before a capital ("I", a name) is left for the merge step.
split_blocks <- function(corpus) {
  raw <- corpus |>
    dplyr::mutate(block = str_split(body_english, "\\r?\\n+")) |>
    dplyr::select(atom_id, Year, block) |>
    tidyr::unnest(block) |>
    dplyr::mutate(block = str_squish(block)) |>
    dplyr::filter(block != "")
  out <- raw |>
    dplyr::group_by(atom_id) |>
    dplyr::mutate(fragment = str_detect(block, "^[a-z]") &
                    !str_detect(dplyr::lag(block, default = "."),
                                "[.!?:;][\"')\\]]*$"),
                  block_id = cumsum(!fragment)) |>
    dplyr::group_by(atom_id, Year, block_id) |>
    dplyr::summarise(block = str_c(block, collapse = " "), .groups = "drop") |>
    dplyr::mutate(n_tokens = str_count(block, "\\S+"))
  attr(out, "lines_in") <- nrow(raw)
  out
}

# Embeddings go through httr2 because ellmer has no embedding function. One
# request per comment; window_n requests in parallel, then window_wait seconds
# of rest, so no minute sees more than window_n calls. Saved after each
# window, so a stopped run resumes where it left off.
embed_endpoint <- function(steps, home = FALSE) {
  cfg <- steps[steps$step == "embed", ]
  if (nrow(cfg) != 1) stop("No unique 'embed' row in the steps table.")
  if (isTRUE(home)) return(embed_endpoint_home(cfg$model))
  url <- Sys.getenv(cfg$base_url_env)
  key <- Sys.getenv(cfg$api_key_env)
  if (!nzchar(url) || !nzchar(key))
    stop("Set ", cfg$base_url_env, " and ", cfg$api_key_env, " in .Renviron.")
  list(url = url, key = key, model = unname(cfg$model))
}

embed_request <- function(txt, ep) {
  httr2::request(ep$url) |>
    httr2::req_url_path_append("embeddings") |>
    httr2::req_auth_bearer_token(ep$key) |>
    httr2::req_body_json(list(model = ep$model, input = as.list(txt))) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_error(body = function(resp)
      if (httr2::resp_has_body(resp)) httr2::resp_body_string(resp))
}

embed_parse <- function(resp) {
  d <- httr2::resp_body_json(resp)$data
  d <- d[order(purrr::map_int(d, "index"))]
  do.call(rbind, purrr::map(d, function(x) unlist(x$embedding)))
}

# Embeddings on disk: one row per block (atom_id, block, model, e1..eN). In
# memory: model, and a list of one matrix per comment, rows in block order.
emb_write <- function(cache, path) {
  if (!length(cache$vec)) return(invisible())
  purrr::imap(cache$vec, function(m, id) {
    colnames(m) <- str_c("e", seq_len(ncol(m)))
    dplyr::bind_cols(tibble::tibble(atom_id = id, block = seq_len(nrow(m))),
                     tibble::as_tibble(m))
  }) |>
    purrr::list_rbind() |>
    dplyr::mutate(model = cache$model, .before = 1) |>
    arrow::write_parquet(path)
}

emb_read <- function(path) {
  d <- dplyr::arrange(tibble::as_tibble(arrow::read_parquet(path)), atom_id, block)
  m <- unname(as.matrix(d[str_detect(names(d), "^e[0-9]+$")]))
  list(model = d$model[1], errors = character(),
       vec = purrr::map(split(seq_len(nrow(d)), d$atom_id),
                        function(i) m[i, , drop = FALSE]))
}

embed_all <- function(blocks, path, steps, home, window_n, window_wait) {
  ep <- embed_endpoint(steps, home)
  model <- unname(steps$model[steps$step == "embed"])
  cache <- if (file.exists(path)) emb_read(path) else
    list(model = model, vec = list(), errors = character())
  if (!identical(cache$model, model))
    stop("embeddings.parquet was built with '", cache$model, "'. Delete it to ",
         "re-embed with the configured model.")
  # a cached matrix is reused only if it still has one row per block
  n_blk <- table(blocks$atom_id)
  stale <- purrr::keep(names(cache$vec), function(id)
    id %in% names(n_blk) && nrow(cache$vec[[id]]) != n_blk[[id]])
  cache$vec[stale] <- NULL
  todo <- setdiff(unique(blocks$atom_id), names(cache$vec))
  windows <- split(todo, ceiling(seq_along(todo) / window_n))
  cache <- purrr::reduce(seq_along(windows), function(cache, w) {
    ids <- windows[[w]]
    message(glue::glue("window {w} of {length(windows)}: {length(ids)} requests"))
    resps <- purrr::map(ids, function(id)
      embed_request(blocks$block[blocks$atom_id == id], ep)) |>
      httr2::req_perform_parallel(on_error = "continue", max_active = window_n,
                                  progress = TRUE)
    res <- purrr::map(resps, function(r)
      if (inherits(r, "httr2_response"))
        tryCatch(embed_parse(r), error = conditionMessage)
      else conditionMessage(r)) |>
      purrr::set_names(ids)
    ok <- purrr::map_lgl(res, is.matrix)
    cache$vec <- c(cache$vec, res[ok])
    cache$errors <- c(cache$errors[setdiff(names(cache$errors), ids)],
                      unlist(res[!ok]))
    emb_write(cache, path)
    if (w < length(windows))
      purrr::walk(seq_len(window_wait), function(s) Sys.sleep(1),
                  .progress = glue::glue("resting {window_wait}s"))
    cache
  }, .init = cache)
  missing <- setdiff(unique(blocks$atom_id), names(cache$vec))
  if (length(missing))
    stop(length(missing), " comments could not be embedded. First error: ",
         cache$errors[[missing[1]]] %||% "unknown",
         ". Re-run the chunk; embedded comments are not re-sent.")
  cache
}

cosine <- function(a, b) sum(a * b) / sqrt(sum(a^2) * sum(b^2))

# Similarity of every adjacent pair of blocks in the corpus. Used to set the
# merge threshold as a quantile, so it means the same thing whichever
# embedding model produced the vectors (E5 cosines run much higher than
# others, so a fixed number would not travel between models).
adjacent_sims <- function(blocks, vec) {
  blocks |>
    dplyr::group_split(atom_id) |>
    purrr::map(function(b) {
      E <- vec[[b$atom_id[1]]]
      if (nrow(E) < 2) return(numeric())
      purrr::map_dbl(seq_len(nrow(E) - 1), function(i) cosine(E[i, ], E[i + 1, ]))
    }) |>
    unlist()
}

# One merge: of the adjacent pairs that are allowed to merge, join the most
# similar. A pair is allowed when at least one side is short, the result
# stays within max_tokens, and the two are similar enough. The merged vector
# is the token-weighted mean of the two, which avoids re-embedding.
merge_once <- function(u, min_tokens, max_tokens, min_sim) {
  k <- length(u$n)
  if (k < 2) return(u)
  i <- seq_len(k - 1)
  sim <- purrr::map_dbl(i, function(j) cosine(u$E[j, ], u$E[j + 1, ]))
  ok <- (u$n[i] < min_tokens | u$n[i + 1] < min_tokens) &
    u$n[i] + u$n[i + 1] <= max_tokens & sim >= min_sim
  if (!any(ok)) return(u)
  j <- which(ok)[which.max(sim[ok])]
  w <- u$n[j:(j + 1)] / sum(u$n[j:(j + 1)])
  u$E[j, ] <- w[1] * u$E[j, ] + w[2] * u$E[j + 1, ]
  u$text[j] <- str_c(u$text[j], " ", u$text[j + 1])
  u$n[j] <- u$n[j] + u$n[j + 1]
  u$n_blocks[j] <- u$n_blocks[j] + u$n_blocks[j + 1]
  u$text <- u$text[-(j + 1)]; u$n <- u$n[-(j + 1)]
  u$n_blocks <- u$n_blocks[-(j + 1)]
  u$E <- u$E[-(j + 1), , drop = FALSE]
  u
}

# Merge one comment's blocks until no allowed pair remains. Each step removes
# one block, so at most (blocks - 1) steps; extra steps change nothing. Units
# still under min_tokens are kept in the output but flagged keep = FALSE.
# Each unit carries its vector (vec), kept for the sensitivity refit.
link_comment <- function(b, E, min_tokens, max_tokens, min_sim) {
  u <- list(text = b$block, n = b$n_tokens, n_blocks = rep(1L, nrow(b)), E = E)
  u <- purrr::reduce(seq_len(max(0, nrow(b) - 1)), function(u, s)
    merge_once(u, min_tokens, max_tokens, min_sim), .init = u)
  tibble::tibble(atom_id = b$atom_id[1], Year = b$Year[1], text = u$text,
                 n_tokens = u$n, n_blocks = u$n_blocks,
                 keep = u$n >= min_tokens,
                 vec = purrr::map(seq_len(nrow(u$E)), function(i) u$E[i, ]))
}

link_corpus <- function(blocks, vec, min_tokens, max_tokens, min_sim) {
  blocks |>
    dplyr::group_split(atom_id) |>
    purrr::map(function(b)
      link_comment(b, vec[[b$atom_id[1]]], min_tokens, max_tokens, min_sim)) |>
    purrr::list_rbind() |>
    dplyr::group_by(atom_id) |>
    dplyr::mutate(para_id = dplyr::row_number(),
                  para_uid = str_c(atom_id, "-", sprintf("%02d", para_id))) |>
    dplyr::ungroup()
}

# ---- 4. Topic model helpers --------------------------------------------------

# Tokens for the topic model: lowercase, letters only, no stopwords, and no
# month or weekday names, which would let topics encode the year directly.
clean_tokens <- function(paras) {
  temporal <- str_to_lower(c(month.name, month.abb, "monday", "tuesday",
                             "wednesday", "thursday", "friday", "saturday",
                             "sunday"))
  paras |>
    dplyr::select(para_uid, text) |>
    tidytext::unnest_tokens(word, text) |>
    dplyr::mutate(word = str_remove_all(word, "'")) |>
    dplyr::filter(str_detect(word, "^[a-z]{2,}$"),
                  !word %in% tidytext::get_stopwords()$word,
                  !word %in% temporal)
}

# Tokens to stm's input format: a vocabulary, and per paragraph a 2-row
# integer matrix of (word index, count). Words in fewer than min_docfreq
# paragraphs are dropped.
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

# Topic-word probabilities as a matrix with the vocabulary as column names.
beta_matrix <- function(fit) {
  b <- exp(fit$beta$logbeta[[1]])
  colnames(b) <- fit$vocab
  b
}

# Match each baseline topic to one topic of another fit (Hungarian
# assignment on topic-word cosine over the shared vocabulary).
match_topics <- function(b_ref, b_alt) {
  v <- intersect(colnames(b_ref), colnames(b_alt))
  a <- b_ref[, v, drop = FALSE]; b <- b_alt[, v, drop = FALSE]
  sim <- (a %*% t(b)) / outer(sqrt(rowSums(a^2)), sqrt(rowSums(b^2)))
  m <- clue::solve_LSAP(sim, maximum = TRUE)
  tibble::tibble(topic = seq_len(nrow(sim)), matched = as.integer(m),
                 cosine = sim[cbind(seq_len(nrow(sim)), as.integer(m))],
                 shared_vocab = length(v))
}

# ---- 5. Trends over time ---------------------------------------------------------

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

# Expected share of topic k by year. A fractional logit (quasibinomial glm on
# the topic share; Papke and Wooldridge 1996) keeps every prediction between
# 0 and 1, unlike the linear model in stm::estimateEffect, which can predict
# negative shares. It is refit on each draw of theta from the fitted STM and
# the draws are combined on the logit scale (mean, plus within- and
# between-draw variance), so the interval carries the topic model's own
# uncertainty as well as clustering by comment.
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
  tibble::tibble(Year = grid, topic = k, fit = stats::plogis(est),
                 lo = stats::plogis(est - 1.96 * se),
                 hi = stats::plogis(est + 1.96 * se))
}

# ---- 6. Tables for Typst ---------------------------------------------------------
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

# Long text reads better as one short block per row than as a table.
tbl_records <- function(df, title_col, body_cols, caption = NULL) {
  if (!is.null(caption)) writeLines(c("", str_c("**", caption, "**"), ""))
  purrr::pwalk(df, function(...) {
    r <- list(...)
    writeLines(c(str_c("**", r[[title_col]], "**"),
                 str_c("- ", body_cols, ": ", unlist(r[body_cols])), ""))
  })
  invisible(df)
}
