#!/bin/bash
# healthcheck.sh - contrôle de santé du cluster Swarm (à lancer sur un manager)
NODES="192.168.109.10 192.168.109.11 192.168.109.12 192.168.109.13 192.168.109.14"
KO=0
ok() { printf "  [OK] %s\n" "$1"; }
ko() { printf "  [KO] %s\n" "$1"; KO=$((KO+1)); }

echo "== $(date '+%F %T') - Santé du cluster Swarm =="

echo "Nœuds"
if ! docker node ls >/dev/null 2>&1; then
  ko "cluster injoignable (perte de quorum ?)"
else
  while read -r name status avail role; do
    if [ "$status" = "Ready" ] && [ "$avail" = "Active" ]; then ok "$name ($role)"; else ko "$name status=$status disponibilité=$avail"; fi
  done < <(docker node ls --format '{{.Hostname}} {{.Status}} {{.Availability}} {{if .ManagerStatus}}{{.ManagerStatus}}{{else}}worker{{end}}')
  leaders=$(docker node ls --format '{{.ManagerStatus}}' | grep -c Leader)
  [ "$leaders" = "1" ] && ok "1 Leader" || ko "$leaders Leader(s)"
fi

echo "Services"
while read -r name rep; do
  if [ "${rep%/*}" = "${rep#*/}" ]; then ok "$name $rep"; else ko "$name $rep"; fi
done < <(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null)

echo "Site web (routing mesh sur chaque nœud)"
for ip in $NODES; do
  if curl -s -m 5 "http://$ip/" | grep -q "Base MariaDB : OK"; then ok "http://$ip (Nginx + PHP + MariaDB)"; else ko "http://$ip ne répond pas correctement"; fi
done

echo "Registry"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --cacert ~/swarm-private/ca.crt https://localhost:5000/v2/)
if [ "$code" = "401" ]; then ok "HTTPS actif, authentification exigée (401 sans identifiants)"; else ko "code HTTP inattendu : $code"; fi

echo "Sauvegardes"
newest=$(find /mnt/backups -maxdepth 1 -name 'dump-*.sql.gz' -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -1)
if [ -z "$newest" ]; then
  ko "aucun dump visible sur /mnt/backups (NFS monté ?)"
else
  age=$(( ( $(date +%s) - ${newest%%.*} ) / 60 ))
  if [ "$age" -lt 120 ]; then ok "dernier dump : ${newest#* } (il y a ${age} min)"; else ko "dernier dump trop ancien : ${newest#* } (il y a ${age} min, seuil : 120)"; fi
fi

echo
if [ "$KO" -eq 0 ]; then echo "=> Tout est OK"; else echo "=> $KO problème(s) détecté(s)"; fi
exit "$KO"
