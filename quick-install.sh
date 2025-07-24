#!/bin/bash

# 🚀 Instalação Rápida - Uma linha só!
# curl -fsSL https://raw.githubusercontent.com/seu-repo/whatsapp-server/main/quick-install.sh | bash

echo "🚀 INSTALAÇÃO RÁPIDA DO WHATSAPP SERVER"
echo "======================================"

# Download e execução do script principal
curl -fsSL https://raw.githubusercontent.com/seu-repo/whatsapp-server/main/install.sh -o /tmp/whatsapp-install.sh
chmod +x /tmp/whatsapp-install.sh
bash /tmp/whatsapp-install.sh

# Limpar arquivo temporário
rm -f /tmp/whatsapp-install.sh
