# llm_openrouter.R: models for home use through OpenRouter. At work, set
# use_openrouter = FALSE in each script (this file is then not read); the
# steps tables decide the endpoint. The key lives in .Renviron as
# OPENROUTER_API_KEY.
open_router_models <- c(
  embed = "mistralai/mistral-embed-2312",
  codebook = "meta-llama/llama-4-maverick")
