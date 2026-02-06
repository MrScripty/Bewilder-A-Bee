defmodule PumaBot.Data.WhatsAppMessage do
  @moduledoc """
  Schema for WhatsApp messages imported from chat exports or the Baileys bridge.

  Stores the original message structure before processing into DataSource.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: binary(),
          message_id: String.t(),
          chat_jid: String.t(),
          chat_name: String.t() | nil,
          sender_jid: String.t(),
          sender_name: String.t() | nil,
          content: String.t(),
          message_type: atom(),
          is_from_me: boolean(),
          is_group: boolean(),
          media_url: String.t() | nil,
          media_mime_type: String.t() | nil,
          quoted_message_id: String.t() | nil,
          timestamp: DateTime.t(),
          raw_data: map(),
          data_source_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @message_types [:text, :image, :video, :audio, :document, :sticker, :location, :contact, :reaction, :other]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "whatsapp_messages" do
    field :message_id, :string
    field :chat_jid, :string
    field :chat_name, :string
    field :sender_jid, :string
    field :sender_name, :string
    field :content, :string
    field :message_type, Ecto.Enum, values: @message_types, default: :text
    field :is_from_me, :boolean, default: false
    field :is_group, :boolean, default: false
    field :media_url, :string
    field :media_mime_type, :string
    field :quoted_message_id, :string
    field :timestamp, :utc_datetime
    field :raw_data, :map, default: %{}

    # Link to the unified data source (once processed with embedding)
    belongs_to :data_source, PumaBot.Data.DataSource

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid message types.
  """
  def message_types, do: @message_types

  @doc """
  Creates a changeset for a WhatsApp message.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :message_id,
      :chat_jid,
      :chat_name,
      :sender_jid,
      :sender_name,
      :content,
      :message_type,
      :is_from_me,
      :is_group,
      :media_url,
      :media_mime_type,
      :quoted_message_id,
      :timestamp,
      :raw_data,
      :data_source_id
    ])
    |> validate_required([:message_id, :chat_jid, :sender_jid, :timestamp])
    |> unique_constraint(:message_id, name: :whatsapp_messages_message_id_index)
  end
end
