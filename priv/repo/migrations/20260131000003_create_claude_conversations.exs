defmodule PumaBot.Repo.Migrations.CreateClaudeConversations do
  use Ecto.Migration

  def change do
    create table(:claude_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :message_index, :integer, null: false
      add :project_path, :string
      add :role, :string, null: false
      add :content, :text
      add :tool_calls, {:array, :map}, default: []
      add :tool_results, {:array, :map}, default: []
      add :timestamp, :utc_datetime
      add :model, :string
      add :raw_data, :map, default: %{}

      # Link to processed data source with embedding
      add :data_source_id, references(:data_sources, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # Unique on session + message index
    create unique_index(:claude_conversations, [:session_id, :message_index])

    # Index for session queries
    create index(:claude_conversations, [:session_id])

    # Index for role queries (useful for finding user messages for personality)
    create index(:claude_conversations, [:role])

    # Index for project path queries
    create index(:claude_conversations, [:project_path])

    # Index for timestamp queries
    create index(:claude_conversations, [:timestamp])
  end
end
