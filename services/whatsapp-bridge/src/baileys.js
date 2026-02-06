import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  fetchLatestBaileysVersion,
  makeCacheableSignalKeyStore,
} from '@whiskeysockets/baileys';
import { Boom } from '@hapi/boom';
import pino from 'pino';
import qrcode from 'qrcode-terminal';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const AUTH_DIR = path.join(__dirname, '..', 'auth');
const BUFFER_FILE = path.join(__dirname, '..', 'buffer.jsonl');

const logger = pino({ level: 'warn' });

class BaileysClient {
  constructor() {
    this.sock = null;
    this.qrCode = null;
    this.status = 'disconnected';
    this.messageBuffer = [];
    this.maxBufferSize = 50000;
    this.historySyncComplete = false;
    this.historySyncProgress = { chats: 0, messages: 0 };
    this.chats = new Map();

    // Load any persisted messages from disk
    this.loadBufferFromDisk();
  }

  // Persist a message to the buffer file
  appendToBufferFile(msg) {
    try {
      fs.appendFileSync(BUFFER_FILE, JSON.stringify(msg) + '\n');
    } catch (err) {
      console.error('[WhatsApp] Failed to write to buffer file:', err.message);
    }
  }

  // Load persisted messages on startup
  loadBufferFromDisk() {
    try {
      if (fs.existsSync(BUFFER_FILE)) {
        const content = fs.readFileSync(BUFFER_FILE, 'utf8');
        const lines = content.split('\n').filter(line => line.trim());
        this.messageBuffer = lines.map(line => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        }).filter(msg => msg !== null);
        console.log(`[WhatsApp] Loaded ${this.messageBuffer.length} messages from buffer file`);
      }
    } catch (err) {
      console.error('[WhatsApp] Failed to load buffer file:', err.message);
      this.messageBuffer = [];
    }
  }

  // Clear the buffer file after messages are consumed
  clearBufferFile() {
    try {
      fs.writeFileSync(BUFFER_FILE, '');
    } catch (err) {
      console.error('[WhatsApp] Failed to clear buffer file:', err.message);
    }
  }

  async connect() {
    const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
    const { version } = await fetchLatestBaileysVersion();

    this.sock = makeWASocket({
      version,
      logger,
      auth: {
        creds: state.creds,
        keys: makeCacheableSignalKeyStore(state.keys, logger),
      },
      generateHighQualityLinkPreview: false,
      syncFullHistory: true,
    });

    // Handle connection updates
    this.sock.ev.on('connection.update', async (update) => {
      const { connection, lastDisconnect, qr } = update;

      if (qr) {
        this.qrCode = qr;
        this.status = 'waiting_for_qr';
        console.log('\n[WhatsApp] Scan QR code to login:');
        qrcode.generate(qr, { small: true });
      }

      if (connection === 'close') {
        const shouldReconnect =
          lastDisconnect?.error instanceof Boom &&
          lastDisconnect.error.output?.statusCode !== DisconnectReason.loggedOut;

        console.log('[WhatsApp] Connection closed:', lastDisconnect?.error?.message);
        this.status = 'disconnected';

        if (shouldReconnect) {
          console.log('[WhatsApp] Reconnecting...');
          setTimeout(() => this.connect(), 3000);
        } else {
          console.log('[WhatsApp] Logged out. Delete auth/ folder to re-authenticate.');
        }
      } else if (connection === 'open') {
        console.log('[WhatsApp] Connected successfully!');
        this.status = 'connected';
        this.qrCode = null;
      }
    });

    // Save credentials on update
    this.sock.ev.on('creds.update', saveCreds);

    // Handle history sync - THIS IS THE KEY PART
    this.sock.ev.on('messaging-history.set', async ({ chats, contacts, messages, isLatest }) => {
      console.log(`[WhatsApp] History sync: ${chats?.length || 0} chats, ${messages?.length || 0} messages, isLatest: ${isLatest}`);

      this.historySyncProgress.chats += (chats?.length || 0);
      this.historySyncProgress.messages += (messages?.length || 0);

      // Store chat metadata
      if (chats) {
        for (const chat of chats) {
          const chatName = chat.name || chat.subject || null;
          this.chats.set(chat.id, {
            jid: chat.id,
            name: chatName || chat.id,
            hasRealName: !!chatName,
            type: chat.id.endsWith('@g.us') ? 'group' : 'individual',
          });
          // Debug: log groups with actual names
          if (chatName && chat.id.endsWith('@g.us')) {
            console.log(`[WhatsApp] History group: ${chat.id} -> "${chatName}"`);
          }
        }
      }

      // Process synced messages
      if (messages) {
        for (const msg of messages) {
          const formatted = this.formatMessage(msg);
          if (formatted) {
            // Check for duplicates
            const exists = this.messageBuffer.some(m => m.message_id === formatted.message_id);
            if (!exists) {
              this.messageBuffer.push(formatted);
              // Persist to disk immediately
              this.appendToBufferFile(formatted);
            }
          }
        }
      }

      // Trim buffer if too large
      while (this.messageBuffer.length > this.maxBufferSize) {
        this.messageBuffer.shift();
      }

      if (isLatest) {
        this.historySyncComplete = true;
        console.log(`[WhatsApp] History sync complete! Total: ${this.historySyncProgress.messages} messages from ${this.historySyncProgress.chats} chats`);
        console.log(`[WhatsApp] Buffered ${this.messageBuffer.length} messages for import`);
      }
    });

    // Handle real-time messages
    this.sock.ev.on('messages.upsert', async ({ messages, type }) => {
      console.log(`[WhatsApp] messages.upsert: ${messages.length} messages, type: ${type}`);

      for (const msg of messages) {
        const formatted = this.formatMessage(msg);
        if (formatted) {
          // Avoid duplicates
          const exists = this.messageBuffer.some(m => m.message_id === formatted.message_id);
          if (!exists) {
            this.messageBuffer.push(formatted);
            // Persist to disk immediately
            this.appendToBufferFile(formatted);
            if (this.messageBuffer.length > this.maxBufferSize) {
              this.messageBuffer.shift();
            }
          }
        }
      }
    });

    // Handle chat updates
    this.sock.ev.on('chats.upsert', (chats) => {
      console.log(`[WhatsApp] ${chats.length} chats synced`);
      for (const chat of chats) {
        const chatName = chat.name || chat.subject || null;
        this.chats.set(chat.id, {
          jid: chat.id,
          name: chatName || chat.id,
          hasRealName: !!chatName,
          type: chat.id.endsWith('@g.us') ? 'group' : 'individual',
        });
        // Debug: log groups with actual names
        if (chatName && chat.id.endsWith('@g.us')) {
          console.log(`[WhatsApp] Group: ${chat.id} -> "${chatName}"`);
        }
      }
    });

    // Handle group metadata updates (subject changes, etc)
    this.sock.ev.on('groups.upsert', (groups) => {
      console.log(`[WhatsApp] ${groups.length} groups metadata received`);
      for (const group of groups) {
        const existing = this.chats.get(group.id);
        const chatName = group.subject || group.name || (existing?.name !== group.id ? existing?.name : null);
        this.chats.set(group.id, {
          jid: group.id,
          name: chatName || group.id,
          hasRealName: !!chatName,
          type: 'group',
        });
        if (chatName) {
          console.log(`[WhatsApp] Group metadata: ${group.id} -> "${chatName}"`);
        }
      }
    });

    // Handle group updates (when subject changes)
    this.sock.ev.on('groups.update', (updates) => {
      for (const update of updates) {
        if (update.subject) {
          const existing = this.chats.get(update.id);
          if (existing) {
            existing.name = update.subject;
            existing.hasRealName = true;
            console.log(`[WhatsApp] Group updated: ${update.id} -> "${update.subject}"`);
          }
        }
      }
    });

    return this;
  }

  formatMessage(msg) {
    if (!msg.message) return null;

    // Handle reaction messages specially - they reference a target message
    if (msg.message.reactionMessage) {
      const reaction = msg.message.reactionMessage;
      const chatJid = msg.key.remoteJid;
      const chatInfo = this.chats.get(chatJid);

      return {
        message_id: msg.key.id,
        chat_jid: chatJid,
        chat_name: chatInfo?.name || null,
        sender_jid: msg.key.participant || chatJid,
        is_from_me: msg.key.fromMe || false,
        content: reaction.text || '',
        message_type: 'reaction',
        timestamp: new Date().toISOString(),
        push_name: msg.pushName || null,
        quoted_message_id: null,
        quoted_content: null,
        quoted_sender: null,
        reaction_target_id: reaction.key?.id || null,
        raw_data: msg,
      };
    }

    const content = this.extractContent(msg.message);
    if (!content) return null;

    // Handle timestamp - could be number or Long object
    let timestamp;
    if (typeof msg.messageTimestamp === 'number') {
      timestamp = new Date(msg.messageTimestamp * 1000).toISOString();
    } else if (msg.messageTimestamp?.low !== undefined) {
      // Long object from protobuf
      timestamp = new Date(msg.messageTimestamp.low * 1000).toISOString();
    } else if (msg.messageTimestamp?.toNumber) {
      timestamp = new Date(msg.messageTimestamp.toNumber() * 1000).toISOString();
    } else {
      timestamp = new Date().toISOString();
    }

    // Look up chat name from our stored chats
    const chatJid = msg.key.remoteJid;
    const chatInfo = this.chats.get(chatJid);
    const chatName = chatInfo?.name || null;

    // Extract quoted message info if this is a reply
    const quotedInfo = this.extractQuotedMessage(msg.message);

    return {
      message_id: msg.key.id,
      chat_jid: chatJid,
      chat_name: chatName,
      sender_jid: msg.key.participant || chatJid,
      is_from_me: msg.key.fromMe || false,
      content: content.text,
      message_type: content.type,
      timestamp: timestamp,
      push_name: msg.pushName || null,
      quoted_message_id: quotedInfo?.stanzaId || null,
      quoted_content: quotedInfo?.content || null,
      quoted_sender: quotedInfo?.participant || null,
      raw_data: msg,
    };
  }

  extractContent(message) {
    if (message.conversation) {
      return { type: 'text', text: message.conversation };
    }
    if (message.extendedTextMessage?.text) {
      return { type: 'text', text: message.extendedTextMessage.text };
    }
    if (message.imageMessage) {
      return { type: 'image', text: message.imageMessage.caption || '[Image]' };
    }
    if (message.videoMessage) {
      return { type: 'video', text: message.videoMessage.caption || '[Video]' };
    }
    if (message.audioMessage) {
      return { type: 'audio', text: '[Audio]' };
    }
    if (message.documentMessage) {
      return { type: 'document', text: message.documentMessage.fileName || '[Document]' };
    }
    if (message.stickerMessage) {
      return { type: 'sticker', text: '[Sticker]' };
    }
    if (message.contactMessage) {
      return { type: 'contact', text: message.contactMessage.displayName || '[Contact]' };
    }
    if (message.locationMessage) {
      return { type: 'location', text: '[Location]' };
    }
    if (message.reactionMessage) {
      return { type: 'reaction', text: message.reactionMessage.text || '' };
    }
    return null;
  }

  extractQuotedMessage(message) {
    // Check all message types that can contain contextInfo with a quoted message
    const containers = [
      message.extendedTextMessage,
      message.imageMessage,
      message.videoMessage,
      message.audioMessage,
      message.documentMessage,
      message.stickerMessage,
      message.contactMessage,
      message.locationMessage,
    ];

    for (const container of containers) {
      const ctx = container?.contextInfo;
      if (ctx?.quotedMessage && ctx?.stanzaId) {
        const quotedContent = this.extractContent(ctx.quotedMessage);
        return {
          stanzaId: ctx.stanzaId,
          participant: ctx.participant || null,
          content: quotedContent?.text || null,
        };
      }
    }

    return null;
  }

  getStatus() {
    return {
      status: this.status,
      connected: this.status === 'connected',
      has_qr: !!this.qrCode,
      buffered_messages: this.messageBuffer.length,
      history_sync_complete: this.historySyncComplete,
      history_sync_progress: this.historySyncProgress,
      chats_count: this.chats.size,
    };
  }

  getQRCode() {
    return this.qrCode;
  }

  getBufferedMessages(clear = true) {
    const messages = [...this.messageBuffer];
    if (clear) {
      this.messageBuffer = [];
      this.clearBufferFile();
    }
    return messages;
  }

  peekBufferedMessages() {
    return [...this.messageBuffer];
  }

  async getChats() {
    const chats = Array.from(this.chats.values());
    const withNames = chats.filter(c => c.hasRealName);
    const groups = chats.filter(c => c.type === 'group');
    const groupsWithNames = groups.filter(c => c.hasRealName);

    console.log(`[WhatsApp] getChats: ${chats.length} total, ${withNames.length} with names, ${groups.length} groups (${groupsWithNames.length} named)`);

    return chats;
  }

  // Fetch group metadata for groups missing names
  async fetchMissingGroupNames() {
    if (!this.sock || this.status !== 'connected') {
      return { fetched: 0, error: 'Not connected' };
    }

    const groups = Array.from(this.chats.values()).filter(
      c => c.type === 'group' && !c.hasRealName
    );

    console.log(`[WhatsApp] Fetching metadata for ${groups.length} groups without names`);
    let fetched = 0;

    for (const group of groups) {
      try {
        const metadata = await this.sock.groupMetadata(group.jid);
        if (metadata.subject) {
          this.chats.set(group.jid, {
            ...group,
            name: metadata.subject,
            hasRealName: true,
          });
          console.log(`[WhatsApp] Fetched: ${group.jid} -> "${metadata.subject}"`);
          fetched++;
        }
      } catch (err) {
        console.log(`[WhatsApp] Could not fetch metadata for ${group.jid}: ${err.message}`);
      }
      // Small delay to avoid rate limiting
      await new Promise(resolve => setTimeout(resolve, 100));
    }

    return { fetched, total: groups.length };
  }

  async sendMessage(chatJid, text) {
    if (!this.sock || this.status !== 'connected') {
      throw new Error('Not connected');
    }

    await this.sock.sendMessage(chatJid, { text });
    return { success: true };
  }

  // Fetch metadata for specific JIDs (provided by caller)
  async fetchGroupNamesForJids(jids) {
    if (!this.sock || this.status !== 'connected') {
      return { fetched: 0, results: [], error: 'Not connected' };
    }

    const groupJids = jids.filter(jid => jid.endsWith('@g.us'));
    console.log(`[WhatsApp] Fetching metadata for ${groupJids.length} groups from provided JIDs`);

    const results = [];
    let fetched = 0;

    for (const jid of groupJids) {
      try {
        const metadata = await this.sock.groupMetadata(jid);
        if (metadata.subject) {
          // Update our local cache too
          this.chats.set(jid, {
            jid: jid,
            name: metadata.subject,
            hasRealName: true,
            type: 'group',
          });
          results.push({ jid, name: metadata.subject, success: true });
          console.log(`[WhatsApp] Fetched: ${jid} -> "${metadata.subject}"`);
          fetched++;
        } else {
          results.push({ jid, name: null, success: false, error: 'No subject' });
        }
      } catch (err) {
        console.log(`[WhatsApp] Could not fetch metadata for ${jid}: ${err.message}`);
        results.push({ jid, name: null, success: false, error: err.message });
      }
      // Small delay to avoid rate limiting
      await new Promise(resolve => setTimeout(resolve, 100));
    }

    return { fetched, total: groupJids.length, results };
  }
}

export default BaileysClient;
