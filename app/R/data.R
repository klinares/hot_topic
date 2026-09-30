# data.R: the app reads the files topics.qmd wrote and never refits anything.

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

check_cols <- function(df, cols, file) {
  miss <- setdiff(cols, names(df))
  if (length(miss))
    stop(file, " is missing column(s): ", paste(miss, collapse = ", "), ".")
  invisible(TRUE)
}

load_outputs <- function(dir) {
  need <- c("paragraph_theta.csv", "topic_codebook.csv", "topic_summary.csv",
            "topic_trends.csv")
  miss <- need[!file.exists(file.path(dir, need))]
  if (length(miss))
    stop("Not found in ", normalizePath(dir, mustWork = FALSE), ": ",
         paste(miss, collapse = ", "), ". Render topics.qmd first, or point HOT_TOPIC_DATA at them.")
  rd <- function(f) readr::read_csv(file.path(dir, f), show_col_types = FALSE,
                                    progress = FALSE)
  paras <- rd(need[1]); cb <- rd(need[2]); sm <- rd(need[3]); tr <- rd(need[4])
  check_cols(paras, c("para_uid", "atom_id", "para_id", "Year", "text",
                      "topic", "theta_max"), need[1])
  check_cols(cb, c("topic", "label", "description"), need[2])
  check_cols(sm, c("topic", "prevalence", "frex", "avepp"), need[3])
  check_cols(tr, c("topic", "Year", "fit", "lo", "hi"), need[4])
  if (!all(paste0("topic_", cb$topic) %in% names(paras)))
    stop(need[1], " lacks the topic_k proportion columns for every codebook ",
         "topic; the codebook and the fit are out of step. Re-render ",
         "topics.qmd.")
  if (!"proposition" %in% names(cb)) cb$proposition <- NA_character_
  topics <- cb |>
    dplyr::select(topic, label, description, proposition) |>
    dplyr::left_join(dplyr::select(sm, topic, prevalence, frex, avepp),
                     by = "topic") |>
    dplyr::left_join(dplyr::count(paras, topic, name = "n_paras"), by = "topic") |>
    dplyr::mutate(n_paras = dplyr::coalesce(n_paras, 0L)) |>
    dplyr::arrange(dplyr::desc(prevalence))
  paras <- paras |>
    dplyr::left_join(dplyr::select(topics, topic, label), by = "topic") |>
    dplyr::arrange(atom_id, para_id)
  list(paras = paras, topics = topics, trends = tr, years = range(paras$Year))
}

topic_choices <- function(topics)
  stats::setNames(topics$topic, paste0(topics$topic, ". ", topics$label))

