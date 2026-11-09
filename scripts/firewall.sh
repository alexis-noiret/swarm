#!/bin/bash
# firewall.sh - pare-feu ufw selon le rôle de la VM (à lancer en root)
# Usage : sudo bash firewall.sh manager|worker|nfs
set -e
NET=192.168.109.0/24
ROLE=${1:?usage: firewall.sh manager|worker|nfs}

apt-get install -y ufw >/dev/null
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow from $NET to any port 22 proto tcp comment 'SSH'

case "$ROLE" in
  nfs)
    ufw allow from $NET to any port 2049 proto tcp comment 'NFSv4' ;;
  manager|worker)
    [ "$ROLE" = "manager" ] && ufw allow from $NET to any port 2377 proto tcp comment 'Swarm management'
    ufw allow from $NET to any port 7946 comment 'Swarm gossip'
    ufw allow from $NET to any port 4789 proto udp comment 'Swarm overlay VXLAN'
    ufw allow 80/tcp comment 'Nginx' ;;
  *)
    echo "rôle inconnu : $ROLE" >&2; exit 1 ;;
esac

ufw --force enable
ufw status verbose
