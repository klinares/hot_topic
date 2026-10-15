# topics_source.R: the functions behind every topics project. Each project
# folder (comments/, unga/) sources this file with source("../topics_source.R").
# Quarto runs each script from its own folder, so the relative paths below
# point at that project's inputs/ and outputs/. Only function definitions live here; nothing runs when it is sourced.
#   1. Paths and model calls
#   2. Output guard (manifest.csv)
#   3. Paragraph units (comments only: split, embed, merge)
#   4. Topic model
#   5. Topic codebook
#   6. Trends over time
#   7. Tables and plots

# ---- 1. Paths and model calls ------------------------------------------------

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# Each project reads <project>/inputs and writes <project>/outputs.
p_in <- function(...) file.path("inputs", ...)
p_out <- function(...) file.path("outputs", ...)

# Every prompt has the same four parts, so each one reads the same way.
build_prompt <- function(role, task, rules, output) {
  str_c("ROLE\n", role, "\n\nTASK\n", task, "\n\nRULES\n",
        str_c("- ", rules, collapse = "\n"), "\n\nOUTPUT\n", output)
}

# The URL, key and model for one pipeline step. The steps table holds the
# NAMES of the .Renviron variables, never the values. At home (OpenRouter)
# the model comes from llm_openrouter.R.
step_config <- function(step, steps, home = FALSE) {
  cfg <- steps[steps$step == step, ]
  if (nrow(cfg) != 1) stop("No unique '", step, "' row in the steps table.")
  if (isTRUE(home))
    return(list(url = "https://openrouter.ai/api/v1",
                key = Sys.getenv("OPENROUTER_API_KEY"),
                model = unname(open_router_models[[step]])))
  url <- Sys.getenv(cfg$base_url_env)
  key <- Sys.getenv(cfg$api_key_env)
  if (!nzchar(url) || !nzchar(key))
    stop("Set ", cfg$base_url_env, " and ", cfg$api_key_env, " in .Renviron.")
  list(url = url, key = key, model = cfg$model)
}

make_chat <- function(step, system_prompt, steps, home = FALSE) {
  cfg <- step_config(step, steps, home)
  ellmer::chat_openai_compatible(
    base_url = cfg$url, model = cfg$model, system_prompt = system_prompt,
    credentials = function() cfg$key,
    params = ellmer::params(temperature = 0), echo = "none")
}

# ---- 2. Output guard (manifest.csv) ------------------------------------------
# A cached output must not outlive the inputs it was built from. manifest.csv
# records the md5 of each input when an output is written; if an input has
# changed since, the next render stops and names the file to delete.

manifest_read <- function() {
  f <- p_out("manifest.csv")
  if (!file.exists(f))
    return(tibble::tibble(output = character(), input = character(), md5 = character()))
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
  changed <- manifest_read() |>
    dplyr::filter(output == basename(!!output)) |>
    dplyr::inner_join(tibble::tibble(input = basename(inputs), md5_now = md5_of(inputs)),
                      by = "input") |>
    dplyr::filter(md5 != md5_now)
  if (nrow(changed))
    stop(str_c(changed$input, collapse = ", "), " changed since ",
         basename(output), " was built. Delete ", basename(output), " and re-render.")
  invisible(TRUE)
}

record_inputs <- function(output, inputs) {
  manifest_read() |>
    dplyr::filter(output != basename(!!output)) |>
    dplyr::bind_rows(tibble::tibble(output = basename(output),
                                    input = basename(inputs), md5 = md5_of(inputs))) |>
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
# sentence. Output is sorted by id, then block_id.
split_blocks <- function(corpus) {
  corpus |>
    dplyr::mutate(block = str_split(raw_text, "\\r?\\n+")) |>
    dplyr::select(id, Year, block) |>
    tidyr::unnest(block) |>
    dplyr::mutate(block = str_squish(block)) |>
    dplyr::filter(block != "") |>
    dplyr::group_by(id) |>
    dplyr::mutate(fragment = str_detect(block, "^[a-z]") &
                    !str_detect(dplyr::lag(block, default = "."), "[.!?:;][\"')\\]]*$"),
                  block_id = cumsum(!fragment)) |>
    dplyr::group_by(id, Year, block_id) |>
    dplyr::summarise(block = str_c(block, collapse = " "), .groups = "drop") |>
    dplyr::mutate(n_tokens = str_count(block, "\\S+")) |>
    dplyr::arrange(id, block_id)
}

# Embeddings are stored one row per distinct block text, keyed by its md5
# (hash, model, e1..eN). Requests pack up to batch_size texts each, whatever
# comment they come from, so no request exceeds the endpoint's input limit
# (37 at work). window_n requests go out together, then window_wait seconds of
# rest. The file is saved after every window, so a stopped run resumes where
# it left off, and a text is never sent twice.
embed_all <- function(blocks, path, steps, home, batch_size, window_n, window_wait) {
  ep <- step_config("embed", steps, home)
  done <- if (file.exists(path)) tibble::as_tibble(arrow::read_parquet(path)) else NULL
  if (!is.null(done) && !identical(done$model[1], ep$model))
    stop(basename(path), " was built with '", done$model[1], "'. Delete it to re-embed.")
  todo <- dplyr::distinct(tibble::tibble(hash = cli::hash_md5(blocks$block),
                                         text = blocks$block), hash, .keep_all = TRUE) |>
    dplyr::filter(!hash %in% done$hash)
  batches <- split(todo, ceiling(seq_len(nrow(todo)) / batch_size))
  windows <- split(batches, ceiling(seq_along(batches) / window_n))
  done <- purrr::reduce(seq_along(windows), function(done, w) {
    win <- windows[[w]]
    message(glue::glue("window {w} of {length(windows)}: {length(win)} requests"))
    resps <- purrr::map(win, function(b) embed_request(b$text, ep)) |>
      httr2::req_perform_parallel(on_error = "continue", max_active = 10L, progress = TRUE)
    ok <- purrr::map_lgl(resps, inherits, "httr2_response")
    if (!all(ok)) message("failed requests: ", sum(!ok), ". First error: ",
                          conditionMessage(resps[!ok][[1]]))
    new <- purrr::map2(win[ok], resps[ok], function(b, r)
      dplyr::bind_cols(tibble::tibble(hash = b$hash, model = ep$model), embed_parse(r))) |>
      purrr::list_rbind()
    done <- dplyr::bind_rows(done, new)
    if (!is.null(done) && nrow(done)) arrow::write_parquet(done, path)
    if (w < length(windows)) Sys.sleep(window_wait)
    done
  }, .init = done)
  missing <- sum(!unique(cli::hash_md5(blocks$block)) %in% done$hash)
  if (missing) stop(missing, " blocks are not embedded. Re-run the chunk; ",
                    "embedded blocks are not re-sent.")
  done
}

embed_request <- function(txt, ep) {
  httr2::request(ep$url) |>
    httr2::req_url_path_append("embeddings") |>
    httr2::req_auth_bearer_token(ep$key) |>
    httr2::req_body_json(list(model = ep$model, input = as.list(txt))) |>
    httr2::req_retry(max_tries = 3)
}

# The response lists one vector per input, tagged with its position.
embed_parse <- function(resp) {
  d <- httr2::resp_body_json(resp)$data
  m <- do.call(rbind, purrr::map(d, function(x) unlist(x$embedding)))
  m <- m[order(purrr::map_int(d, "index")), , drop = FALSE]
  colnames(m) <- str_c("e", seq_len(ncol(m)))
  tibble::as_tibble(m)
}

# One embedding row per block, in the same order as blocks.
emb_matrix <- function(blocks, emb) {
  m <- as.matrix(emb[str_detect(names(emb), "^e[0-9]+$")])
  m[match(cli::hash_md5(blocks$block), emb$hash), , drop = FALSE]
}

cosine_rows <- function(A, B) rowSums(A * B) / sqrt(rowSums(A^2) * rowSums(B^2))

# Similarity of every adjacent pair of blocks within a comment. The merge
# threshold is a quantile of these, so it means the same thing whichever
# embedding model produced the vectors.
adjacent_sims <- function(blocks, E) {
  n <- nrow(blocks)
  same <- blocks$id[-1] == blocks$id[-n]
  cosine_rows(E[-n, , drop = FALSE], E[-1, , drop = FALSE])[same]
}

# One merge: of the adjacent pairs allowed to merge, join the most similar. A
# pair is allowed when one side is short, the result stays within max_tokens,
# and the two are similar enough. The merged vector is the token-weighted mean
# of the two, which avoids re-embedding.
merge_once <- function(u, min_tokens, max_tokens, min_sim) {
  k <- length(u$n)
  if (k < 2) return(u)
  i <- seq_len(k - 1)
  sim <- cosine_rows(u$E[i, , drop = FALSE], u$E[i + 1, , drop = FALSE])
  ok <- (u$n[i] < min_tokens | u$n[i + 1] < min_tokens) &
    u$n[i] + u$n[i + 1] <= max_tokens & sim >= min_sim
  if (!any(ok)) return(u)
  j <- which(ok)[which.max(sim[ok])]
  w <- u$n[j:(j + 1)] / sum(u$n[j:(j + 1)])
  u$E[j, ] <- w[1] * u$E[j, ] + w[2] * u$E[j + 1, ]
  u$text[j] <- str_c(u$text[j], " ", u$text[j + 1])
  u$n[j] <- u$n[j] + u$n[j + 1]
  u$n_blocks[j] <- u$n_blocks[j] + u$n_blocks[j + 1]
  u$text <- u$text[-(j + 1)]; u$n <- u$n[-(j + 1)]; u$n_blocks <- u$n_blocks[-(j + 1)]
  u$E <- u$E[-(j + 1), , drop = FALSE]
  u
}

# Merge one comment's blocks until no allowed pair remains (at most blocks - 1
# merges). Units still under min_tokens are flagged keep = FALSE.
link_comment <- function(b, E, min_tokens, max_tokens, min_sim) {
  u <- list(text = b$block, n = b$n_tokens, n_blocks = rep(1L, nrow(b)), E = E)
  u <- purrr::reduce(seq_len(max(0, nrow(b) - 1)), function(u, s)
    merge_once(u, min_tokens, max_tokens, min_sim), .init = u)
  tibble::tibble(id = b$id[1], Year = b$Year[1], text = u$text, n_tokens = u$n,
                 n_blocks = u$n_blocks, keep = u$n >= min_tokens)
}

link_corpus <- function(blocks, E, min_tokens, max_tokens, min_sim) {
  split(seq_len(nrow(blocks)), blocks$id) |>
    purrr::map(function(i)
      link_comment(blocks[i, ], E[i, , drop = FALSE], min_tokens, max_tokens, min_sim)) |>
    purrr::list_rbind() |>
    dplyr::group_by(id) |>
    dplyr::mutate(para_id = dplyr::row_number(),
                  para_uid = str_c(id, "-", sprintf("%02d", para_id))) |>
    dplyr::ungroup()
}

# ---- 4. Topic model ----------------------------------------------------------

# Tokens: lowercase, letters only, no stopwords, no month or weekday names
# (they would let topics encode the year), no words in `drop`.
clean_tokens <- function(paras, drop = character()) {
  temporal <- str_to_lower(c(month.name, month.abb, "monday", "tuesday", "wednesday",
                             "thursday", "friday", "saturday", "sunday"))
  paras |>
    dplyr::select(para_uid, text) |>
    tidytext::unnest_tokens(word, text) |>
    dplyr::mutate(word = str_remove_all(word, "'")) |>
    dplyr::filter(str_detect(word, "^[a-z]{2,}$"),
                  !word %in% tidytext::get_stopwords()$word,
                  !word %in% temporal, !word %in% drop)
}

# Tokens to stm's input: a vocabulary, and per paragraph a 2-row matrix of
# (word index, count). Words in fewer than min_docfreq paragraphs are dropped.
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

# Everything stm needs, built once: documents, vocab, the paragraph metadata
# in document order (a plain data frame), the year spline as columns
# yr1, yr2, ..., and the prevalence formula.
stm_setup <- function(paragraphs, min_docfreq, spline_df, drop = character()) {
  s <- stm_input(clean_tokens(paragraphs, drop), min_docfreq)
  meta <- tibble::tibble(para_uid = names(s$documents)) |>
    dplyr::left_join(paragraphs, by = "para_uid")
  bs <- splines::ns(meta$Year, df = spline_df)
  colnames(bs) <- str_c("yr", seq_len(ncol(bs)))
  c(s, list(meta = as.data.frame(cbind(meta, as.data.frame(bs))), bs = bs,
            formula = as.formula(str_c("~ ", str_c(colnames(bs), collapse = " + ")))))
}

fit_stm <- function(s, K, documents = s$documents, vocab = s$vocab) {
  stm::stm(documents, vocab, K = K, init.type = "Spectral",
           prevalence = s$formula, data = s$meta, verbose = FALSE)
}

# Fit each K on most of the text and score it on the held-out rest.
search_k <- function(s, K_grid, seed, workers) {
  future::plan(future::multisession, workers = workers)
  on.exit(future::plan(future::sequential))
  ho <- stm::make.heldout(s$documents, s$vocab, seed = seed)
  furrr::future_map(K_grid, function(k) {
    fit <- fit_stm(s, k, ho$documents, ho$vocab)
    tibble::tibble(K = k,
                   heldout = stm::eval.heldout(fit, ho$missing)$expected.heldout,
                   dispersion = stm::checkResiduals(fit, ho$documents)$dispersion,
                   coherence = mean(stm::semanticCoherence(fit, ho$documents)),
                   exclusivity = mean(stm::exclusivity(fit)))
  }, .options = furrr::furrr_options(seed = seed)) |>
    purrr::list_rbind()
}

plot_search_k <- function(metrics) {
  metrics |>
    tidyr::pivot_longer(-K) |>
    ggplot(aes(K, value)) +
    geom_line(color = viridis(1, begin = 0.35)) + geom_point() +
    facet_wrap(~ name, scales = "free_y") + labs(y = NULL)
}

# Per paragraph: every topic share, the most likely topic and its share.
# Per topic: prevalence, FREX and probable words, paragraphs, and AvePP.
topic_tables <- function(fit, meta, keep_cols, n_words) {
  theta <- fit$theta
  colnames(theta) <- str_c("topic_", seq_len(ncol(theta)))
  paragraph_theta <- tibble::as_tibble(meta[keep_cols]) |>
    dplyr::bind_cols(tibble::as_tibble(theta)) |>
    dplyr::mutate(topic = max.col(theta, ties.method = "first"),
                  theta_max = theta[cbind(dplyr::row_number(), topic)])
  words <- stm::labelTopics(fit, n = n_words)
  topic_summary <- tibble::tibble(
    topic = seq_len(ncol(theta)),
    prevalence = colMeans(theta),
    frex = apply(words$frex, 1, str_c, collapse = ", "),
    prob = apply(words$prob, 1, str_c, collapse = ", ")) |>
    dplyr::left_join(paragraph_theta |>
                       dplyr::group_by(topic) |>
                       dplyr::summarise(n_paras = dplyr::n(), avepp = mean(theta_max)),
                     by = "topic")
  entropy_r2 <- 1 - (-sum(theta * log(theta + 1e-12))) / (nrow(theta) * log(ncol(theta)))
  list(paragraph_theta = paragraph_theta, topic_summary = topic_summary,
       entropy_r2 = entropy_r2)
}

# Match each baseline topic to one topic of another fit (Hungarian
# assignment on topic-word cosine over the shared vocabulary).
beta_matrix <- function(fit) {
  b <- exp(fit$beta$logbeta[[1]])
  colnames(b) <- fit$vocab
  b
}

match_topics <- function(b_ref, b_alt) {
  v <- intersect(colnames(b_ref), colnames(b_alt))
  a <- b_ref[, v, drop = FALSE]; b <- b_alt[, v, drop = FALSE]
  sim <- (a %*% t(b)) / outer(sqrt(rowSums(a^2)), sqrt(rowSums(b^2)))
  m <- as.integer(clue::solve_LSAP(sim, maximum = TRUE))
  tibble::tibble(topic = seq_len(nrow(sim)), matched = m,
                 cosine = sim[cbind(seq_len(nrow(sim)), m)])
}

# ---- 5. Topic codebook -------------------------------------------------------

# One call per topic, in parallel, with the larger model. Each call sees only
# that topic's words and its most typical paragraphs (`text` must be in
# paragraph_theta). Written once: an existing file is read, never redrafted,
# so hand edits survive.
draft_codebook <- function(path, inputs, tables, source_desc, steps, home, n_examples) {
  check_inputs(path, inputs)
  if (file.exists(path)) return(readr::read_csv(path, show_col_types = FALSE))
  ev <- tables$paragraph_theta |>
    dplyr::group_by(topic) |>
    dplyr::slice_max(theta_max, n = n_examples, with_ties = FALSE) |>
    dplyr::summarise(ex = str_c("- ", str_trunc(text, 400), collapse = "\n")) |>
    dplyr::right_join(tables$topic_summary, by = "topic") |>
    dplyr::arrange(topic)
  sys <- build_prompt(
    role = "You are a survey methodologist who names statistical topics so colleagues can use them.",
    task = str_c("Read one topic's words and example paragraphs from ", source_desc, ". Write a ",
                 "short label, one factual sentence on what the paragraphs discuss, and one ",
                 "proposition: a single claim, in one sentence, that a paragraph on this topic ",
                 "could agree or disagree with. Check every word against the evidence."),
    rules = c("Use only the words and paragraphs shown.",
              "Do not infer who is speaking or their intent.",
              "Do not invent statistics, dates, places, or names.",
              "The proposition states one side only: never 'X over Y' or 'X rather than Y'.",
              "If the evidence is mixed, say so plainly."),
    output = "A label of at most 4 words, a one-sentence description, and a one-sentence proposition.")
  type <- ellmer::type_object(
    label = ellmer::type_string("At most 4 words."),
    description = ellmer::type_string("One factual sentence."),
    proposition = ellmer::type_string("One claim, one sentence."))
  prompts <- str_c("Distinctive words: ", ev$frex, "\nMost probable words: ", ev$prob,
                   "\nExample paragraphs:\n", ev$ex)
  drafts <- ellmer::parallel_chat_structured(
    make_chat("codebook", sys, steps, home), as.list(prompts), type = type,
    max_active = 10L, on_error = "continue")
  codebook <- dplyr::bind_cols(tibble::tibble(topic = ev$topic),
                               dplyr::select(drafts, label, description, proposition))
  readr::write_csv(codebook, path, na = "")
  record_inputs(path, inputs)
  if (anyNA(codebook$label))
    warning(sum(is.na(codebook$label)), " topics got no label; name them by hand.")
  codebook
}

# ---- 6. Trends over time -----------------------------------------------------

# Standard errors clustered on document (comment or speech), since its
# paragraphs are correlated. Sandwich estimator written out.
cluster_vcov <- function(model, cluster) {
  X <- stats::model.matrix(model)
  u <- stats::residuals(model, type = "working") * stats::weights(model, "working")
  S <- rowsum(X * u, cluster)
  G <- nrow(S)
  bread <- summary(model)$cov.unscaled
  bread %*% crossprod(S) %*% bread * G / (G - 1)
}

# Expected share of topic k by year: a fractional logit (quasibinomial glm on
# the topic share; Papke and Wooldridge 1996), refit on each draw of theta and
# combined on the logit scale (Rubin's rules), so the interval carries the
# topic model's uncertainty and the clustering.
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
                 lo = stats::plogis(est - 1.96 * se), hi = stats::plogis(est + 1.96 * se))
}

topic_trends <- function(fit, s, n_draws, seed, cluster) {
  draws <- withr::with_seed(seed, purrr::map(seq_len(n_draws), function(i)
    do.call(rbind, stm::thetaPosterior(fit, nsims = 1, type = "Global"))))
  grid <- sort(unique(s$meta$Year))
  purrr::map(seq_len(ncol(fit$theta)), function(k)
    topic_trend(draws, k, s$bs, grid, cluster)) |>
    purrr::list_rbind()
}

# ---- 7. Tables and plots -----------------------------------------------------
# Typst will not break a captioned table across pages, so long tables print
# in blocks of `rows`. Chunks that call these need results: asis.

tbl_paged <- function(df, caption = NULL, rows = 20L, max_chars = 60L) {
  d <- df |>
    dplyr::mutate(dplyr::across(dplyr::where(is.numeric), function(x) round(x, 3)),
                  dplyr::across(dplyr::where(is.character), function(x) str_trunc(x, max_chars)))
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

# Trend panels, nine topics per page, most prevalent first. `trends` needs
# topic, Year, fit, lo, hi, label, prevalence.
plot_trends <- function(trends) {
  trends |>
    dplyr::mutate(name = forcats::fct_reorder(str_c(topic, ". ", str_trunc(label, 24)),
                                              -prevalence),
                  page = (dplyr::dense_rank(dplyr::desc(prevalence)) - 1) %/% 9) |>
    dplyr::group_split(page) |>
    purrr::walk(function(d) print(
      ggplot(d, aes(Year, fit)) +
        geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.2, fill = viridis(1, begin = 0.35)) +
        geom_line(color = viridis(1, begin = 0.35)) +
        facet_wrap(~ name, scales = "free_y", ncol = 3) +
        scale_y_continuous(labels = scales::percent) +
        labs(x = NULL, y = "estimated share")))
}
