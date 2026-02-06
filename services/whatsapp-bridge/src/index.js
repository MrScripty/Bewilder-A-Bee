import express from 'express';
import BaileysClient from './baileys.js';
import createRoutes from './routes.js';

const PORT = process.env.WHATSAPP_BRIDGE_PORT || 3456;

async function main() {
  console.log('=================================');
  console.log('  WhatsApp Bridge for PumaBot');
  console.log('=================================\n');

  // Initialize Baileys client
  const client = new BaileysClient();
  await client.connect();

  // Initialize Express server
  const app = express();
  app.use(express.json());

  // Mount API routes
  app.use('/api', createRoutes(client));

  // Root endpoint with detailed status
  app.get('/', (req, res) => {
    const status = client.getStatus();
    res.json({
      name: 'WhatsApp Bridge',
      version: '1.0.0',
      status: status,
      endpoints: {
        status: 'GET /api/status',
        qr: 'GET /api/qr',
        chats: 'GET /api/chats',
        buffer: 'GET /api/messages/buffer',
        peek: 'GET /api/messages/peek',
        messages: 'GET /api/messages/:chatJid',
        send: 'POST /api/messages/send',
      },
      usage: {
        step1: 'Scan QR code when prompted',
        step2: 'Wait for history sync to complete',
        step3: 'Run: ./launcher.sh import',
      },
    });
  });

  // Start server
  app.listen(PORT, () => {
    console.log(`\n[Server] WhatsApp Bridge running on http://localhost:${PORT}`);
    console.log(`[Server] API: http://localhost:${PORT}/api/status`);
    console.log('\nWaiting for WhatsApp connection...');
    console.log('After connecting, history sync will begin automatically.\n');
  });
}

main().catch(console.error);
