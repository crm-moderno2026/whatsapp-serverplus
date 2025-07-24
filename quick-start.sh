#!/bin/bash

# 🚀 Script de Início Rápido - Execute como root
# Este script baixa e executa a instalação completa

set -e

echo "🚀 WhatsApp Server - Instalação Rápida"
echo "====================================="
echo ""

# Verificar se é Ubuntu/Debian
if ! command -v apt &> /dev/null; then
    echo "❌ Este script é apenas para Ubuntu/Debian"
    exit 1
fi

# Baixar script principal
echo "📥 Baixando script de instalação..."
curl -fsSL https://raw.githubusercontent.com/seu-repo/whatsapp-server/main/install.sh -o /tmp/whatsapp-install.sh

# Dar permissão de execução
chmod +x /tmp/whatsapp-install.sh

# Executar instalação
echo "🚀 Iniciando instalação..."
bash /tmp/whatsapp-install.sh

# Limpar arquivo temporário
rm -f /tmp/whatsapp-install.sh

echo ""
echo "✅ Instalação rápida concluída!"
