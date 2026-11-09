# Handoff: stance app, user-supplied key and model, tests, simplification

Paste this whole file into Claude Code, started in `D:\repos\hot_topic`. Read
it to the end before touching code.

## Who I am and how I work

I'm Kevin, a survey methodologist. I write R in the tidyverse style. Rules
that apply to every line you write:

- **Never use `for` loops in R.** Use `purrr::map()` and its relatives.
- Native pipe `|>`, `dplyr::` namespacing in package-style files, minimal and readable code with short comments that explain *why*.
- **API keys never go in code, logs, files, downloads or `Sys.setenv()`.**
- No em-dashes in prose (UI text, README, comments).
- Don't hand me untested code as if it works. Say what you ran and what you didn't.
- Ask before deleting files or making large structural changes. Prefer deleting code to adding it.

## The project

`hot_topic` has two independent tools. **Only `stance/` is in scope here.**
Don't touch `topics/`.

`stance/` is a Shiny app (deployed on Posit Connect) plus a Quarto report
(`stance.qmd`). A user uploads a CSV of short passages, writes one claim, and
picks a label scheme (favor, agree or aligned). Every passage is sent alone to
an OpenAI-compatible `/chat/completions` endpoint at temperature 0, and the
one-word reply becomes the label. The app reports salience (share of
passages addressing the claim) and direction (shares among relevant
passages), static or as trends with clustered 95% intervals. It also writes a
400-passage hand-coding sheet, and the Check the labels tab computes
agreement (Cohen's kappa) from the labeled file and the hand-coded sheet,
matched by run id. The app keeps no state between sessions.

```
stance/
  app.R                 settings block, banner and logo, page layout
  R/stance_core.R       prompt, requests (httr2), parsing, estimates, plots, agreement
  R/ui_stance.R         Detect stance and Check the labels (module mod_stance_*)
  R/ui_stance_help.R    Start here page
  R/ui_stance_prompt.R  Start here card printing the prompt per scheme
  R/classification.R    OBSOLETE: banner and logo now live in app.R; delete it
  stance.qmd            the method report (renders stance.pdf); uses st$url/st$model/st$key
  stance_source.R       helpers for stance.qmd only
  inputs/ outputs/      data for stance.qmd (inputs/ is gitignored)
```

### How the connection works today (read the code to confirm)

- `app.R` sets `options(stance.model = "gemma4:31b", stance.reasoning_effort = "none", stance.workers, stance.sec_per_passage, stance.call_limit = 300)`.
- On Detect stance, step 1 "Connect to the model" has an Endpoint URL text box, an API key `passwordInput`, and a **Check connection** button.
- `stance_check(ep)` in `stance_core.R` sends one short request with the real model and settings. It returns `list(ok, secs, message)`, and the message carries the provider's error body (401 bad key, 404 unknown model, unreachable host, empty reply meaning the model is thinking).
- The checked endpoint is held in `conn <- reactiveVal(NULL)` inside the module. Editing the URL or key clears it. A run refuses to start until `conn()` is set.
- `stance_endpoint(url, model, key, reasoning_effort)` builds the endpoint list. A `NULL` url, model or key falls back to `STANCE_URL`, `STANCE_MODEL` and `STANCE_KEY` (used by `stance.qmd`).
- The model name is written into every labeled row (`stance_model`) and into the estimates. The key is never written anywhere; a test confirmed it's absent from all downloads.

## The task

### 1. Change who supplies what

| Item | Now | Wanted |
|---|---|---|
| base URL | typed by the user | **hard-coded in `app.R`, one per provider** |
| API key | typed by the user | typed by the user. **Never a server key, never saved anywhere** |
| model | hard-coded `stance.model` | **chosen by the user from a fixed list of three** |

**The three models**, defined once in a table in `app.R`:

| Label shown | Provider and client | Rate limit to enforce |
|---|---|---|
| Gemma 4 (default) | OpenAI-compatible `/chat/completions`, the current httr2 path | 300 requests per 4 hours |
| Claude Sonnet 4.5 | Anthropic, through `ellmer::chat_anthropic()` | 300 requests per minute |
| Claude Opus 5 | Anthropic, through `ellmer::chat_anthropic()` | 300 requests per minute |

Suggested shape (adjust names, but keep it one table):

```r
options(stance.models = list(
  gemma4 = list(label = "Gemma 4", provider = "openai",
                base_url = "https://YOUR-GEMMA-ENDPOINT/v1", model = "GEMMA-ID",
                limit = 300, window_secs = 4 * 3600),
  sonnet = list(label = "Claude Sonnet 4.5", provider = "anthropic",
                base_url = "https://YOUR-ANTHROPIC-ENDPOINT", model = "SONNET-ID",
                limit = 300, window_secs = 60),
  opus   = list(label = "Claude Opus 5", provider = "anthropic",
                base_url = "https://YOUR-ANTHROPIC-ENDPOINT", model = "OPUS-ID",
                limit = 300, window_secs = 60)))
```

**The exact model IDs and base URLs are placeholders.** I will fill them in. Do not guess IDs such as `claude-opus-5`; leave them as `"SONNET-ID"` and `"OPUS-ID"` and stop the app at startup with a clear message if a placeholder is still there.

**Keys.** Follow my DrSvyR app (`ui_chat.R`):
- a masked key field, with **Use this key** and **Forget it** buttons;
- clear the input box after the key is accepted;
- a status line: key in use, or none;
- a note that the key lives for this session only, is never saved and is not in any result.

There is **no server key at all**: never read `STANCE_KEY`, `ANTHROPIC_API_KEY` or any environment variable in the app, and never call `Sys.setenv()`. Be careful here: `ellmer::chat_anthropic()` reads `ANTHROPIC_API_KEY` by default, so always pass the user's key explicitly. Check the installed ellmer's documentation for how; I believe `credentials` (a function) replaced `api_key` in ellmer 0.4.0, but verify. Write a test proving the app fails without a pasted key even when `ANTHROPIC_API_KEY` is set in the environment.

You don't need DrSvyR's process-wide key registry keyed by `session$token`. It exists there because model calls happen deep outside the modules. In this app every call starts inside `mod_stance_server`, so a `reactiveVal` in the module is already per-session and dies with it. Keep that; it is simpler. If you disagree, explain why before changing it.

**One key or one per provider?** Assume one key field that applies to whichever model is selected, and clear the key when the user switches provider (Gemma vs Claude), since one key cannot serve both. Ask me if you think two fields are cleaner.

**Two code paths, one interface.** Put the provider difference behind one function, for example `stance_label_all(texts, prompt, endpoint, on_step)`, so the module, the estimates, the run id and the downloads do not care which provider ran:
- **openai** (Gemma): keep the current httr2 code (`stance_request`, `code_all`, `req_perform_parallel`) and its dedupe, probe and chunked progress.
- **anthropic**: build one `ellmer::chat_anthropic()` per run with the claim's prompt as the system prompt, temperature 0 and a small max_tokens, and send passages with `ellmer::parallel_chat_text()`. Each passage must be its own conversation, never a continuing chat: confirm that `parallel_chat_text()` gives each prompt a fresh turn from the system prompt. I believe it has `max_active` and `rpm` arguments; verify them and use `rpm` for the 300-per-minute limit. Keep the dedupe (unique texts sent once, labels copied back) and the same label parser (`stance_parse`). Progress: if `parallel_chat_text` cannot report progress, send in chunks and update the bar per chunk.
- Check whether the current Anthropic models accept `temperature = 0` (some newer ones restrict sampling settings). If not, drop it for those models and say so in the prompt card and in your summary, since it affects reproducibility.

**Rate limits, per model:**
- **Claude (300 per minute):** throttle so no more than 300 requests go in any minute. The run waits; it never sends faster.
- **Gemma (300 per 4 hours):** before a run, if the unique passages exceed 300, warn that requests past the limit will fail and those passages stay unlabeled, and suggest a random sample. Keep this simple. Do not build a scheduler that waits 4 hours inside a Shiny session.
- The time estimate should use each model's limit: about N/300 minutes for Claude, and the warning for Gemma.

**The check.** **Check connection** runs one short request with the selected model, base URL and pasted key, through the same path a run uses. A run stays locked until it passes. Changing the key or the model clears it. Error messages must name the problem (bad key, unknown model, unreachable host, rate limit) and must never contain the key. `reasoning_effort` applies to Gemma only; for Gemma, if the check fails with a 400 that mentions `reasoning_effort`, retry once without it and remember that for the session.

**A model other than Gemma 4.** Show a short note under the check result: the prompt was written and tested with Gemma 4, labels from this model have not been checked against hand coding, so do the 400-passage check before reporting. Also note that the passages are sent to the provider, so upload only text that may go there.

**Keep:**
- the model ID recorded in every output row and in the run id (check how `stance_run_id()` is built, so runs with different models are told apart and the Check the labels tab will refuse to match a sheet from another model's run);
- the Start here page and prompt card, updated: list the three models and their providers, and do not claim settings (temperature, reasoning_effort) that a given model does not get.

**`stance.qmd`** stays script-driven and Gemma-only, reading `STANCE_KEY` from `.Renviron` as now. That is a local script, not the app, so the never-a-server-key rule is about the app. Make sure the changed functions still work for it.

### 2. Test so we find bugs

The old tests (`t1_core.R` to `t5_qmd.R`, and others from earlier sessions) are outside the repo, predate the label schemes, and no longer match the code. **Replace them** with a `testthat` suite in `stance/tests/testthat/`, run with `testthat::test_dir("stance/tests/testthat")`. Use a local mock server (`webfakes`) for the endpoint: no real network, no real key.

Minimum coverage:

- **Core functions:**
  - `stance_screen()` word bounds (5 to 250) and reasons;
  - `stance_prepare()` with and without time and document columns;
  - `stance_parse()` for each scheme, including replies with extra words, punctuation, upper case, an empty reply, and a reply naming a label from another scheme;
  - duplicate passages sent once (count requests on the mock) and labels copied back in the right order;
  - `stance_static()` and the trend rule (period ≥ 30 passages, ≥ 4 such periods, otherwise static);
  - salience = 1 − irrelevant share; the direction shares among relevant passages sum to 1;
  - intervals inside [0, 1].
- **Endpoint and connection:**
  - for each provider (a mock OpenAI-compatible server and a mock Anthropic `/v1/messages` server): good key and model pass;
  - bad key gives 401 with the provider's message shown;
  - unknown model gives 404;
  - unreachable host;
  - empty reply gives the thinking hint;
  - a 400 mentioning `reasoning_effort` is retried without it (Gemma);
  - with `ANTHROPIC_API_KEY` and `STANCE_KEY` set in the environment and no key pasted, the app refuses to check or run;
  - no more than 300 requests reach the Claude mock in any 60-second window (count timestamps on the mock; shorten the window in the test through an option if the real one makes the test too slow);
  - the key never appears in any message, label file, estimates file, sheet or prompt file.
- **Rate limits:** a mock that returns 429 after N calls, for each provider. Confirm what the user sees: unlabeled passages are counted and reported, the app doesn't crash, and no label is invented. Report what actually happens; don't paper over it.
- **Module (`shiny::testServer(mod_stance_server, ...)`):**
  - no run without a passed check;
  - Forget it clears the key and the connection;
  - changing the model clears the connection, and switching provider also clears the key;
  - a full run on a small CSV gives the expected labels and estimates;
  - downloads contain the chosen model ID, for a Gemma run and a Claude run;
  - the Check the labels tab matches the run's labeled file and its sheet, and refuses a sheet from another run.
- **`app.R` smoke test:** source it, build the UI, and confirm the banner, the logo placeholder and the three tabs render with no error.
- **`stance.qmd`:** at least `knitr::purl()` it and run the code against the mock. Quarto may not be installed; say so if it isn't.

When a test finds a bug, fix the code, not the test, unless the test was wrong. List every bug found in your final summary.

### 3. Simplify

After the tests pass, look for code to delete or merge, then rerun the suite:

- **Delete `stance/R/classification.R`** (nothing calls it). Ask before deleting anything else.
- **Remove dead code:** functions nobody calls, options nobody reads. Grep, for example, for `stance.tested`, `stance.docs`, `stance.url_hint` (made obsolete by the hard-coded URL) and `stance_source.R` helpers that duplicate `stance_core.R`.
- **Collapse repetition:** any helper used once that adds nothing.
- **Keep the comments that explain why;** cut comments that restate the code.
- Report line counts per file before and after.

Don't change the method: the prompt text, the label schemes, the screening bounds, the trend rule, the interval method and the agreement statistics stay as they are, unless a test proves one is wrong. If one is, stop and tell me rather than changing it.

### 4. Docs

Update `README.md` (the stance sections), the Start here text, and the comments at the top of `app.R` so they describe: base URL fixed in `app.R`, key and model from the user, and the check before a run. Keep them short.

## Settings block I expect in `app.R` afterwards

```r
options(
  stance.models = list(...),        # the three models, as above: the only connection details in code
  stance.default_model = "gemma4",  # pre-selected; the prompt was tested on it
  stance.reasoning_effort = "none", # Gemma only; dropped automatically if the endpoint rejects it
  stance.workers = 1)               # concurrent requests (Claude is additionally held to its rpm)
```

## Constraints and context

- Gemma allows **300 requests per 4 hours**; Claude allows **300 per minute**. Don't run anything against a real endpoint without asking me; use the mocks.
- R packages already used: shiny, bslib, httr2 (≥ 1.1.1 for `req_perform_parallel(max_active =)`), dplyr, readr, purrr, ggplot2, splines, glue, withr, DT. **ellmer is now a runtime package** (for Anthropic); report the installed version and pin the minimum in the README. Test-only additions (`testthat`, `webfakes`) are fine. Ask before adding any other runtime package.
- On Posit Connect, "Max connections per process" is 1, so each user gets their own R process. Even so, don't store keys in globals or options.
- Windows paths: the repo is at `D:\repos\hot_topic`.

## When you finish

Give me:
1. What changed, file by file, in a few lines each.
2. The test results: how many tests, all passing or not, and the bugs found and fixed.
3. Line counts before and after.
4. Anything you could not test, and anything you think is still risky.
5. Files you want me to delete or that you deleted.

Before you start, ask me anything this file leaves unclear.
