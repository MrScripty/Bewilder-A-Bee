import { Router } from 'express';

export default function createRoutes(client) {
  const router = Router();

  // Health check / status
  router.get('/status', (req, res) => {
    res.json(client.getStatus());
  });

  // Get QR code for authentication
  router.get('/qr', (req, res) => {
    const qr = client.getQRCode();
    if (qr) {
      res.json({ qr, status: 'waiting_for_scan' });
    } else if (client.getStatus().connected) {
      res.json({ qr: null, status: 'already_connected' });
    } else {
      res.json({ qr: null, status: 'no_qr_available' });
    }
  });

  // Get list of chats
  router.get('/chats', async (req, res) => {
    try {
      const chats = await client.getChats();
      const withNames = chats.filter(c => c.hasRealName);
      res.json({
        chats,
        count: chats.length,
        with_names: withNames.length,
      });
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  // Fetch missing group names from WhatsApp (for groups in bridge's cache)
  router.post('/chats/fetch-names', async (req, res) => {
    try {
      const result = await client.fetchMissingGroupNames();
      res.json(result);
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  // Fetch group names for specific JIDs (provided by caller)
  router.post('/chats/fetch-names-for-jids', async (req, res) => {
    const { jids } = req.body;

    if (!jids || !Array.isArray(jids)) {
      return res.status(400).json({ error: 'jids array is required' });
    }

    try {
      const result = await client.fetchGroupNamesForJids(jids);
      res.json(result);
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  // Get buffered messages (clears buffer after fetch)
  router.get('/messages/buffer', (req, res) => {
    const clear = req.query.clear !== 'false';
    const messages = client.getBufferedMessages(clear);
    res.json({
      messages,
      count: messages.length,
      cleared: clear,
    });
  });

  // Peek at buffered messages (doesn't clear)
  router.get('/messages/peek', (req, res) => {
    const messages = client.peekBufferedMessages();
    res.json({
      messages,
      count: messages.length,
    });
  });

  // Fetch messages from a specific chat (from store)
  router.get('/messages/:chatJid', async (req, res) => {
    const { chatJid } = req.params;
    const limit = parseInt(req.query.limit) || 100;

    try {
      const messages = await client.fetchMessagesFromChat(decodeURIComponent(chatJid), limit);
      res.json({ messages, count: messages.length });
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  // Send a message
  router.post('/messages/send', async (req, res) => {
    const { chat_jid, text } = req.body;

    if (!chat_jid || !text) {
      return res.status(400).json({ error: 'chat_jid and text are required' });
    }

    try {
      const result = await client.sendMessage(chat_jid, text);
      res.json(result);
    } catch (err) {
      res.status(500).json({ error: err.message });
    }
  });

  return router;
}
