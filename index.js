const express = require('express')
const { default: makeWASocket, DisconnectReason, useSingleFileAuthState } = require('@whiskeysockets/baileys')
const qrcode = require('qrcode-terminal')
const cors = require('cors')
const path = require('path')
const fs = require('fs')

const SESSION_FILE = path.resolve('./auth_info.json')

if (!fs.existsSync(SESSION_FILE)) {
  fs.writeFileSync(SESSION_FILE, JSON.stringify({}))
}

const { state, saveCreds } = useSingleFileAuthState(SESSION_FILE)

const app = express()
app.use(cors())
app.use(express.json())

let sock

async function startSock() {
  sock = makeWASocket({
    auth: state,
    printQRInTerminal: true,
  })

  sock.ev.on('connection.update', (update) => {
    const { connection, qr } = update
    if (qr) {
      qrcode.generate(qr, { small: true })
      console.log('QR Code gerado no terminal')
    }
    if (connection === 'close') {
      console.log('Conexão fechada, tentando reconectar...')
      startSock()
    }
    if (connection === 'open') {
      console.log('WhatsApp conectado!')
    }
  })

  sock.ev.on('creds.update', saveCreds)
}

startSock()

app.get('/', (req, res) => res.send('Servidor WhatsApp rodando.'))

app.post('/send-message', async (req, res) => {
  const { number, message } = req.body
  const jid = number.includes('@') ? number : `${number}@s.whatsapp.net`
  try {
    await sock.sendMessage(jid, { text: message })
    res.json({ success: true })
  } catch (err) {
    res.status(500).json({ success: false, error: err.message })
  }
})

const PORT = process.env.PORT || 3001
app.listen(PORT, () => console.log(`Servidor rodando na porta ${PORT}`))
