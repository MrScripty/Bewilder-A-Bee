defmodule PumaBot.Data.DataSource do
  @moduledoc """
  Unified data source schema for storing all imported content with embeddings.

  This serves as the main table for RAG retrieval, storing processed content
  from various sources (WhatsApp, Claude Code, etc.) with vector embeddings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @source_types [:whatsapp, :claude_code, :git, :notes, :other]

  @type t :: %__MODULE__{
          id: binary(),
          source_type: atom(),
          source_id: String.t(),
          content_hash: String.t(),
          raw_content: String.t(),
          processed_content: String.t(),
          metadata: map(),
          embedding: Pgvector.Ecto.Vector.t() | nil,
          source_timestamp: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "data_sources" do
    field :source_type, Ecto.Enum, values: @source_types
    field :source_id, :string
    field :content_hash, :string
    field :raw_content, :string
    field :processed_content, :string
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector
    field :source_timestamp, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid source types.
  """
  def source_types, do: @source_types

  @doc """
  Creates a changeset for inserting or updating a data source.
  """
  def changeset(data_source, attrs) do
    data_source
    |> cast(attrs, [
      :source_type,
      :source_id,
      :content_hash,
      :raw_content,
      :processed_content,
      :metadata,
      :embedding,
      :source_timestamp
    ])
    |> validate_required([:source_type, :source_id, :raw_content])
    |> unique_constraint([:source_type, :source_id],
      name: :data_sources_source_type_source_id_index
    )
    |> unique_constraint(:content_hash, name: :data_sources_content_hash_index)
    |> compute_content_hash()
  end

  defp compute_content_hash(changeset) do
    case get_change(changeset, :raw_content) do
      nil ->
        changeset

      content ->
        hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
        put_change(changeset, :content_hash, hash)
    end
  end
end
