#!/bin/bash

# 🗑️ Script de Desinstalação do WhatsApp Server

echo "🗑️  DESINSTALAÇÃO DO WHATSAPP SERVER"
echo "==================================="

read -p "⚠️  Tem certeza que deseja desinstalar? (y/N): " confirm

if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo "❌ Desinstalação cancelada."
    exit 0
fi

# Parar e remover do PM2
echo "⏹️  Parando serviços..."
sudo -u whatsapp pm2 stop whatsapp-server 2>/dev/null || true
sudo -u whatsapp pm2 delete whatsapp-server 2>/dev/null || true
sudo -u whatsapp pm2 save

# Remover do startup
sudo pm2 unstartup systemd

# Remover arquivos
echo "🗑️  Removendo arquivos..."
sudo rm -rf /home/whatsapp/whatsapp-server
sudo rm -rf /home/whatsapp/backups

# Remover configuração do Nginx
if [ -f "/etc/nginx/sites-available/whatsapp-server" ]; then
    echo "🌐 Removendo configuração do Nginx..."
    sudo rm -f /etc/nginx/sites-available/whatsapp-server
    sudo rm -f /etc/nginx/sites-enabled/whatsapp-server
    sudo systemctl reload nginx
fi

# Remover regras do firewall
echo "🔥 Removendo regras do firewall..."
sudo ufw delete allow 3001/tcp 2>/dev/null || true

# Remover crontab
echo "⏰ Removendo tarefas agendadas..."
sudo -u whatsapp crontab -r 2>/dev/null || true

echo "✅ Desinstalação concluída!"
echo ""
echo "ℹ️  Para remover completamente:"
echo "   • sudo deluser whatsapp"
echo "   • sudo apt remove nodejs npm pm2"
