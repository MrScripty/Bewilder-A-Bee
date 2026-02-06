defmodule PumaBot.Repo.Migrations.CreateDataSources do
  use Ecto.Migration

  def up do
    # Enable pgvector extension (idempotent)
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:data_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_type, :string, null: false
      add :source_id, :string, null: false
      add :content_hash, :string
      add :raw_content, :text, null: false
      add :processed_content, :text
      add :metadata, :map, default: %{}
      add :embedding, :vector, size: 1536  # Common embedding dimension (adjustable)
      add :source_timestamp, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Unique constraint on source_type + source_id for deduplication
    create unique_index(:data_sources, [:source_type, :source_id])

    # Unique constraint on content_hash for content deduplication
    create unique_index(:data_sources, [:content_hash])

    # Index for source type queries
    create index(:data_sources, [:source_type])

    # Index for timestamp queries
    create index(:data_sources, [:source_timestamp])

    # Vector similarity search index using IVFFlat
    # IVFFlat is faster to build, good for development
    # For production with >1M rows, consider HNSW
    execute """
    CREATE INDEX data_sources_embedding_idx
    ON data_sources
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100)
    """
  end

  def down do
    drop table(:data_sources)
  end
end
