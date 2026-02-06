defmodule PumaBot.LLM.Client do
  @moduledoc """
  Wrapper around Ollama for LLM interactions.

  Provides a simplified interface for:
  - Chat completions
  - Embeddings generation
  - Model management

  Uses the `ollama` library under the hood.
  """

  require Logger

  @default_host "http://localhost:11434"
  @default_chat_model "qwen3:latest"
  @default_embed_model "nomic-embed-text"

  @type message :: %{role: String.t(), content: String.t()}
  @type chat_opts :: [
          model: String.t(),
          temperature: float(),
          system: String.t(),
          stream: boolean(),
          format: atom()
        ]
  @type embed_opts :: [model: String.t()]

  # --- Configuration ---

  @doc """
  Returns the configured Ollama host URL.
  """
  def host do
    Application.get_env(:puma_bot, :ollama_host, @default_host)
  end

  @doc """
  Returns the default chat model.
  """
  def default_chat_model do
    Application.get_env(:puma_bot, :ollama_chat_model, @default_chat_model)
  end

  @doc """
  Returns the default embedding model.
  """
  def default_embed_model do
    Application.get_env(:puma_bot, :ollama_embed_model, @default_embed_model)
  end

  # --- Chat ---

  @doc """
  Sends a chat completion request to Ollama.

  ## Options
  - `:model` - Model to use (default: configured chat model)
  - `:temperature` - Sampling temperature (default: 0.7)
  - `:system` - System prompt
  - `:stream` - Whether to stream the response (default: false)

  ## Examples

      iex> PumaBot.LLM.Client.chat([%{role: "user", content: "Hello!"}])
      {:ok, "Hello! How can I help you today?"}

      iex> PumaBot.LLM.Client.chat(
      ...>   [%{role: "user", content: "Hello!"}],
      ...>   system: "You are a helpful assistant."
      ...> )
      {:ok, "Hello! I'm here to help. What can I do for you?"}
  """
  @spec chat([message()], chat_opts()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) do
    model = Keyword.get(opts, :model, default_chat_model())
    temperature = Keyword.get(opts, :temperature, 0.7)
    system = Keyword.get(opts, :system)
    stream = Keyword.get(opts, :stream, false)

    # Build request options
    request_opts = [
      model: model,
      messages: format_messages(messages, system),
      stream: stream,
      options: %{temperature: temperature}
    ]

    client = build_client()

    case Ollama.chat(client, request_opts) do
      {:ok, %{"message" => %{"content" => content}}} ->
        {:ok, content}

      {:ok, response} when is_list(response) ->
        # Streaming response - collect all chunks
        content = Enum.map_join(response, "", fn chunk ->
          get_in(chunk, ["message", "content"]) || ""
        end)
        {:ok, content}

      {:error, reason} = error ->
        Logger.error("Ollama chat error: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Streams a chat completion, yielding chunks to the provided function.

  ## Examples

      PumaBot.LLM.Client.chat_stream(
        [%{role: "user", content: "Tell me a story"}],
        fn chunk -> IO.write(chunk) end
      )
  """
  @spec chat_stream([message()], (String.t() -> any()), chat_opts()) :: :ok | {:error, term()}
  def chat_stream(messages, callback, opts \\ []) do
    model = Keyword.get(opts, :model, default_chat_model())
    temperature = Keyword.get(opts, :temperature, 0.7)
    system = Keyword.get(opts, :system)

    request_opts = [
      model: model,
      messages: format_messages(messages, system),
      stream: true,
      options: %{temperature: temperature}
    ]

    client = build_client()

    stream_handler = fn chunk ->
      case chunk do
        %{"message" => %{"content" => content}} when content != "" ->
          callback.(content)
        _ ->
          :ok
      end
    end

    case Ollama.chat(client, Keyword.put(request_opts, :stream, stream_handler)) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # --- Embeddings ---

  @doc """
  Generates embeddings for the given text.

  ## Options
  - `:model` - Embedding model to use (default: configured embed model)

  ## Examples

      iex> PumaBot.LLM.Client.embed("Hello, world!")
      {:ok, [0.123, -0.456, ...]}

      iex> PumaBot.LLM.Client.embed(["Hello", "World"])
      {:ok, [[0.123, ...], [0.456, ...]]}
  """
  @spec embed(String.t() | [String.t()], embed_opts()) ::
          {:ok, [float()] | [[float()]]} | {:error, term()}
  def embed(text, opts \\ []) do
    model = Keyword.get(opts, :model, default_embed_model())
    client = build_client()

    case Ollama.embed(client, model: model, input: text) do
      {:ok, %{"embeddings" => embeddings}} when is_list(embeddings) ->
        # If single text, return single embedding; if list, return list
        result = if is_binary(text), do: List.first(embeddings), else: embeddings
        {:ok, result}

      {:error, reason} = error ->
        Logger.error("Ollama embed error: #{inspect(reason)}")
        error
    end
  end

  # --- Model Management ---

  @doc """
  Lists available models on the Ollama server.
  """
  @spec list_models() :: {:ok, [map()]} | {:error, term()}
  def list_models do
    client = build_client()

    case Ollama.list_models(client) do
      {:ok, %{"models" => models}} -> {:ok, models}
      {:error, _} = error -> error
    end
  end

  @doc """
  Checks if a specific model is available.
  """
  @spec model_available?(String.t()) :: boolean()
  def model_available?(model_name) do
    case list_models() do
      {:ok, models} ->
        Enum.any?(models, fn m ->
          m["name"] == model_name or String.starts_with?(m["name"], model_name <> ":")
        end)

      _ ->
        false
    end
  end

  @doc """
  Checks if the Ollama server is reachable.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case list_models() do
      {:ok, _} -> true
      _ -> false
    end
  end

  # --- Private ---

  defp build_client do
    Ollama.init(host())
  end

  defp format_messages(messages, nil), do: messages

  defp format_messages(messages, system) do
    [%{role: "system", content: system} | messages]
  end
end
