# hot_topic

Which topics emerge in public comments over time, and how they change. Three Quarto scripts and a Shiny dashboard.

```
code/preprocess.qmd  comments -> paragraph units
code/topics.qmd      paragraph units -> STM topics, codebook, trends
code/stance.qmd      one topic -> stance trend (experimental)
app/                 dashboard over the topics outputs
```

`code/llm_source.R` holds every shared function; `code/llm_openrouter.R` is the home provider and is deleted at work.

## Run order

1. **preprocess.qmd.** Replace the corpus chunk with your read (`atom_id`, `Year`, `body_english`). Set `min_tokens` and `max_tokens`. The first run embeds every comment; later runs reuse `embeddings.rds`.
2. **topics.qmd.** Once with `run_searchK = TRUE` to choose K, then set `K`. Once with `run_sensitivity = TRUE` to check the merge settings. The first full run drafts `topic_codebook.csv`; edit it by hand, it is never redrafted while it exists.
3. **stance.qmd** (experimental). Set `topic`, and either a `proposition` or use the codebook's.
4. **app/.** `shiny::runApp("app")` from the repo root. It reads its four files straight from `outputs/`.

## How paragraph units are built

Most comments put a line break after every sentence. `preprocess.qmd`:

1. splits at line breaks and rejoins wrapped lines (a line after a line with no end punctuation that starts lowercase);
2. embeds each comment (one request per comment, `window_n` per minute);
3. within each comment, merges the most similar pair of neighboring blocks while one of them is under `min_tokens`, the result stays within `max_tokens`, and their similarity is above the `min_sim_quantile` point of all neighboring pairs;
4. drops units still under `min_tokens` and writes them to `dropped_units.csv`.

The similarity threshold is a quantile rather than a fixed cosine so it means the same thing with any embedding model. The report shows the share of words dropped, overall and by year; if it is large or uneven, loosen the settings.

## Outputs (all in outputs/)

| File | Written by | What |
|---|---|---|
| `paragraphs.csv` | preprocess | kept paragraph units |
| `dropped_units.csv` | preprocess | units too short to place, for review |
| `blocks.csv`, `embeddings.rds`, `merge_settings.rds` | preprocess | inputs to the sensitivity test |
| `paragraph_theta.csv` | topics | units with topic shares, assigned topic, theta |
| `topic_summary.csv`, `topic_trends.csv` | topics | per-topic words, prevalence, AvePP; yearly trend |
| `topic_codebook.csv` | topics | labels, descriptions, propositions (edit by hand) |
| `stm_fit.rds`, `searchK.rds`, `sensitivity*.{rds,csv}` | topics | model caches |
| `stance_labels_topicNN.csv`, `stance_trend_topicNN.csv`, `stance_prompt_topicNN.txt` | stance | labels, trend, the exact prompt |
| `manifest.csv` | all | which inputs each cache was built from |

`manifest.csv` records the md5 of every input a cache was built from. If an input changes, the next render stops and names the file to delete, so a stale model is never reloaded.

## Settings for work

Each script has a `steps` table holding the **names** of `.Renviron` variables, never keys:

```
COMPASS_EMBED_URL / COMPASS_EMBED_KEY   embeddings (preprocess)
COMPASS_LARGE_URL / COMPASS_LARGE_KEY   codebook (topics)
COMPASS_SMALL_URL / COMPASS_SMALL_KEY   stance
```

Set `use_openrouter = FALSE` and delete `llm_openrouter.R`.

## Packages

Scripts: tidyverse, here, viridis, stm, tidytext, splines, furrr, clue, httr2 (1.1 or later), ellmer (0.4 or later), knitr; quanteda only for the demo corpus. App: shiny, bslib, DT, ggplot2, viridisLite, dplyr, purrr, readr, stringr, tibble.

## Troubleshooting

| Message | Meaning |
|---|---|
| `X changed since Y was built. Delete Y` | an upstream file changed; delete Y and re-render |
| `N comments could not be embedded. First error: ...` | the provider's own message; rerun, finished comments are not re-sent |
| `Set X and Y in .Renviron` | the named variable is empty; restart R after editing .Renviron |
| `ellmer 0.4.0 or later is needed` | update ellmer (the key is passed as `credentials`) |
| `stm_fit.rds has K = a but tx$K = b` | delete `stm_fit.rds` |
| stance: `no trend fitted: too few paragraphs` | the class has under `min_class_n` paragraphs; read the era table only |
