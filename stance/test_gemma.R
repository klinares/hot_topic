# test_gemma.R: THROWAWAY. Runs the stance code against a real Gemma and
# writes what it found to stance/outputs/gemma_test_results.txt. Source it from
# the repo root. Delete it once the results are read.
#
# Endpoint, in this order: STANCE_URL / STANCE_MODEL if set; otherwise Gemma 4
# on OpenRouter if OPENROUTER_API_KEY is set; otherwise a local Ollama Gemma.

out_file <- here::here("stance", "outputs", "gemma_test_results.txt")
dir.create(dirname(out_file), showWarnings = FALSE)
log <- function(...) cat(..., "\n", sep = "", file = out_file, append = TRUE)
unlink(out_file)
log("started ", format(Sys.time()), " | httr2 ", as.character(packageVersion("httr2")))

if (!nzchar(Sys.getenv("STANCE_URL"))) {
  if (nzchar(Sys.getenv("OPENROUTER_API_KEY"))) {
    Sys.setenv(STANCE_URL = "https://openrouter.ai/api/v1",
               STANCE_MODEL = "google/gemma-4-31b-it",
               STANCE_KEY = Sys.getenv("OPENROUTER_API_KEY"))
  } else {
    Sys.setenv(STANCE_URL = "http://localhost:11434/v1", STANCE_MODEL = "gemma4:12b",
               STANCE_KEY = "")
  }
}
res <- tryCatch({
  source(here::here("stance", "R", "stance_core.R"))
  ep <- stance_endpoint()
  log("endpoint ", ep$url, " | model ", ep$model)
  claim <- "The United States should take an active role in the affairs of other nations."
  prompt <- stance_prompt(claim, "paragraphs from public comments")
  raw <- readr::read_csv(here::here("topics", "outputs", "paragraph_theta.csv"),
                         show_col_types = FALSE)
  paras <- dplyr::filter(stance_prepare(raw, "text", "Year", "atom_id"), keep)
  log("corpus: ", nrow(paras), " passages in bounds")

  # 1. one passage
  one <- code_one(paras$text[1], prompt, ep)
  log("1. one passage: ", one, if (is.na(one)) paste(" | error:", attr(one, "error")))

  # 2. 60 passages, then the same 60 plus 30 exact copies, 1 and 4 at a time
  x <- paras$text[1:60]
  xd <- c(x, x[1:30])
  t1 <- system.time(l1 <- code_all(x, prompt, ep, workers = 1))[["elapsed"]]
  t4 <- system.time(l4 <- code_all(xd, prompt, ep, workers = 4))[["elapsed"]]
  log("2. 60 passages one at a time: ", round(t1, 1), " s (", round(t1 / 60, 2), " s each)")
  log("   90 rows (60 unique) four at a time: ", round(t4, 1), " s (",
      round(t4 / 60, 2), " s per unique passage)")
  log("   speedup per unique passage: ", round(t1 / t4, 2), "x")
  log("   labels that differ, sequential vs parallel: ",
      sum(l1 != l4[1:60], na.rm = TRUE), " of 60")
  log("   copies got their original's label: ", identical(l4[61:90], l4[1:30]))
  log("   NA labels: sequential ", sum(is.na(l1)), ", parallel ", sum(is.na(l4)))
  log("   label counts (parallel): ",
      paste(names(table(l4[1:60])), table(l4[1:60]), sep = "=", collapse = ", "))

  # 3. 400 passages at random through the estimates, four at a time
  y <- withr::with_seed(2026, dplyr::slice_sample(paras, n = min(400, nrow(paras))))
  t3 <- system.time(y$label <- code_all(y$text, prompt, ep, workers = 4))[["elapsed"]]
  coded <- dplyr::filter(y, !is.na(label))
  log("3. ", nrow(y), " passages four at a time: ", round(t3, 1), " s; ",
      nrow(coded), " labeled")
  st <- stance_static(coded)
  log("   static: ", paste(st$quantity, sprintf("%.1f%% [%.1f, %.1f]", 100 * st$share,
                                                   100 * st$lo, 100 * st$hi),
                           collapse = " | "))
  tr <- stance_trends(coded)
  log("   trend fitted: ", stance_has_trend(tr), " | notes: ",
      paste(attr(tr, "notes"), collapse = "; "))
  png(here::here("stance", "outputs", "gemma_test_plot.png"), 1100, 700, res = 110)
  print(if (stance_has_trend(tr)) stance_plot_direction(tr, stance_observed(coded)) else
    stance_plot_static(st))
  dev.off()
  log("   examples:")
  ex <- withr::with_seed(1, dplyr::slice_sample(dplyr::group_by(coded, label), n = 2))
  purrr::pwalk(list(ex$label, ex$text), function(l, t)
    log("   [", toupper(l), "] ", substr(gsub("\\s+", " ", t), 1, 220)))
  "ok"
}, error = function(e) { log("ERROR: ", conditionMessage(e)); "error" })
log("finished ", format(Sys.time()), " | ", res)
message("Done: see stance/outputs/gemma_test_results.txt")
