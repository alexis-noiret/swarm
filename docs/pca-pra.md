# 🔁 PCA / PRA

## Définitions

| Terme | Sens dans ce projet |
| --- | --- |
| **PCA** (Plan de Continuité d'Activité) | Le service continue de fonctionner pendant la panne, sans intervention : réplicas Nginx/PHP, recréation automatique des conteneurs, routing mesh |
| **PRA** (Plan de Reprise d'Activité) | Après un sinistre qui a détruit des données ou le cluster, on remet le service en état à partir de sauvegardes |
| **RTO** | Temps maximal pour rétablir le service |
| **RPO** | Quantité maximale de données qu'on accepte de perdre (liée à la fréquence des sauvegardes) |

## PCA : ce qui protège en continu

| Panne | Mécanisme | Effet mesuré |
| --- | --- | --- |
| Conteneur PHP ou Nginx | 2 réplicas, recréation automatique | aucune coupure |
| Conteneur MariaDB | recréation sur un autre worker, données sur le NFS | environ 5 s d'erreur, retour en moins de 30 s |
| Worker entier | replacement des tâches sur les autres workers | aucune coupure du site |
| Manager | le site continue (les workers n'ont pas besoin du manager pour servir) ; le pilotage du cluster est perdu jusqu'à la reprise | voir ci-dessous |

## PRA : sauvegardes

### Dumps MariaDB (automatiques)

Le service `ops_backup` (stack `ops`, [`stack/backup.yml`](../stack/backup.yml)) exécute en boucle :

1. un `mariadb-dump --single-transaction --all-databases` vers `/backups/dump-<date>.sql` ;
2. un contrôle que le fichier n'est pas vide, puis une compression gzip ;
3. en cas d'échec, une nouvelle tentative après 60 s (observé après un redémarrage du cluster) ;
4. la suppression des dumps de plus de 7 jours ;
5. une pause d'une heure.

Les dumps sont sur le NFS : `/srv/nfs/backups/dump-AAAA-MM-JJ_HHMMSS.sql.gz`. **RPO théorique : 1 heure.**

### État du cluster Swarm (manuel)

À faire après chaque changement important de topologie, sur un manager :

```bash
sudo systemctl stop docker
sudo tar czf swarm-state-$(date +%F).tar.gz -C /var/lib/docker swarm
sudo systemctl start docker
sudo chmod 600 swarm-state-*.tar.gz        # contient les clés de chiffrement des secrets
```

Copier ensuite l'archive hors du cluster (le NFS est un point de défaillance unique). Cette archive contient les secrets : ne jamais la versionner.

### Sauvegardes à conserver hors du cluster

| Élément | Où | Pourquoi |
| --- | --- | --- |
| Dumps MariaDB | `/srv/nfs/backups` (copier hors du NFS pour un vrai PRA) | restauration des données |
| Archive de l'état Swarm | idem | recréer le cluster et ses secrets |
| Autorité de certification (`ca.key`, `ca.crt`) | `~/swarm-private` sur manager1 | signer de nouveau les certificats de la registry |
| Fichiers de stack | ce dépôt Git | redéployer les services |

## Restauration de la base

Scénario testé : la base `app` est supprimée par erreur.

```bash
# 1. Sur le worker qui héberge swarm_db
DB=$(docker ps -q --filter name=swarm_db)
docker exec -i $DB sh -c 'mariadb -u root -p"$(cat /run/secrets/db_root_password)"' <<< "DROP DATABASE app;"    # la panne

# 2. Restauration depuis le dernier dump (monté depuis le NFS)
LAST=$(ls -1t /mnt/backups/dump-*.sql.gz | head -1)
docker exec -i $DB sh -c 'mariadb -u root -p"$(cat /run/secrets/db_root_password)" -e "CREATE DATABASE IF NOT EXISTS app"'
time (zcat "$LAST" | docker exec -i $DB sh -c 'mariadb -u root -p"$(cat /run/secrets/db_root_password)" --one-database app')

# 3. Vérification
curl -s http://192.168.109.11/ | grep -o "[0-9]* visites"
```

`/mnt/backups` désigne le montage NFS de `/srv/nfs/backups` sur le worker (`sudo mount -t nfs4 192.168.109.20:/srv/nfs/backups /mnt/backups`). L'option `--one-database` limite la restauration à la base `app`.

**Mesures** :

| Indicateur | Valeur |
| --- | --- |
| Panne simulée (`DROP DATABASE app`) | 09:07:53 |
| Service rétabli | 09:08:17 |
| **RTO** | environ **24 s** (manuel, dont la saisie des commandes) |
| Durée de l'import seul | 0,67 s |
| **RPO** | compteur à 14 570 avant la panne, 14 567 après : **3 visites perdues** (au plus 1 h en théorie) |

## Perte d'un manager

Avec **2 managers**, le quorum Raft exige 2 voix sur 2 : si l'un tombe, le cluster **ne peut plus être piloté** (`docker node ls` répond « The swarm does not have a leader »). Les services déjà lancés continuent de tourner : le site reste disponible (à interroger sur l'IP d'un worker ou du manager restant).

### Procédure de reprise

Sur le manager restant (ici manager2) :

```bash
docker swarm init --force-new-cluster --advertise-addr 192.168.109.13
docker node ls          # le manager restant est Leader, les services sont intacts
```

Mesure : **32 secondes** entre la commande et un cluster de nouveau opérationnel, services intacts.

### Réintégrer le manager perdu

```bash
# Sur le manager réparé (ancien nœud)
docker swarm leave --force

# Sur le Leader : supprimer l'ancienne entrée puis récupérer le jeton manager
docker node rm --force swarm-manager1
docker swarm join-token manager

# Sur le manager réparé : rejoindre
docker swarm join --token <JETON> 192.168.109.13:2377
```

Le manager réintégré reçoit un nouvel identifiant.

### Piège rencontré : le routing mesh du manager récupéré

Après le `--force-new-cluster`, le manager récupéré (manager2) ne répondait plus sur le port 80 : les paquets de son réseau overlay arrivaient bien sur les workers, mais ces derniers n'avaient pas son point d'entrée dans leur table VXLAN et ne pouvaient pas lui répondre. Ni le pare-feu ni la configuration n'étaient en cause.

Correctif : `sudo systemctl restart docker` sur ce manager (il se ré-annonce au cluster). Pendant ce redémarrage de 15 à 30 s, le cluster perd son quorum (2 managers), les services continuent de tourner.

**À retenir** : après un `--force-new-cluster`, tester le site sur chaque IP (`scripts/healthcheck.sh`) et redémarrer Docker sur le manager récupéré si besoin.

## Recommandations pour aller plus loin

- Passer à **3 managers** (tolère la perte d'un manager sans intervention).
- **MariaDB Galera** à 3 nœuds pour une vraie haute disponibilité de la base.
- Répliquer le NFS ou ses sauvegardes hors du cluster.
- Alertes automatiques à partir de `healthcheck.sh` (mail, webhook).
