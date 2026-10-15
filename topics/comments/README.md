# topics/comments

Topics in public comments, and a dashboard to explore them. The scripts, their reports and the app share one folder, so the app always reads the latest render and nothing is copied.

```
preprocess.qmd   comments -> paragraph units (embeddings + merge)
topics.qmd       paragraph units -> STM topics, codebook, trends
_quarto.yml      renders both PDFs into reports/
app.R, R/        the dashboard
inputs/          your corpus (not tracked by git)
outputs/         everything the scripts write; the app reads four CSVs here
reports/         preprocess.pdf and topics.pdf, linked from the app
logo/            office_logo.png, shown under the classification banner
```

## Running it

1. Put the corpus in `inputs/` and read it in the corpus chunk of `preprocess.qmd`. Columns: `id` (comment id), `Year` (integer), `raw_text` (text).
2. Render `preprocess.qmd`. Embedding requests carry up to `batch_size` (32) blocks each, under the work endpoint's limit of 37; each distinct text is embedded once, and a stopped run resumes.
3. Render `topics.qmd`: once with `run_searchK = TRUE` to choose `K`, then normally. Edit `topic_codebook.csv` by hand; it is never redrafted while it exists.
4. `shiny::runApp("topics/comments")` from the repo root.

Re-render both scripts before redeploying. The app checks that the codebook and the topic shares cover the same topics, but it cannot tell whether they came from the latest render.

## The app

| Tab | What it shows |
|---|---|
| **Start here** | What topic modeling is and why it is used, how the results were made, how to read the numbers, a summary of the data, and links to the PDFs in `reports/`. |
| **Topics** | One topic's words, label, description and draft claim, its share over time with a 95 percent interval, exact yearly counts, and every topic side by side. |
| **Read** | The paragraphs behind a topic, filtered by topic, years, share or a word; click one to open the whole comment. CSV downloads. |

Settings sit in one block at the top of `app.R`: the classification marking, the logo file name in `logo/`, an office name, what the text is, what one document is called, and the stance app's URL.

## Deploying on Posit Connect

Publish `app.R`, `R/`, `reports/`, `logo/`, and from `outputs/` only `paragraph_theta.csv`, `topic_codebook.csv`, `topic_summary.csv`, `topic_trends.csv`. Uncheck the `.qmd` files, `inputs/`, `stm_fit.rds`, `embeddings.parquet`, and the other outputs; the app reads none of them.

`paragraph_theta.csv` holds the text of every paragraph. Publish or commit it only where that text may be stored.

## Packages

Scripts: tidyverse, here, viridis, stm, tidytext, splines, furrr, clue, withr, httr2, cli, ellmer (0.4 or later), knitr, glue, arrow; quanteda for the demo corpus.
App: shiny, bslib, DT, ggplot2, viridisLite, dplyr, readr, stringr, purrr, glue.
