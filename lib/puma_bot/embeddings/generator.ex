defmodule PumaBot.Embeddings.Generator do
  @moduledoc """
  Handles generation of embeddings for text content.

  Uses Ollama's embedding models to generate vector representations
  that can be stored in pgvector for similarity search.
  """

  alias PumaBot.LLM.Client
  alias PumaBot.Data.DataSource
  alias PumaBot.Repo

  require Logger

  @batch_size 10

  @doc """
  Generates an embedding for the given text.

  Returns a list of floats representing the embedding vector.

  ## Examples

      iex> PumaBot.Embeddings.Generator.generate("Hello, world!")
      {:ok, [0.123, -0.456, ...]}
  """
  @spec generate(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def generate(text, opts \\ []) do
    Client.embed(text, opts)
  end

  @doc """
  Generates embeddings for multiple texts in a batch.

  More efficient than calling `generate/1` multiple times.

  ## Examples

      iex> PumaBot.Embeddings.Generator.generate_batch(["Hello", "World"])
      {:ok, [[0.123, ...], [0.456, ...]]}
  """
  @spec generate_batch([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def generate_batch(texts, opts \\ []) when is_list(texts) do
    Client.embed(texts, opts)
  end

  @doc """
  Generates and stores an embedding for a DataSource record.

  Updates the record with the generated embedding.
  """
  @spec embed_data_source(DataSource.t(), keyword()) ::
          {:ok, DataSource.t()} | {:error, term()}
  def embed_data_source(%DataSource{} = data_source, opts \\ []) do
    text = data_source.processed_content || data_source.raw_content

    case generate(text, opts) do
      {:ok, embedding} ->
        data_source
        |> DataSource.changeset(%{embedding: embedding})
        |> Repo.update()

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Processes all DataSource records without embeddings in batches.

  Useful for backfilling embeddings after import.

  ## Options
  - `:batch_size` - Number of records to process at once (default: 10)
  - `:model` - Embedding model to use
  """
  @spec backfill_embeddings(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill_embeddings(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)

    import Ecto.Query

    query =
      from ds in DataSource,
        where: is_nil(ds.embedding),
        where: not is_nil(ds.raw_content),
        limit: ^batch_size

    process_batch(query, opts, 0)
  end

  defp process_batch(query, opts, total_processed) do
    records = Repo.all(query)

    if Enum.empty?(records) do
      Logger.info("Embedding backfill complete. Processed #{total_processed} records.")
      {:ok, total_processed}
    else
      Logger.info("Processing batch of #{length(records)} records...")

      texts =
        Enum.map(records, fn ds ->
          ds.processed_content || ds.raw_content
        end)

      case generate_batch(texts, opts) do
        {:ok, embeddings} ->
          # Update each record with its embedding
          Enum.zip(records, embeddings)
          |> Enum.each(fn {record, embedding} ->
            record
            |> DataSource.changeset(%{embedding: embedding})
            |> Repo.update!()
          end)

          # Process next batch
          process_batch(query, opts, total_processed + length(records))

        {:error, reason} ->
          Logger.error("Batch embedding failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Gets the embedding dimension for a given model.

  Useful for ensuring vector column size matches the model output.
  """
  @spec get_embedding_dimension(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_embedding_dimension(model \\ nil) do
    # Generate a test embedding to determine dimension
    case generate("test", model: model) do
      {:ok, embedding} -> {:ok, length(embedding)}
      error -> error
    end
  end
end
