# stance.R: stance toward one claim within one topic, for one country (all
# its years: a trend) or one year (all countries: a static estimate). Step 2
# of 2; reads topics.qmd outputs. Edit `st`, then source this file.
#
# Every paragraph of the topic inside the filter is coded, one request at a
# time, by the model named in STANCE_URL / STANCE_MODEL. The coding and the
# estimates are the stance app's own functions (stance/R/stance_core.R), so a
# number here means what it means there:
#   salience               share of the paragraphs that address the claim
#   favor, neutral, oppose shares of the paragraphs that do address it
#
# Writes to unga/outputs/stance/, under NAME_topicK_BY_VALUE:
#   _labels.parquet   one label per paragraph; the run resumes from it
#   _prompt.txt       the exact prompt and model behind those labels
#   _estimates.csv    the estimates, with the claim, model, counts, and date

st <- list(
  name = "climate_finance",  # short name for this claim's files
  proposition = "Developed countries should pay for climate adaptation in developing countries.",
  topic = 7L,  # one STM topic, from topic_codebook.csv
  by = "country",  # "country": one country, all its years; "year": one year, all countries
  value = "USA",  # the country as written in the data, or a year
  model_cutoff_year = 2025L,  # the stance model has not seen speeches after this year
  # A country gives one speech a year, so a year counts toward the trend with a
  # single paragraph, and the trend needs that many speeches: the intervals are
  # clustered by speech and rest on how many there are.
  min_period_n = 1L,
  min_periods = 10L,
  df_spline = 2L,  # flexibility of the trend; years span decades, so try 3 too
  max_words = 250L,  # longer paragraphs are reported and left uncoded
  save_every = 100L)  # labels are saved after this many paragraphs

suppressPackageStartupMessages(library(tidyverse))
options(hot_topic.project = "unga")  # paths: unga/outputs
source(here::here("topics", "topics_source.R"))  # paths and the manifest guard
source(here::here("stance", "R", "stance_core.R"))  # coding and estimates

# Every paragraph of one topic within one country or one year. A paragraph
# belongs to the topic it is most about, as in the topics app's Read tab.
select_paragraphs <- function(st, theta) {
  if (!st$by %in% c("country", "year")) stop("st$by must be \"country\" or \"year\".")
  pool <- dplyr::filter(theta, topic == st$topic, .data[[st$by]] == st$value)
  if (!nrow(pool))
    stop("No paragraph of topic ", st$topic, " with ", st$by, " = ", st$value, ".")
  dplyr::bind_cols(dplyr::select(pool, para_uid, id, country, year),
                   stance_prepare(pool, "text", "year", "id", max_words = st$max_words))
}

run_stance <- function(st) {
  ep <- stance_endpoint()
  theta_in <- p_out("paragraph_theta.parquet")
  cb <- readr::read_csv(p_out("topic_codebook.csv"), show_col_types = FALSE)
  pool <- select_paragraphs(st, arrow::read_parquet(theta_in))
  if (!any(pool$keep)) stop("No paragraph in the filter is within the word bounds.")
  dir.create(p_out("stance"), showWarnings = FALSE)
  stem <- p_out("stance", str_c(st$name, "_topic", st$topic, "_", st$by, "_",
                                str_replace_all(st$value, "\\W+", "-")))
  labels_path <- str_c(stem, "_labels.parquet")
  prompt_path <- str_c(stem, "_prompt.txt")
  prompt <- stance_prompt(st$proposition, "paragraphs from speeches at the UN General Assembly")
  writeLines(c(prompt, "", str_c("MODEL ", ep$model)), prompt_path)
  # a new claim, model, or topic model refuses the saved labels
  check_inputs(labels_path, c(theta_in, prompt_path))

  done <- if (file.exists(labels_path)) arrow::read_parquet(labels_path) else
    tibble::tibble(para_uid = character(), label = character())
  todo <- dplyr::anti_join(dplyr::filter(pool, keep), done, by = "para_uid")
  if (nrow(todo)) {
    pb <- utils::txtProgressBar(max = nrow(todo), style = 3, file = stderr())
    chunks <- split(todo, ceiling(seq_len(nrow(todo)) / st$save_every))
    done <- purrr::reduce(seq_along(chunks), function(done, i) {
      d <- chunks[[i]]
      lab <- code_all(d$text, prompt, ep, on_step = function(j, n)
        utils::setTxtProgressBar(pb, (i - 1) * st$save_every + j))
      out <- dplyr::bind_rows(done, tibble::tibble(para_uid = d$para_uid, label = lab)) |>
        dplyr::filter(!is.na(label))
      arrow::write_parquet(out, labels_path)
      record_inputs(labels_path, c(theta_in, prompt_path))
      out
    }, .init = done)
    close(pb)
  }

  coded <- dplyr::inner_join(pool, done, by = "para_uid")
  if (nrow(coded) < sum(pool$keep))
    message(sum(pool$keep) - nrow(coded), " paragraphs got no label; run again to retry them.")
  if (any(!pool$keep))
    message(sum(!pool$keep), " paragraphs outside the word bounds were not coded: ",
            str_c(names(table(pool$why)), collapse = ", "), ".")
  static <- stance_static(coded)
  trends <- if (st$by == "country")
    stance_trends(coded, st$df_spline, st$min_period_n, st$min_periods) else NULL
  counts <- list(total = nrow(pool), coded = nrow(coded),
                 excluded = nrow(pool) - nrow(coded),
                 documents = dplyr::n_distinct(coded$id))
  est <- stance_record(stance_table(static, trends), st$proposition, prompt, ep, counts) |>
    dplyr::mutate(topic = st$topic, topic_label = cb$label[cb$topic == st$topic],
                  by = st$by, value = as.character(st$value),
                  after_cutoff = sum(coded$year > st$model_cutoff_year), .before = 1)
  readr::write_csv(est, str_c(stem, "_estimates.csv"))
  invisible(list(st = st, topic_label = cb$label[cb$topic == st$topic],
                 coded = coded, static = static, trends = trends, est = est))
}

# A trend for a country (salience, then the three directions), points for a
# year. The dotted line marks the model's cutoff: speeches to its right cannot
# be in the model's training data, so a pattern that holds on both sides is
# being read from the text rather than recalled.
plot_stance <- function(res) {
  sub <- ggplot2::labs(subtitle = str_c("Topic ", res$st$topic, " (", res$topic_label,
                                        "), ", res$st$by, " ", res$st$value))
  if (!stance_has_trend(res$trends)) return(list(stance_plot_static(res$static) + sub))
  cut <- ggplot2::geom_vline(xintercept = res$st$model_cutoff_year + 0.5, linetype = 3)
  obs <- stance_observed(res$coded)
  purrr::compact(list(stance_plot_salience(res$trends, obs),
                      stance_plot_direction(res$trends, obs))) |>
    purrr::map(function(p) p + cut + sub)
}

# Runs when sourced at top level; source(..., local = TRUE) only defines, so
# a Shiny server can call run_stance() and plot_stance() itself.
if (identical(environment(), globalenv())) {
  res <- run_stance(st)
  print(dplyr::select(res$static, quantity, basis, n, share, lo, hi))
  purrr::walk(attr(res$trends, "notes"), message)
  purrr::walk(plot_stance(res), print)
}
