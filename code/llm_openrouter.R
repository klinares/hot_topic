# llm_home_openrouter.R -------------------------------------------------------

# HOME ONLY. DELETE THIS FILE ON THE WORK SERVER and set home = FALSE in both

# scripts' config. The router in llm_source.R then uses

# ellmer::chat_openai_compatible() with the per-step base_url_env, api_key_env,

# and model from the steps table. Nothing else in the pipeline references this

# file, and both scripts source it only when their home flag is TRUE.

#

# Key lives in .Renviron, never here: OPENROUTER_API_KEY.



make_chat_home <- function(model, system_prompt) {

  ellmer::chat_openrouter(

    model         = sub("^openrouter/", "", model),   # the slug contains a "/"

    system_prompt = system_prompt,

    params        = ellmer::params(temperature = 0),

    echo          = "none")

}



# Home model per pipeline step. The steps tables in the two scripts supply the

# work models; when home = TRUE, these override the model column by step name.

open_router_models <- c(
  label       = "openrouter/meta-llama/llama-3.3-70b-instruct",
  manager     = "openrouter/meta-llama/llama-4-maverick",
  proposition = "openrouter/meta-llama/llama-4-maverick",
  stance_1    = "openrouter/google/gemma-4-31b-it",
  stance_2    = "openrouter/meta-llama/llama-3.1-70b-instruct")

