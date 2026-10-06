# stance_source.R: what stance.qmd needs beyond the app's own functions.
# Only function definitions live here; nothing runs when it is sourced.
#   1. Paths, and the app's stance functions
#   2. Output guard (manifest.csv)
#   3. Tables for Typst
#
# The estimates themselves live in R/stance_core.R, which the app loads too,
# so the report and the app cannot drift apart.

# ---- 1. Paths ----------------------------------------------------------------

# The corpus to code goes in stance/inputs; labels and estimates go in
# stance/outputs. The app reads neither: it works on what a user uploads.
p_in <- function(f) here::here("stance", "inputs", f)
p_out <- function(f) here::here("stance", "outputs", f)
source(here::here("stance", "R", "stance_core.R"))

# ---- 2. Output guard (manifest.csv) ------------------------------------------
# A saved output must not outlive the inputs it was built from. manifest.csv
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
    stop("Missing input: ", paste(basename(miss), collapse = ", "), ".")
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
    stop(paste(changed$input, collapse = ", "), " changed since ",
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

# ---- 3. Tables for Typst -----------------------------------------------------
# Typst will not break a captioned table across pages, so long tables are
# printed in blocks of `rows`. Chunks that call these need results: asis.

tbl_paged <- function(df, caption = NULL, rows = 20L, max_chars = 60L) {
  d <- df |>
    dplyr::mutate(dplyr::across(dplyr::where(is.numeric), function(x) round(x, 3)),
                  dplyr::across(dplyr::where(is.character),
                                function(x) stringr::str_trunc(x, max_chars)))
  if (!is.null(caption)) writeLines(c("", paste0("**", caption, "**"), ""))
  split(d, (seq_len(nrow(d)) - 1L) %/% rows) |>
    purrr::walk(function(p) writeLines(c(knitr::kable(p, format = "pipe"), "")))
  invisible(df)
}

# Long text reads better as one short block per row than as a table.
tbl_records <- function(df, title_col, body_cols, caption = NULL) {
  if (!is.null(caption)) writeLines(c("", paste0("**", caption, "**"), ""))
  purrr::pwalk(df, function(...) {
    r <- list(...)
    writeLines(c(paste0("**", r[[title_col]], "**"),
                 paste0("- ", body_cols, ": ", unlist(r[body_cols])), ""))
  })
  invisible(df)
}
