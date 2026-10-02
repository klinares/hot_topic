# stance.R: stance toward one claim, within one topic, for one country (all
# its years -> a trend) or one year (all countries -> a single estimate).
# Step 2 of 2; reads topics.qmd outputs. Edit `st`, then source this file.
#
# Selection is the n paragraphs with the highest share of the topic, so
# results describe the paragraphs most central to the topic, not every
# paragraph that touches it.
#
# Writes two files to outputs/stance/topic_NN/:
#   NAME_BY_VALUE.parquet    one row per coded paragraph (enough to redraw)
#   NAME_BY_VALUE_meta.rds   settings, prompt, model, date, and summaries

st <- list(
  name = "climate_finance",  # short name for this claim's files
  proposition = "Developed countries should pay for climate adaptation in developing countries.",
  topic = 7L,  # one STM topic, from topic_codebook.csv
  by = "country",  # "country": one country, all its years; "year": one year, all countries
  value = "USA",  # the country as written in the data, or a year
  n = 300L,  # paragraphs to code: the top n by the topic's share
  model_cutoff_year = 2025L,  # the stance model has not seen speeches after this year
  window_n = 300L,  # calls per quota window
  window_wait = 0L,  # seconds between windows; 4 * 3600 for 300 calls per 4 hours
  rpm = 300L,  # requests a minute
  max_active = 10L,  # simultaneous connections
  df_spline = 2L,  # flexibility of the trend
  min_class_n = 5L,  # paragraphs needed on each side for a trend
  use_openrouter = TRUE,  # FALSE at work
  steps = tibble::tribble(
    ~step, ~base_url_env, ~api_key_env, ~model,
    "stance", "COMPASS_SMALL_URL", "COMPASS_SMALL_KEY", "SMALL-MODEL"))

suppressPackageStartupMessages(library(tidyverse))
source(here::here("unga", "code", "unga_source.R"))
if (isTRUE(st$use_openrouter)) {
  source(here::here("unga", "code", "unga_openrouter.R"))
  st$steps$model <- open_router_models[st$steps$step]
}

stance_prompt <- function(proposition) build_prompt(
  role = "You are a survey methodologist coding stance in speeches at the UN General Assembly.",
  task = str_c("Decide the speaker's position toward this proposition: \"", proposition,
               "\". First decide whether the text addresses the proposition at all; ",
               "if not, the label is irrelevant. Otherwise decide favor, oppose, or neutral."),
  rules = c("Stance is measured only toward the proposition.",
            "Stance is not tone: a harsh passage can favor the proposition.",
            "Judge only the text shown; use no outside knowledge of the speaker or the speech.",
            "If the text is ambiguous, choose neutral rather than guessing."),
  output = "One label: favor, neutral, oppose, or irrelevant.")

# The top n paragraphs of one topic within one country or one year.
select_paragraphs <- function(st, theta) {
  col <- str_c("topic_", st$topic)
  if (!col %in% names(theta)) stop("No topic ", st$topic, " in paragraph_theta.parquet.")
  if (!st$by %in% c("country", "year")) stop("st$by must be \"country\" or \"year\".")
  pool <- dplyr::filter(theta, .data[[st$by]] == st$value)
  if (nrow(pool) == 0) stop("No paragraphs with ", st$by, " = ", st$value, ".")
  if (nrow(pool) < st$n)
    message(st$by, " = ", st$value, " has only ", nrow(pool), " paragraphs; coding all of them.")
  pool |>
    dplyr::mutate(theta = .data[[col]]) |>
    dplyr::slice_max(theta, n = st$n, with_ties = FALSE) |>
    dplyr::select(para_uid, id, para_id, year, country, theta, text) |>
    structure(n_pool = nrow(pool))
}

# One call per paragraph, in windows. Labels are saved after every window, so
# an interrupted run resumes and re-sends nothing already coded.
code_paragraphs <- function(sel, st, sys, path) {
  done <- if (file.exists(path))
    dplyr::select(arrow::read_parquet(path), para_uid, label) else
    tibble::tibble(para_uid = character(), label = character())
  todo <- dplyr::anti_join(sel, done, by = "para_uid")
  windows <- split(todo, ceiling(seq_len(nrow(todo)) / st$window_n))
  type <- ellmer::type_object(label = ellmer::type_enum(
    c("favor", "neutral", "oppose", "irrelevant"), "The single best label."))
  purrr::reduce(seq_along(windows), function(done, i) {
    if (i > 1 && st$window_wait > 0)
      purrr::walk(seq_len(st$window_wait), function(s) Sys.sleep(1),
                  .progress = glue::glue("resting {st$window_wait}s"))
    d <- windows[[i]]
    message(glue::glue("window {i} of {length(windows)}: {nrow(d)} calls"))
    res <- ask_many(make_chat("stance", sys, st$steps, st$use_openrouter),
                    str_c("Text: ", d$text), type, rpm = st$rpm,
                    max_active = st$max_active)
    if (all(is.na(res$label)))
      stop("Every call in the window failed. First error: ",
           conditionMessage(purrr::compact(res$.error)[[1]]))
    out <- dplyr::bind_rows(done, tibble::tibble(para_uid = d$para_uid,
                                                 label = as.character(res$label))) |>
      dplyr::filter(!is.na(label))
    arrow::write_parquet(dplyr::inner_join(sel, out, by = "para_uid"), path)
    out
  }, .init = done) |>
    dplyr::inner_join(x = sel, by = "para_uid")
}

# Shares for the whole selection; a trend in year when one country is followed
# over time. All intervals are 95 percent, clustered by speech.
summarise_stance <- function(coded, st) {
  rel <- dplyr::filter(coded, label != "irrelevant")
  sided <- dplyr::filter(rel, label != "neutral")
  shares <- dplyr::bind_rows(
    dplyr::mutate(share_ci(coded$label != "irrelevant", coded$id),
                  measure = "addressing the claim, of all coded"),
    dplyr::mutate(share_ci(rel$label == "favor", rel$id), measure = "favor, of those addressing it"),
    dplyr::mutate(share_ci(rel$label == "oppose", rel$id), measure = "oppose, of those addressing it"),
    dplyr::mutate(share_ci(sided$label == "favor", sided$id), measure = "favor, of those taking a side")) |>
    dplyr::relocate(measure)
  trend <- if (st$by == "country")
    tryCatch(trend_curve(as.integer(rel$label == "favor"), rel$year, rel$id,
                         st$df_spline, st$min_class_n),
             error = function(e) conditionMessage(e))
  list(labels = dplyr::count(coded, label),
       shares = shares,
       trend = if (is.data.frame(trend)) trend,
       trend_note = if (is.character(trend)) str_c("no trend fitted: ", trend),
       coverage = dplyr::count(coded, year, country, name = "paragraphs"))
}

run_stance <- function(st) {
  theta_path <- p_out("paragraph_theta.parquet")
  theta <- arrow::read_parquet(theta_path)
  codebook <- readr::read_csv(p_out("topic_codebook.csv"), show_col_types = FALSE)
  dir <- p_out("stance", sprintf("topic_%02d", st$topic))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  stem <- file.path(dir, str_c(st$name, "_", st$by, "_", str_replace_all(st$value, "\\W+", "-")))
  labels_path <- str_c(stem, ".parquet")
  meta_path <- str_c(stem, "_meta.rds")
  sys <- stance_prompt(st$proposition)
  md5 <- md5_of(theta_path)

  # saved labels are reused only if the claim, model, and topics are unchanged
  if (file.exists(meta_path)) {
    old <- readRDS(meta_path)
    if (!identical(old$prompt, sys) || !identical(old$model, unname(st$steps$model)) ||
        !identical(old$theta_md5, md5))
      stop("The claim, model, or topic model changed since ", basename(labels_path),
           " was coded. Delete it and its _meta.rds, or use a new st$name.")
  }

  sel <- select_paragraphs(st, theta)
  meta <- list(name = st$name, proposition = st$proposition, topic = st$topic,
               topic_label = codebook$label[codebook$topic == st$topic],
               by = st$by, value = st$value, n_requested = st$n,
               n_in_filter = attr(sel, "n_pool"), n_selected = nrow(sel),
               theta_range = range(sel$theta), model = unname(st$steps$model),
               prompt = sys, theta_md5 = md5, model_cutoff_year = st$model_cutoff_year,
               n_after_cutoff = sum(sel$year > st$model_cutoff_year),
               years = sort(unique(sel$year)), created = Sys.time(),
               sample_note = str_c("The ", nrow(sel), " paragraphs with the highest share of topic ",
                                   st$topic, ", not a random sample: results describe the ",
                                   "paragraphs most central to the topic."))
  saveRDS(meta, meta_path)

  coded <- code_paragraphs(sel, st, sys, labels_path)
  if (nrow(coded) < nrow(sel))
    message(nrow(sel) - nrow(coded), " calls failed; run again to retry them.")
  meta <- c(meta, list(n_coded = nrow(coded)), summarise_stance(coded, st))
  saveRDS(meta, meta_path)
  invisible(list(labels = coded, meta = meta))
}

# Trend for a country, bars for a year.
plot_stance <- function(res) {
  m <- res$meta
  title <- str_c("Topic ", m$topic, " (", m$topic_label, "), ", m$by, " ", m$value)
  if (!is.null(m$trend)) {
    rel <- dplyr::filter(res$labels, label != "irrelevant")
    ggplot(m$trend, aes(year, fit)) +
      geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.2, fill = "#3b528b") +
      geom_line(linewidth = 0.9, color = "#3b528b") +
      geom_rug(data = rel, aes(year), inherit.aes = FALSE, alpha = 0.4) +
      geom_vline(xintercept = m$model_cutoff_year + 0.5, linetype = 3) +
      scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
      labs(x = NULL, y = "favor, of paragraphs addressing the claim", title = title,
           caption = "95% intervals clustered by speech. Ticks: coded paragraphs. Dotted: model cutoff.")
  } else {
    ggplot(m$shares, aes(share, measure)) +
      geom_pointrange(aes(xmin = lo, xmax = hi), color = "#3b528b") +
      scale_x_continuous(labels = scales::percent, limits = c(0, 1)) +
      labs(x = NULL, y = NULL, title = title, caption = m$trend_note %||% "95% intervals clustered by speech.")
  }
}

# Runs when sourced at top level; source(..., local = TRUE) only defines.
if (identical(environment(), globalenv())) {
  res <- run_stance(st)
  print(res$meta$shares)
  if (!is.null(res$meta$trend_note)) message(res$meta$trend_note)
  print(plot_stance(res))
}
