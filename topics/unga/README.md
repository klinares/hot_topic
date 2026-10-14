# topics/unga

What the UN General Assembly talks about in its General Debate, 2000 to 2026, and how attention to each subject moved over time. One Quarto script, `topics.qmd`, fits a structural topic model to the speeches' paragraphs and renders a descriptive report with room for your findings.

```         
topics/unga/inputs/unga_paragraphs.csv   the paragraphs, one row each (not tracked by git)
topics/unga/topics.qmd                   the analysis and its report
topics/unga/outputs/                     everything the script writes
```

Stance is not part of this folder. To measure stance on a claim, filter `paragraph_topics.parquet` to the paragraphs you want, join their text back from the input, and upload that CSV to the stance app.

## The input

One row per paragraph, as already parsed from the speeches (paragraphs are the blocks between empty lines in each transcript):

| Column | What |
|------------------------------------|------------------------------------|
| `id` | the speech |
| `Year` | the year of the session, a whole number |
| `para_uid` | the paragraph's position within the speech: 1, 2, 3, ... |
| `raw_text` | the paragraph |

Names are set in `tx$cols` if yours differ. `id` + `para_uid` must be unique, and a speech must have one year; the script stops and says so if not.

**The paragraphs are used exactly as parsed.** None is merged, split, or edited, so every result joins back to other analyses of the same paragraphs on `id` + `para_uid`. A paragraph that is not one is left out whole:

1. **no complete sentence**: nothing ending in `.`, `?`, or `!`. This catches headers such as `Meeting/Event: peru` and `[Auto-generated transcript: may contain errors]`, dates, and subheadings;
2. **the presiding officer speaking**: introducing the speaker or thanking them, matched by the phrases in `tx$procedural` ("will now hear an address", "on behalf of the Assembly, I wish to thank", ...). Add phrases there if the report's examples show more;
3. **under `min_words` (20) words**: salutations such as "Distinguished delegates." and "Thank you."

The report counts each, plots the share left out by year, and prints examples of each so you can see what a rule caught. `dropped_paragraphs.parquet` lists every one with its reason.

## Running it

1. Put the CSV in `topics/unga/inputs/`.
2. **Choose K.** Render once with `run_searchK = TRUE`. The first grid is 5 and 10 to 100 by 10, on 4 workers. Each worker holds a copy of the data, so 4 is about what 32 GB allows. Read the plots, set `K_grid` to a finer grid around the best values, and render again. Each grid is saved under its own file name, so the passes do not overwrite each other. At this size, each pass can take hours.
3. **Fit.** Set `K`, set `run_searchK = FALSE`, and render. The fit is saved as `stm_fit.rds` and reloaded on later renders.
4. **Label.** The first full render drafts `topic_codebook.csv`, one call per topic. Edit it by hand. It is never redrafted while it exists, so delete it to redraft.
5. **Write the findings.** The report ends with empty sections under *Findings*. Fill them in once the numbers are in.

At work, set `use_openrouter = FALSE`; the codebook then uses `COMPASS_LARGE_URL` / `COMPASS_LARGE_KEY` from `.Renviron`.

The script lives inside the topics project and uses its functions (`topics/topics_source.R`), so the method is the same as `topics/topics.qmd`, minus the paragraph-building step that these transcripts do not need. A change to `topics_source.R` changes this analysis too: rerender after editing it.

## Outputs

| File | What | Size at 180,000 paragraphs |
|------------------------------------|------------------------------------|------------------------------------|
| `paragraph_topics.parquet` | `id`, `para_uid`, `Year`, assigned topic, its share, and every topic's share (4 decimals). No text | about 10 MB at K = 40 (0.7 MB measured at K = 4) |
| `topic_summary.parquet` | per-topic prevalence, FREX and probable words, paragraphs, AvePP | small |
| `topic_trends.parquet` | estimated share of each topic by year, with 95% intervals | small |
| `topic_codebook.csv` | labels, descriptions, propositions (edit by hand) | small |
| `dropped_paragraphs.parquet` | `id`, `para_uid`, `Year`, and the reason each was left out | small |
| `searchK_*.parquet` | the scores behind each K search | small |
| `stm_fit.rds` | the fitted model. **Not tracked by git** | about 70 MB measured at K = 4; 200 MB or more at K = 40 |
| `manifest.csv` | which input each saved result was built from | small |

**Why the fit stays off GitHub.** stm keeps several numbers per paragraph per topic inside the fit, and `thetaPosterior()` needs them for the trend intervals, so they cannot be stripped out. At this size the file passes GitHub's 100 MB limit, so `topics/unga/outputs/stm_fit.rds` is in `.gitignore`. Everything the report and later work read is in the parquet files, which are small. To render on another machine, copy `stm_fit.rds` across by hand (or to S3 if you move to AWS), or let the script refit. Spectral initialization repeats on the same machine, but stm's documentation warns it can differ slightly across machines, so topic numbers may shift and the codebook would need checking. Copying the file is safer.

**Memory and time**, from a synthetic test of 207,000 paragraphs on one core: the full script (fit at K = 4, 3 trend draws, outputs) peaked near 3 GB, and a render that reloads the saved fit took about a minute. Real speeches have a much larger vocabulary and K near 40, so the fit and each searchK run will take hours, not minutes. stm caps its spectral start at the 10,000 most frequent words, so vocabulary size does not blow up memory. The 25 draws behind the trends hold about 1.5 GB at K = 40. Four searchK workers on 32 GB should be safe; drop to 3 if the machine starts swapping.

`manifest.csv` records the md5 of the input each cached result was built from. If the input changes, the next render stops and names the file to delete, so a stale fit is never reloaded.

## What the numbers mean

- **Topics are found, not chosen.** Labels are drafted from each topic's words and paragraphs and should be checked by hand. A topic with AvePP under about 0.7 mixes subjects; read its paragraphs before relying on its trend.
- **Shares are shares of paragraphs.** A long speech counts more than a short one.
- **Trends are smoothed**, most of all at the first and last years. 2026 is the last year on the curve, so its estimate leans on the years before it. The report sets 2026 against the five years before it for that reason.
- **Who speaks changes.** Not every country speaks every year, so a trend mixes change in what is said with change in who said it. Country is not in the model.
- **These are machine transcripts.** Misheard words add noise to the topics; read examples before trusting a small topic.

## Packages

tidyverse, here, arrow, stm, tidytext, splines, viridis, furrr, future, withr, glue, knitr, scales, ellmer (0.4 or later; the codebook only).
