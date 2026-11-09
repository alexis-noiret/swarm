#!/bin/bash
# ssh-harden.sh - SSH par clé uniquement (à lancer en root)
# Vérifier AVANT que la connexion par clé fonctionne : ssh -o PasswordAuthentication=no <hôte> hostname
set -e
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<CONF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 3
CONF
sshd -t
systemctl reload ssh
echo "SSH durci sur $(hostname)"
