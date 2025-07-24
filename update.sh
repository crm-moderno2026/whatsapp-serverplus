#!/bin/bash

# 🔄 Script de Atualização do WhatsApp Server

echo "🔄 Atualizando WhatsApp Server..."

PROJECT_DIR="/home/whatsapp/whatsapp-server"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ WhatsApp Server não encontrado!"
    echo "Execute primeiro: bash install.sh"
    exit 1
fi

cd $PROJECT_DIR

# Parar aplicação
echo "⏹️  Parando aplicação..."
sudo -u whatsapp pm2 stop whatsapp-server

# Backup das sessões
echo "📦 Fazendo backup das sessões..."
sudo -u whatsapp ./backup.sh

# Atualizar dependências
echo "📦 Atualizando dependências..."
sudo -u whatsapp npm update

# Reiniciar aplicação
echo "🚀 Reiniciando aplicação..."
sudo -u whatsapp pm2 restart whatsapp-server

echo "✅ Atualização concluída!"
