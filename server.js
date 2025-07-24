const express = require("express")
const cors = require("cors")
const makeWASocket = require("@whiskeysockets/baileys").default
const { useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } = require("@whiskeysockets/baileys")
const P = require("pino")
const QRCode = require("qrcode")
const axios = require("axios")
require("dotenv").config()

const app = express()
const PORT = process.env.PORT || 3001
const API_KEY = process.env.API_KEY || "default-key"

// Middleware
app.use(cors())
app.use(express.json())

// Logger
const logger = P({ level: "info" })

// WhatsApp Service
class WhatsAppServer {
  constructor() {
    this.sock = null
    this.qrCode = ""
    this.isConnected = false
    this.connectionState = "close"
    this.clients = new Map() // Para múltiplos clientes
  }

  async startConnection(clientId, webhookUrl) {
    try {
      console.log(`🚀 Iniciando conexão para cliente: ${clientId}`)

      // Usar diretório específico para cada cliente
      const sessionPath = `./sessions/${clientId}`

      const { state, saveCreds } = await useMultiFileAuthState(sessionPath)
      const { version } = await fetchLatestBaileysVersion()

      this.sock = makeWASocket({
        version,
        auth: state,
        logger: P({ level: "silent" }),
        printQRInTerminal: true,
        browser: ["WhatsApp Server", "Chrome", "1.0.0"],
        connectTimeoutMs: 60000,
        defaultQueryTimeoutMs: 60000,
      })

      // Event listeners
      this.sock.ev.on("connection.update", async (update) => {
        await this.handleConnectionUpdate(update, clientId, webhookUrl)
      })

      this.sock.ev.on("creds.update", saveCreds)

      this.sock.ev.on("messages.upsert", async (m) => {
        await this.handleIncomingMessages(m, clientId, webhookUrl)
      })

      // Armazenar cliente
      this.clients.set(clientId, {
        sock: this.sock,
        webhookUrl,
        isConnected: false,
        qrCode: "",
      })

      return { success: true }
    } catch (error) {
      console.error("❌ Erro ao iniciar conexão:", error)
      return { success: false, error: error.message }
    }
  }

  async handleConnectionUpdate(update, clientId, webhookUrl) {
    const { connection, lastDisconnect, qr } = update

    console.log(`📡 Update para ${clientId}:`, { connection, hasQr: !!qr })

    if (qr) {
      try {
        this.qrCode = await QRCode.toDataURL(qr, { width: 300 })

        // Atualizar cliente
        const client = this.clients.get(clientId)
        if (client) {
          client.qrCode = this.qrCode
        }

        // Enviar para webhook
        if (webhookUrl) {
          await this.sendWebhook(webhookUrl, {
            type: "qr",
            clientId,
            qrCode: this.qrCode,
          })
        }

        console.log("✅ QR Code gerado para", clientId)
      } catch (error) {
        console.error("❌ Erro ao gerar QR:", error)
      }
    }

    if (connection === "open") {
      this.isConnected = true

      const client = this.clients.get(clientId)
      if (client) {
        client.isConnected = true
        client.qrCode = ""
      }

      if (webhookUrl) {
        await this.sendWebhook(webhookUrl, {
          type: "connection",
          clientId,
          isConnected: true,
        })
      }

      console.log("✅ WhatsApp conectado para", clientId)
    }

    if (connection === "close") {
      this.isConnected = false

      const client = this.clients.get(clientId)
      if (client) {
        client.isConnected = false
      }

      const shouldReconnect = lastDisconnect?.error?.output?.statusCode !== DisconnectReason.loggedOut

      if (shouldReconnect) {
        console.log("🔄 Reconectando...", clientId)
        setTimeout(() => {
          this.startConnection(clientId, webhookUrl)
        }, 3000)
      }

      if (webhookUrl) {
        await this.sendWebhook(webhookUrl, {
          type: "connection",
          clientId,
          isConnected: false,
        })
      }
    }

    this.connectionState = connection || "close"
  }

  async handleIncomingMessages(m, clientId, webhookUrl) {
    for (const message of m.messages) {
      if (!message.key.fromMe && message.message) {
        try {
          const phoneNumber = message.key.remoteJid?.replace("@s.whatsapp.net", "")
          const messageText = this.extractMessageText(message)

          if (phoneNumber && messageText && webhookUrl) {
            await this.sendWebhook(webhookUrl, {
              type: "message",
              clientId,
              phoneNumber: `+${phoneNumber}`,
              message: messageText,
              isFromContact: true,
              contactName: message.pushName,
              messageId: message.key.id,
              timestamp: new Date().toISOString(),
            })
          }
        } catch (error) {
          console.error("❌ Erro ao processar mensagem:", error)
        }
      }
    }
  }

  extractMessageText(message) {
    return (
      message.message?.conversation ||
      message.message?.extendedTextMessage?.text ||
      message.message?.imageMessage?.caption ||
      ""
    )
  }

  async sendWebhook(webhookUrl, data) {
    try {
      await axios.post(webhookUrl, data, {
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${API_KEY}`,
        },
        timeout: 10000,
      })
    } catch (error) {
      console.error("❌ Erro ao enviar webhook:", error.message)
    }
  }

  async sendMessage(clientId, phoneNumber, message) {
    const client = this.clients.get(clientId)

    if (!client || !client.sock || !client.isConnected) {
      throw new Error("Cliente não conectado")
    }

    const formattedNumber = phoneNumber.replace(/\D/g, "")
    const jid = `${formattedNumber}@s.whatsapp.net`

    await client.sock.sendMessage(jid, { text: message })
    return { success: true }
  }

  getClientStatus(clientId) {
    const client = this.clients.get(clientId)

    if (!client) {
      return {
        isConnected: false,
        qrCode: "",
        connectionState: "close",
      }
    }

    return {
      isConnected: client.isConnected,
      qrCode: client.qrCode,
      connectionState: this.connectionState,
    }
  }
}

// Instância do serviço
const whatsappServer = new WhatsAppServer()

// Middleware de autenticação
const authenticate = (req, res, next) => {
  const authHeader = req.headers.authorization

  if (!authHeader || !authHeader.includes(API_KEY)) {
    return res.status(401).json({ error: "Unauthorized" })
  }

  next()
}

// Rotas da API
app.get("/api/health", (req, res) => {
  res.json({
    success: true,
    name: "WhatsApp Server",
    version: "1.0.0",
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
  })
})

app.post("/api/whatsapp/connect", authenticate, async (req, res) => {
  try {
    const { clientId, webhook } = req.body

    if (!clientId) {
      return res.status(400).json({ error: "clientId é obrigatório" })
    }

    const result = await whatsappServer.startConnection(clientId, webhook)

    if (result.success) {
      // Aguardar um pouco para ver se QR é gerado
      setTimeout(() => {
        const status = whatsappServer.getClientStatus(clientId)
        res.json({
          success: true,
          qrCode: status.qrCode,
          isConnected: status.isConnected,
        })
      }, 2000)
    } else {
      res.status(500).json(result)
    }
  } catch (error) {
    res.status(500).json({ error: error.message })
  }
})

app.get("/api/whatsapp/status", authenticate, (req, res) => {
  const clientId = req.query.clientId || "whatsapp-crm"
  const status = whatsappServer.getClientStatus(clientId)

  res.json(status)
})

app.post("/api/whatsapp/send", authenticate, async (req, res) => {
  try {
    const { clientId = "whatsapp-crm", phoneNumber, message } = req.body

    if (!phoneNumber || !message) {
      return res.status(400).json({ error: "phoneNumber e message são obrigatórios" })
    }

    const result = await whatsappServer.sendMessage(clientId, phoneNumber, message)
    res.json(result)
  } catch (error) {
    res.status(500).json({ error: error.message })
  }
})

app.post("/api/whatsapp/disconnect", authenticate, async (req, res) => {
  try {
    const { clientId = "whatsapp-crm" } = req.body

    const client = whatsappServer.clients.get(clientId)
    if (client && client.sock) {
      await client.sock.logout()
      whatsappServer.clients.delete(clientId)
    }

    res.json({ success: true })
  } catch (error) {
    res.status(500).json({ error: error.message })
  }
})

// Iniciar servidor
app.listen(PORT, () => {
  console.log(`🚀 WhatsApp Server rodando na porta ${PORT}`)
  console.log(`🔑 API Key: ${API_KEY}`)
})
