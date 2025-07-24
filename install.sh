#!/bin/bash

# 🚀 Script de Instalação Automática do WhatsApp Server
# Para Ubuntu 20.04+ / Debian 11+

set -e

echo "🚀 Iniciando instalação do WhatsApp Server..."
echo "📋 Este script irá:"
echo "   - Instalar Node.js 18+"
echo "   - Instalar PM2"
echo "   - Configurar o servidor WhatsApp"
echo "   - Configurar Nginx (opcional)"
echo "   - Configurar SSL (opcional)"
echo ""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para log colorido
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Verificar se é root e criar usuário se necessário
if [[ $EUID -eq 0 ]]; then
   log_info "Executando como root - criando usuário whatsapp..."
   
   # Criar usuário whatsapp se não existir
   if ! id "whatsapp" &>/dev/null; then
       log_info "Criando usuário 'whatsapp'..."
       useradd -m -s /bin/bash whatsapp
       usermod -aG sudo whatsapp
       
       # Definir senha temporária
       echo "whatsapp:whatsapp123" | chpasswd
       log_warning "Senha temporária para usuário whatsapp: whatsapp123"
       log_warning "Altere a senha após a instalação!"
   fi
   
   # Continuar instalação como usuário whatsapp
   log_info "Continuando instalação como usuário whatsapp..."
   exec sudo -u whatsapp -H bash "$0" "$@"
fi

# A partir daqui, executa como usuário whatsapp
log_info "Executando como usuário: $(whoami)"

# Atualizar sistema
log_info "Atualizando sistema..."
sudo apt update && sudo apt upgrade -y

# Instalar dependências básicas
log_info "Instalando dependências básicas..."
sudo apt install -y curl wget git build-essential software-properties-common

# Instalar Node.js 18
log_info "Instalando Node.js 18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verificar instalação do Node.js
NODE_VERSION=$(node --version)
NPM_VERSION=$(npm --version)
log_success "Node.js instalado: $NODE_VERSION"
log_success "NPM instalado: $NPM_VERSION"

# Instalar PM2 globalmente
log_info "Instalando PM2..."
sudo npm install -g pm2

# Criar diretório do projeto
PROJECT_DIR="/home/whatsapp/whatsapp-server"
log_info "Criando diretório do projeto: $PROJECT_DIR"
mkdir -p $PROJECT_DIR
mkdir -p $PROJECT_DIR/{sessions,logs}

# Criar package.json
log_info "Criando package.json..."
cat > $PROJECT_DIR/package.json << 'EOF'
{
  "name": "whatsapp-server",
  "version": "1.0.0",
  "description": "Servidor dedicado para WhatsApp Baileys",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon server.js",
    "pm2:start": "pm2 start ecosystem.config.js",
    "pm2:stop": "pm2 stop whatsapp-server",
    "pm2:restart": "pm2 restart whatsapp-server",
    "pm2:logs": "pm2 logs whatsapp-server"
  },
  "dependencies": {
    "@whiskeysockets/baileys": "^6.7.8",
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "qrcode": "^1.5.3",
    "pino": "^8.17.2",
    "axios": "^1.6.0",
    "dotenv": "^16.3.1",
    "helmet": "^7.1.0",
    "express-rate-limit": "^7.1.5"
  },
  "devDependencies": {
    "nodemon": "^3.0.2"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
EOF

# Criar server.js
log_info "Criando server.js..."
cat > $PROJECT_DIR/server.js << 'EOF'
const express = require("express")
const cors = require("cors")
const helmet = require("helmet")
const rateLimit = require("express-rate-limit")
const makeWASocket = require("@whiskeysockets/baileys").default
const { useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } = require("@whiskeysockets/baileys")
const P = require("pino")
const QRCode = require("qrcode")
const axios = require("axios")
const fs = require("fs")
const path = require("path")
require("dotenv").config()

const app = express()
const PORT = process.env.PORT || 3001
const API_KEY = process.env.API_KEY || "whatsapp-server-2024"

// Configurar logger
const logger = P({
  level: process.env.LOG_LEVEL || "info",
  transport: {
    target: "pino-pretty",
    options: {
      colorize: true,
      translateTime: "SYS:standard",
    },
  },
})

// Middleware de segurança
app.use(helmet())
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS?.split(",") || "*",
  credentials: true,
}))

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutos
  max: 100, // máximo 100 requests por IP
  message: { error: "Muitas tentativas, tente novamente em 15 minutos" },
})
app.use(limiter)

app.use(express.json({ limit: "10mb" }))

// Criar diretórios necessários
const sessionsDir = path.join(__dirname, "sessions")
const logsDir = path.join(__dirname, "logs")

if (!fs.existsSync(sessionsDir)) {
  fs.mkdirSync(sessionsDir, { recursive: true })
}

if (!fs.existsSync(logsDir)) {
  fs.mkdirSync(logsDir, { recursive: true })
}

// WhatsApp Service
class WhatsAppServer {
  constructor() {
    this.clients = new Map()
    this.connectionAttempts = new Map()
    this.maxReconnectAttempts = 5
  }

  async startConnection(clientId, webhookUrl) {
    try {
      logger.info(`🚀 Iniciando conexão para cliente: ${clientId}`)

      // Limitar tentativas de reconexão
      const attempts = this.connectionAttempts.get(clientId) || 0
      if (attempts >= this.maxReconnectAttempts) {
        throw new Error(`Máximo de tentativas de reconexão excedido para ${clientId}`)
      }

      const sessionPath = path.join(sessionsDir, clientId)
      if (!fs.existsSync(sessionPath)) {
        fs.mkdirSync(sessionPath, { recursive: true })
      }

      const { state, saveCreds } = await useMultiFileAuthState(sessionPath)
      const { version } = await fetchLatestBaileysVersion()

      const sock = makeWASocket({
        version,
        auth: state,
        logger: P({ level: "silent" }),
        printQRInTerminal: false,
        browser: ["WhatsApp CRM", "Chrome", "1.0.0"],
        connectTimeoutMs: 60000,
        defaultQueryTimeoutMs: 60000,
        keepAliveIntervalMs: 30000,
        markOnlineOnConnect: true,
      })

      // Armazenar cliente
      this.clients.set(clientId, {
        sock,
        webhookUrl,
        isConnected: false,
        qrCode: "",
        lastSeen: new Date(),
        connectionState: "connecting",
      })

      // Event listeners
      sock.ev.on("connection.update", async (update) => {
        await this.handleConnectionUpdate(update, clientId, webhookUrl)
      })

      sock.ev.on("creds.update", saveCreds)

      sock.ev.on("messages.upsert", async (m) => {
        await this.handleIncomingMessages(m, clientId, webhookUrl)
      })

      // Resetar contador de tentativas em caso de sucesso
      this.connectionAttempts.set(clientId, 0)

      return { success: true }
    } catch (error) {
      logger.error(`❌ Erro ao iniciar conexão para ${clientId}:`, error)
      
      // Incrementar contador de tentativas
      const attempts = this.connectionAttempts.get(clientId) || 0
      this.connectionAttempts.set(clientId, attempts + 1)

      return { success: false, error: error.message }
    }
  }

  async handleConnectionUpdate(update, clientId, webhookUrl) {
    const { connection, lastDisconnect, qr } = update
    const client = this.clients.get(clientId)

    if (!client) return

    logger.info(`📡 Update para ${clientId}:`, { connection, hasQr: !!qr })

    if (qr) {
      try {
        const qrCode = await QRCode.toDataURL(qr, { 
          width: 300,
          margin: 2,
          color: {
            dark: "#000000",
            light: "#FFFFFF"
          }
        })

        client.qrCode = qrCode
        client.connectionState = "qr"

        if (webhookUrl) {
          await this.sendWebhook(webhookUrl, {
            type: "qr",
            clientId,
            qrCode,
            timestamp: new Date().toISOString(),
          })
        }

        logger.info(`✅ QR Code gerado para ${clientId}`)
      } catch (error) {
        logger.error(`❌ Erro ao gerar QR para ${clientId}:`, error)
      }
    }

    if (connection === "open") {
      client.isConnected = true
      client.qrCode = ""
      client.connectionState = "open"
      client.lastSeen = new Date()

      // Resetar tentativas de reconexão
      this.connectionAttempts.set(clientId, 0)

      if (webhookUrl) {
        await this.sendWebhook(webhookUrl, {
          type: "connection",
          clientId,
          isConnected: true,
          timestamp: new Date().toISOString(),
        })
      }

      logger.info(`✅ WhatsApp conectado para ${clientId}`)
    }

    if (connection === "close") {
      client.isConnected = false
      client.connectionState = "close"

      const shouldReconnect = lastDisconnect?.error?.output?.statusCode !== DisconnectReason.loggedOut
      const attempts = this.connectionAttempts.get(clientId) || 0

      if (shouldReconnect && attempts < this.maxReconnectAttempts) {
        logger.info(`🔄 Reconectando ${clientId} (tentativa ${attempts + 1}/${this.maxReconnectAttempts})...`)
        
        setTimeout(() => {
          this.startConnection(clientId, webhookUrl)
        }, Math.min(5000 * Math.pow(2, attempts), 30000)) // Backoff exponencial
      } else {
        logger.warn(`❌ Não reconectando ${clientId} - loggedOut ou máximo de tentativas`)
      }

      if (webhookUrl) {
        await this.sendWebhook(webhookUrl, {
          type: "connection",
          clientId,
          isConnected: false,
          reason: lastDisconnect?.error?.output?.statusCode,
          timestamp: new Date().toISOString(),
        })
      }
    }
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
              contactName: message.pushName || "Desconhecido",
              messageId: message.key.id,
              timestamp: new Date().toISOString(),
            })

            logger.info(`📨 Mensagem recebida de ${phoneNumber} para ${clientId}`)
          }
        } catch (error) {
          logger.error(`❌ Erro ao processar mensagem para ${clientId}:`, error)
        }
      }
    }
  }

  extractMessageText(message) {
    return (
      message.message?.conversation ||
      message.message?.extendedTextMessage?.text ||
      message.message?.imageMessage?.caption ||
      message.message?.videoMessage?.caption ||
      "[Mídia]"
    )
  }

  async sendWebhook(webhookUrl, data) {
    try {
      await axios.post(webhookUrl, data, {
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${API_KEY}`,
          "User-Agent": "WhatsApp-Server/1.0.0",
        },
        timeout: 10000,
      })
    } catch (error) {
      logger.error(`❌ Erro ao enviar webhook:`, error.message)
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
    
    logger.info(`📤 Mensagem enviada para ${phoneNumber} via ${clientId}`)
    
    return { success: true }
  }

  getClientStatus(clientId) {
    const client = this.clients.get(clientId)

    if (!client) {
      return {
        isConnected: false,
        qrCode: "",
        connectionState: "close",
        lastSeen: null,
      }
    }

    return {
      isConnected: client.isConnected,
      qrCode: client.qrCode,
      connectionState: client.connectionState,
      lastSeen: client.lastSeen,
    }
  }

  async disconnectClient(clientId) {
    const client = this.clients.get(clientId)
    
    if (client && client.sock) {
      try {
        await client.sock.logout()
        logger.info(`🔌 Cliente ${clientId} desconectado`)
      } catch (error) {
        logger.error(`❌ Erro ao desconectar ${clientId}:`, error)
      }
    }

    this.clients.delete(clientId)
    this.connectionAttempts.delete(clientId)
  }

  getServerStats() {
    const clients = Array.from(this.clients.entries()).map(([id, client]) => ({
      id,
      isConnected: client.isConnected,
      connectionState: client.connectionState,
      lastSeen: client.lastSeen,
    }))

    return {
      totalClients: this.clients.size,
      connectedClients: clients.filter(c => c.isConnected).length,
      clients,
      uptime: process.uptime(),
      memory: process.memoryUsage(),
      timestamp: new Date().toISOString(),
    }
  }
}

// Instância do serviço
const whatsappServer = new WhatsAppServer()

// Middleware de autenticação
const authenticate = (req, res, next) => {
  const authHeader = req.headers.authorization

  if (!authHeader || !authHeader.startsWith("Bearer ") || !authHeader.includes(API_KEY)) {
    return res.status(401).json({ error: "Unauthorized" })
  }

  next()
}

// Rotas da API
app.get("/", (req, res) => {
  res.json({
    name: "WhatsApp Server",
    version: "1.0.0",
    status: "online",
    timestamp: new Date().toISOString(),
  })
})

app.get("/api/health", (req, res) => {
  const stats = whatsappServer.getServerStats()
  res.json({
    success: true,
    ...stats,
  })
})

app.post("/api/whatsapp/connect", authenticate, async (req, res) => {
  try {
    const { clientId, webhook } = req.body

    if (!clientId) {
      return res.status(400).json({ error: "clientId é obrigatório" })
    }

    logger.info(`🔌 Tentativa de conexão para ${clientId}`)

    const result = await whatsappServer.startConnection(clientId, webhook)

    if (result.success) {
      // Aguardar um pouco para ver se QR é gerado
      setTimeout(() => {
        const status = whatsappServer.getClientStatus(clientId)
        res.json({
          success: true,
          qrCode: status.qrCode,
          isConnected: status.isConnected,
          connectionState: status.connectionState,
        })
      }, 3000)
    } else {
      res.status(500).json(result)
    }
  } catch (error) {
    logger.error("❌ Erro na rota connect:", error)
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
    logger.error("❌ Erro ao enviar mensagem:", error)
    res.status(500).json({ error: error.message })
  }
})

app.post("/api/whatsapp/disconnect", authenticate, async (req, res) => {
  try {
    const { clientId = "whatsapp-crm" } = req.body

    await whatsappServer.disconnectClient(clientId)

    res.json({ success: true })
  } catch (error) {
    logger.error("❌ Erro ao desconectar:", error)
    res.status(500).json({ error: error.message })
  }
})

app.get("/api/stats", authenticate, (req, res) => {
  const stats = whatsappServer.getServerStats()
  res.json(stats)
})

// Tratamento de erros global
app.use((error, req, res, next) => {
  logger.error("❌ Erro não tratado:", error)
  res.status(500).json({ error: "Erro interno do servidor" })
})

// Graceful shutdown
process.on("SIGTERM", async () => {
  logger.info("🛑 Recebido SIGTERM, desligando graciosamente...")
  
  // Desconectar todos os clientes
  for (const [clientId] of whatsappServer.clients) {
    await whatsappServer.disconnectClient(clientId)
  }
  
  process.exit(0)
})

process.on("SIGINT", async () => {
  logger.info("🛑 Recebido SIGINT, desligando graciosamente...")
  
  // Desconectar todos os clientes
  for (const [clientId] of whatsappServer.clients) {
    await whatsappServer.disconnectClient(clientId)
  }
  
  process.exit(0)
})

// Iniciar servidor
app.listen(PORT, "0.0.0.0", () => {
  logger.info(`🚀 WhatsApp Server rodando na porta ${PORT}`)
  logger.info(`🔑 API Key configurada`)
  logger.info(`📁 Sessões em: ${sessionsDir}`)
  logger.info(`📋 Logs em: ${logsDir}`)
})
EOF

# Criar arquivo de configuração do PM2
log_info "Criando configuração do PM2..."
cat > $PROJECT_DIR/ecosystem.config.js << 'EOF'
module.exports = {
  apps: [{
    name: 'whatsapp-server',
    script: 'server.js',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      PORT: 3001
    },
    error_file: './logs/err.log',
    out_file: './logs/out.log',
    log_file: './logs/combined.log',
    time: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    merge_logs: true,
    max_restarts: 10,
    min_uptime: '10s'
  }]
}
EOF

# Criar arquivo .env
log_info "Criando arquivo .env..."
API_KEY_GENERATED=$(openssl rand -hex 32 2>/dev/null || echo "whatsapp-$(date +%s)-$(shuf -i 1000-9999 -n 1)")
cat > $PROJECT_DIR/.env << EOF
# Configurações do Servidor WhatsApp
NODE_ENV=production
PORT=3001

# Chave de API (IMPORTANTE: Mantenha em segredo!)
API_KEY=$API_KEY_GENERATED

# Configurações de Log
LOG_LEVEL=info

# Origens permitidas (separadas por vírgula)
ALLOWED_ORIGINS=*

# Configurações de Rate Limiting
RATE_LIMIT_WINDOW_MS=900000
RATE_LIMIT_MAX_REQUESTS=100
EOF

# Instalar dependências
log_info "Instalando dependências do Node.js..."
cd $PROJECT_DIR
npm install

# Configurar PM2 para iniciar no boot
log_info "Configurando PM2 para iniciar no boot..."
sudo env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u whatsapp --hp /home/whatsapp

# Iniciar aplicação com PM2
log_info "Iniciando aplicação com PM2..."
pm2 start ecosystem.config.js
pm2 save

# Configurar firewall
log_info "Configurando firewall..."
sudo ufw allow 3001/tcp
sudo ufw allow ssh
sudo ufw --force enable

# Criar script de monitoramento
log_info "Criando script de monitoramento..."
cat > $PROJECT_DIR/monitor.sh << 'EOF'
#!/bin/bash

# Script de monitoramento do WhatsApp Server

echo "📊 Status do WhatsApp Server"
echo "=========================="

# Status do PM2
echo "🔄 Status PM2:"
pm2 status whatsapp-server

echo ""

# Status da aplicação
echo "🌐 Status da Aplicação:"
curl -s http://localhost:3001/api/health | python3 -m json.tool 2>/dev/null || echo "Aplicação não responde"

echo ""

# Uso de recursos
echo "💾 Uso de Recursos:"
echo "CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | awk -F'%' '{print $1}' || echo "N/A")"
echo "RAM: $(free -h | awk '/^Mem:/ {print $3 "/" $2}' || echo "N/A")"
echo "Disco: $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " usado)"}' || echo "N/A")"

echo ""

# Logs recentes
echo "📋 Logs Recentes:"
pm2 logs whatsapp-server --lines 5 --nostream
EOF

chmod +x $PROJECT_DIR/monitor.sh

# Criar script de backup
log_info "Criando script de backup..."
cat > $PROJECT_DIR/backup.sh << 'EOF'
#!/bin/bash

# Script de backup das sessões WhatsApp

BACKUP_DIR="/home/whatsapp/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="whatsapp_sessions_$DATE.tar.gz"

mkdir -p $BACKUP_DIR

echo "📦 Criando backup das sessões..."
tar -czf $BACKUP_DIR/$BACKUP_FILE -C /home/whatsapp/whatsapp-server sessions/

echo "✅ Backup criado: $BACKUP_DIR/$BACKUP_FILE"

# Manter apenas os 7 backups mais recentes
find $BACKUP_DIR -name "whatsapp_sessions_*.tar.gz" -type f -mtime +7 -delete

echo "🧹 Backups antigos removidos"
EOF

chmod +x $PROJECT_DIR/backup.sh

# Configurar cron para backup diário
log_info "Configurando backup automático..."
(crontab -l 2>/dev/null; echo "0 2 * * * /home/whatsapp/whatsapp-server/backup.sh >> /home/whatsapp/whatsapp-server/logs/backup.log 2>&1") | crontab -

# Aguardar um pouco para o servidor iniciar
log_info "Aguardando servidor iniciar..."
sleep 5

# Testar se o servidor está funcionando
log_info "Testando servidor..."
if curl -s http://localhost:3001/ > /dev/null; then
    log_success "Servidor está respondendo!"
else
    log_warning "Servidor pode não estar respondendo ainda. Verifique os logs."
fi

# Obter IP público
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "SEU-IP")

# Mostrar informações finais
echo ""
echo "🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "=================================="
echo ""
log_success "WhatsApp Server instalado e rodando!"
echo ""
echo "📋 INFORMAÇÕES IMPORTANTES:"
echo "   • Servidor rodando na porta: 3001"
echo "   • API Key: $API_KEY_GENERATED"
echo "   • Usuário: whatsapp"
echo "   • Diretório: $PROJECT_DIR"
echo "   • IP Público: $PUBLIC_IP"
echo ""
echo "🔧 COMANDOS ÚTEIS:"
echo "   • Ver status: pm2 status"
echo "   • Ver logs: pm2 logs whatsapp-server"
echo "   • Reiniciar: pm2 restart whatsapp-server"
echo "   • Monitorar: $PROJECT_DIR/monitor.sh"
echo "   • Backup: $PROJECT_DIR/backup.sh"
echo ""
echo "🌐 TESTE A INSTALAÇÃO:"
echo "   curl http://localhost:3001/api/health"
echo "   curl http://$PUBLIC_IP:3001/api/health"
echo ""
echo "⚙️  CONFIGURAR NO SEU CRM:"
echo "   WHATSAPP_SERVER_URL=http://$PUBLIC_IP:3001"
echo "   WHATSAPP_API_KEY=$API_KEY_GENERATED"
echo ""

log_warning "IMPORTANTE: Anote a API Key em local seguro!"
log_warning "Ela será necessária para conectar seu CRM ao servidor."

echo ""
log_info "Para ver o status atual, execute:"
echo "$PROJECT_DIR/monitor.sh"

# Perguntar sobre Nginx
echo ""
read -p "🌐 Deseja instalar e configurar Nginx como proxy reverso? (y/n): " install_nginx

if [[ $install_nginx =~ ^[Yy]$ ]]; then
    log_info "Instalando Nginx..."
    sudo apt install -y nginx
    
    # Configurar Nginx
    sudo tee /etc/nginx/sites-available/whatsapp-server > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

    # Ativar site
    sudo ln -sf /etc/nginx/sites-available/whatsapp-server /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Testar configuração
    sudo nginx -t
    
    # Reiniciar Nginx
    sudo systemctl restart nginx
    sudo systemctl enable nginx
    
    # Configurar firewall para HTTP
    sudo ufw allow 'Nginx Full'
    
    log_success "Nginx configurado com sucesso!"
    
    echo ""
    echo "🌍 NGINX CONFIGURADO:"
    echo "   • Acesse: http://$PUBLIC_IP/api/health"
    echo ""
    
    # Perguntar sobre SSL
    read -p "🔒 Deseja configurar SSL com Let's Encrypt? (y/n): " install_ssl
    
    if [[ $install_ssl =~ ^[Yy]$ ]]; then
        read -p "📝 Digite seu domínio (ex: whatsapp.seusite.com): " domain
        
        if [[ -n "$domain" ]]; then
            log_info "Instalando Certbot..."
            sudo apt install -y certbot python3-certbot-nginx
            
            log_info "Configurando SSL para $domain..."
            sudo certbot --nginx -d $domain --non-interactive --agree-tos --email admin@$domain --redirect
            
            log_success "SSL configurado para $domain!"
            
            echo ""
            echo "🔒 SSL CONFIGURADO:"
            echo "   • Acesse: https://$domain/api/health"
            echo ""
            echo "⚙️  CONFIGURAR NO SEU CRM:"
            echo "   WHATSAPP_SERVER_URL=https://$domain"
            echo "   WHATSAPP_API_KEY=$API_KEY_GENERATED"
        fi
    fi
fi

echo ""
log_success "🎉 Instalação finalizada! Execute '$PROJECT_DIR/monitor.sh' para ver o status."
