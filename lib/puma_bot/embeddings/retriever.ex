defmodule PumaBot.Embeddings.Retriever do
  @moduledoc """
  Handles similarity search and retrieval of content from the vector database.

  Uses pgvector's cosine similarity for semantic search across stored embeddings.
  """

  alias PumaBot.Data.DataSource
  alias PumaBot.Embeddings.Generator
  alias PumaBot.Repo

  import Ecto.Query

  @default_limit 5
  @default_threshold 0.7

  @type search_result :: %{
          data_source: DataSource.t(),
          similarity: float()
        }

  @type search_opts :: [
          limit: non_neg_integer(),
          threshold: float(),
          source_types: [atom()],
          model: String.t()
        ]

  @doc """
  Searches for content similar to the given query text.

  ## Options
  - `:limit` - Maximum number of results (default: 5)
  - `:threshold` - Minimum similarity score 0-1 (default: 0.7)
  - `:source_types` - Filter by source types (e.g., [:whatsapp, :claude_code])
  - `:model` - Embedding model to use for the query

  ## Examples

      iex> PumaBot.Embeddings.Retriever.search("What do I think about Elixir?")
      {:ok, [%{data_source: %DataSource{...}, similarity: 0.89}, ...]}

      iex> PumaBot.Embeddings.Retriever.search("coding", source_types: [:claude_code])
      {:ok, [%{data_source: %DataSource{...}, similarity: 0.75}]}
  """
  @spec search(String.t(), search_opts()) :: {:ok, [search_result()]} | {:error, term()}
  def search(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    source_types = Keyword.get(opts, :source_types)
    model_opts = if opts[:model], do: [model: opts[:model]], else: []

    with {:ok, query_embedding} <- Generator.generate(query_text, model_opts) do
      results = execute_similarity_search(query_embedding, limit, threshold, source_types)
      {:ok, results}
    end
  end

  @doc """
  Searches using a pre-computed embedding vector.

  Useful when you've already generated the embedding elsewhere.
  """
  @spec search_by_embedding([float()], search_opts()) :: {:ok, [search_result()]}
  def search_by_embedding(embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    source_types = Keyword.get(opts, :source_types)

    results = execute_similarity_search(embedding, limit, threshold, source_types)
    {:ok, results}
  end

  @doc """
  Retrieves context for a RAG query.

  Returns formatted context string ready to be injected into a prompt.

  ## Options
  Same as `search/2`, plus:
  - `:max_tokens` - Approximate max tokens for context (default: 2000)
  - `:separator` - Separator between context chunks (default: "\\n\\n---\\n\\n")
  """
  @spec get_context(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_context(query_text, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 2000)
    separator = Keyword.get(opts, :separator, "\n\n---\n\n")

    # Estimate ~4 characters per token
    max_chars = max_tokens * 4

    search_opts = Keyword.take(opts, [:limit, :threshold, :source_types, :model])
    # Get more results than needed to ensure we have enough content
    search_opts = Keyword.put(search_opts, :limit, Keyword.get(search_opts, :limit, 10))

    case search(query_text, search_opts) do
      {:ok, results} ->
        context =
          results
          |> Enum.reduce_while({[], 0}, fn result, {acc, char_count} ->
            content = result.data_source.processed_content || result.data_source.raw_content
            content_len = String.length(content)

            if char_count + content_len > max_chars do
              {:halt, {acc, char_count}}
            else
              {:cont, {[content | acc], char_count + content_len + String.length(separator)}}
            end
          end)
          |> elem(0)
          |> Enum.reverse()
          |> Enum.join(separator)

        {:ok, context}

      error ->
        error
    end
  end

  @doc """
  Finds similar documents to a given DataSource.

  Useful for finding related content or detecting near-duplicates.
  """
  @spec find_similar(DataSource.t(), search_opts()) :: {:ok, [search_result()]} | {:error, term()}
  def find_similar(%DataSource{embedding: nil}, _opts) do
    {:error, :no_embedding}
  end

  def find_similar(%DataSource{id: id, embedding: embedding}, opts) do
    limit = Keyword.get(opts, :limit, @default_limit) + 1  # +1 to exclude self
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    source_types = Keyword.get(opts, :source_types)

    results =
      execute_similarity_search(embedding, limit, threshold, source_types)
      |> Enum.reject(fn r -> r.data_source.id == id end)
      |> Enum.take(Keyword.get(opts, :limit, @default_limit))

    {:ok, results}
  end

  # --- Private ---

  defp execute_similarity_search(embedding, limit, threshold, source_types) do
    # Convert embedding to pgvector format
    embedding_vector = Pgvector.new(embedding)

    # Build base query
    base_query =
      from ds in DataSource,
        where: not is_nil(ds.embedding),
        select: %{
          data_source: ds,
          # Cosine similarity = 1 - cosine distance
          similarity: fragment("1 - (? <=> ?)", ds.embedding, ^embedding_vector)
        },
        order_by: [asc: fragment("? <=> ?", ds.embedding, ^embedding_vector)],
        limit: ^limit

    # Add source type filter if specified
    query =
      if source_types do
        from [ds] in base_query,
          where: ds.source_type in ^source_types
      else
        base_query
      end

    # Execute and filter by threshold
    Repo.all(query)
    |> Enum.filter(fn result -> result.similarity >= threshold end)
  end
end
