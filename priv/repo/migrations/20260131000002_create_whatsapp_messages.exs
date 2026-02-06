defmodule PumaBot.Repo.Migrations.CreateWhatsappMessages do
  use Ecto.Migration

  def change do
    create table(:whatsapp_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :message_id, :string, null: false
      add :chat_jid, :string, null: false
      add :chat_name, :string
      add :sender_jid, :string, null: false
      add :sender_name, :string
      add :content, :text
      add :message_type, :string, default: "text"
      add :is_from_me, :boolean, default: false
      add :is_group, :boolean, default: false
      add :media_url, :string
      add :media_mime_type, :string
      add :quoted_message_id, :string
      add :timestamp, :utc_datetime, null: false
      add :raw_data, :map, default: %{}

      # Link to processed data source with embedding
      add :data_source_id, references(:data_sources, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # Unique on message_id to prevent duplicates
    create unique_index(:whatsapp_messages, [:message_id])

    # Index for chat queries
    create index(:whatsapp_messages, [:chat_jid])

    # Index for sender queries
    create index(:whatsapp_messages, [:sender_jid])

    # Index for "my" messages (for personality training)
    create index(:whatsapp_messages, [:is_from_me])

    # Index for timestamp range queries
    create index(:whatsapp_messages, [:timestamp])

    # Composite index for chat + timestamp queries
    create index(:whatsapp_messages, [:chat_jid, :timestamp])
  end
end
