# Topics

A Shiny dashboard for the results of a structural topic model: what a body of text is about, how attention to each subject changed over time, and the paragraphs behind each topic. The app only reads saved results; it never refits a model or calls a language model, so it is quick to start and safe to leave running.

```
app.R          deployment settings and the page layout
R/             the tabs and the data loader
outputs/       the four CSVs the app reads
www/           files served as-is: the method report PDFs and the office logo
```

## The tabs

| Tab | What it shows |
|------------------------------------|------------------------------------|
| **Start here** | What topic modeling is, why it is used, how the results were made, how to use the tool, how to read the numbers, and a summary of the data. Links to the method reports. |
| **Topics** | One topic at a time: its words, label, description and draft claim, its estimated share over time with a 95 percent interval, the exact count of paragraphs assigned each year, and every topic side by side. The codebook downloads as a CSV. |
| **Read** | The paragraphs behind a topic, filtered by topic, years, topic share, or a word. Clicking one opens the whole document it came from. Paragraphs or whole documents download as CSV. |

## Settings

All in the block at the top of `app.R`:

| Option | What |
|------------------------------------|------------------------------------|
| `drsvyr.classification` | the banner on every page |
| `hot_topic.logo` | the logo's file name in `www/`. Until that file exists, a dashed box marks its place |
| `hot_topic.office` | an office name beside the logo; leave empty for none |
| `hot_topic.source` | what the text is, in a phrase ("public comments on the 2026 rule") |
| `hot_topic.unit` | what one document is called, singular and plural: `c("comment", "comments")`, `c("speech", "speeches")` |
| `hot_topic.stance_app` | the stance app's URL, which adds a link to it; empty for none |

Set the environment variable `HOT_TOPIC_DATA` to read the CSVs from somewhere other than `outputs/`.

## Updating the results

The analysis lives in its own repository (`topics.qmd` and `topics_source.R`). After rendering it:

1. Copy these four files from its `outputs/` into this repository's `outputs/`:
   `paragraph_theta.csv`, `topic_codebook.csv`, `topic_summary.csv`, `topic_trends.csv`.
2. Copy the rendered `topics.pdf` (and `preprocess.pdf`, if the text was divided into paragraphs) into `www/`. Each PDF found there gets a link on Start here; a missing one is left off.
3. Redeploy.

The app checks the files when it starts and stops with a message naming what is missing, or saying that the codebook and the topic shares disagree (a codebook from one fit with the shares from another). Re-render the analysis if so.

`paragraph_theta.csv` holds the text of every paragraph. Commit it only if that text may be stored in this repository.

## Deploying on Posit Connect

Publish `app.R`, `R/`, `outputs/`, and `www/`. The app reads nothing else and writes nothing.

## Packages

shiny, bslib, DT, ggplot2, viridisLite, dplyr, readr, stringr, purrr, glue.
