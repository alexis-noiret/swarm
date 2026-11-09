# 🐝 Docker Swarm pour la Résilience

![Docker Swarm](https://img.shields.io/badge/Docker-Swarm-2496ED?logo=docker&logoColor=white)
![Debian 13](https://img.shields.io/badge/Debian-13_trixie-A81D33?logo=debian&logoColor=white)
![VMware](https://img.shields.io/badge/VMware-Workstation-607078?logo=vmware&logoColor=white)
![Projet](https://img.shields.io/badge/Projet-La_Plateforme-6e40c9)
![Focus](https://img.shields.io/badge/Focus-PCA_%2F_PRA-2ea44f)

> Un cluster Docker Swarm de 5 nœuds (2 managers, 3 workers) sur des VM Debian, avec cinq services conteneurisés, un Plan de Continuité d'Activité (PCA) testé et un Plan de Reprise d'Activité (PRA) chronométré.

## 🖥️ Environnement

| Élément | Valeur |
| --- | --- |
| Hyperviseur | VMware Workstation, réseau NAT `192.168.109.0/24` |
| Système | Debian 13 (trixie), 6 VM |
| Docker | 29.9.2 (Swarm mode) |
| Stockage partagé | NFSv4 sur une VM dédiée |
| Accès | SSH par clé uniquement, depuis le poste de travail |

| VM | IP | Rôle |
| --- | --- | --- |
| swarm-manager1 | 192.168.109.10 | manager |
| swarm-manager2 | 192.168.109.13 | manager |
| swarm-worker1 | 192.168.109.11 | worker |
| swarm-worker2 | 192.168.109.12 | worker |
| swarm-worker3 | 192.168.109.14 | worker |
| swarm-nfs | 192.168.109.20 | serveur NFS (données persistantes et sauvegardes) |

## 📑 Sommaire

1. [Architecture](#-architecture)
2. [Les 5 services](#-les-5-services)
3. [Démarrage rapide](#-démarrage-rapide)
4. [Tests de résilience](#-tests-de-résilience)
5. [PCA / PRA](#-pca--pra)
6. [Sécurité](#-sécurité)
7. [Supervision](#-supervision)
8. [Limites assumées](#-limites-assumées)
9. [Structure du dépôt](#-structure-du-dépôt)
10. [Compétences démontrées](#-compétences-démontrées)
11. [Auteur](#-auteur)

## 🏗️ Architecture

```
                 Poste de travail (SSH par clé)
                            │
        ┌───────────────────┼───────────────────┐
        │        Réseau NAT 192.168.109.0/24    │
        │                                       │
  ┌─────┴──────┐  ┌────────────┐   ┌───────────┴──────────────────────┐
  │ manager1   │  │ manager2   │   │ worker1   worker2   worker3      │
  │ .10        │  │ .13        │   │ .11       .12       .14          │
  │ (Raft)     │  │ (Raft)     │   │ nginx x2 · php x2 · mariadb      │
  └────────────┘  └────────────┘   │ registry · code-server · backup  │
                                   └───────────────┬──────────────────┘
                                                   │ NFSv4
                                            ┌──────┴──────┐
                                            │ swarm-nfs   │
                                            │ .20         │
                                            │ mariadb/    │
                                            │ registry/   │
                                            │ www/ code/  │
                                            │ backups/    │
                                            └─────────────┘
```

- Les **managers** gèrent l'état du cluster (consensus Raft) et ne portent aucun service applicatif.
- Les **workers** exécutent les conteneurs. Swarm les replace tout seul sur un autre worker si l'un tombe.
- Toutes les **données** (base, registry, code, sauvegardes) vivent sur le NFS : un conteneur relancé ailleurs retrouve ses données.
- Le **routing mesh** permet d'interroger le site sur l'IP de n'importe quel nœud.

## 🧩 Les 5 services

| Service demandé | Service Swarm | Détails |
| --- | --- | --- |
| Registry interne | `infra_registry` | `registry:2`, HTTPS avec certificat signé par une CA locale, authentification htpasswd, données sur NFS |
| MariaDB | `swarm_db` | `mariadb:11`, 1 réplica, données sur NFS, mots de passe via secrets Swarm |
| PHP | `swarm_php` | 2 réplicas, image `php:8.3-fpm-alpine` + `pdo_mysql`, construite et servie depuis la registry interne |
| Nginx | `swarm_nginx` | 2 réplicas, port 80, serveur web et proxy FastCGI vers `php:9000` |
| VSCode Server | `dev_code` | `code-server`, port 8443, mot de passe via secret Swarm |

Service complémentaire : `ops_backup` réalise un dump MariaDB compressé toutes les heures vers le NFS.

## 🚀 Démarrage rapide

Le détail pas à pas est dans [`docs/installation.md`](docs/installation.md). En résumé, depuis `swarm-manager1` :

```bash
# 1. Initialiser le cluster
docker swarm init --advertise-addr 192.168.109.10

# 2. Créer les secrets (voir docs/installation.md)
# 3. Déployer les stacks
docker stack deploy -c stack/registry.yml infra
docker stack deploy --with-registry-auth -c stack/docker-stack.yml swarm
docker stack deploy -c stack/code.yml dev
docker stack deploy -c stack/backup.yml ops

# 4. Vérifier
scripts/healthcheck.sh
```

Aucun secret n'est stocké dans ce dépôt : mots de passe, clés et certificats sont créés sur le cluster et exclus par le `.gitignore`.

## 🧪 Tests de résilience

Résultats mesurés, détaillés dans [`docs/tests.md`](docs/tests.md) :

| Test | Scénario | Résultat |
| --- | --- | --- |
| 1 | Perte d'un conteneur PHP (`docker kill`) | Recréé sur un autre worker en 4 à 6 s, site disponible |
| 2 | Perte du conteneur MariaDB | Indisponibilité d'environ 5 s côté appli, retour complet en moins de 30 s, aucune donnée perdue |
| 3 | Coupure brutale d'un worker entier | Services recréés sur les autres workers, site disponible |
| 4 | Perte d'un manager | Site disponible, cluster récupéré en 32 s avec `--force-new-cluster` |

## 🔁 PCA / PRA

| Indicateur | Valeur mesurée |
| --- | --- |
| **PCA** (continuité) | Web : continuité assurée par 2 réplicas Nginx/PHP et le routing mesh. Base : relance automatique en moins de 30 s |
| **PRA** (reprise) | Sauvegarde horaire des bases, restauration testée après un `DROP DATABASE` |
| **RTO** (temps de reprise) | environ 24 s (restauration manuelle) |
| **RPO** (perte de données) | 3 visites perdues lors du test ; 1 heure au maximum en théorie (fréquence des dumps) |
| Sauvegarde de l'état Swarm | archive de `/var/lib/docker/swarm` conservée sur le NFS |

Procédures complètes : [`docs/pca-pra.md`](docs/pca-pra.md).

## 🔒 Sécurité

- **Registry** en HTTPS (CA locale) avec authentification ; les workers reçoivent les identifiants avec `--with-registry-auth`.
- **Secrets Swarm** pour tous les mots de passe (base, code-server) : montés dans `/run/secrets`, jamais en variable d'environnement ni dans Git.
- **Pare-feu `ufw`** sur chaque VM, en refus par défaut : seuls les ports Swarm utiles et NFS sont ouverts, restreints au sous-réseau.
- **SSH** par clé uniquement, connexion root et mots de passe désactivés.
- Moindre privilège : 2377/tcp (gestion du cluster) n'est ouvert que sur les managers.

## 📊 Supervision

[`scripts/healthcheck.sh`](scripts/healthcheck.sh) vérifie en une commande l'état des nœuds, des services, du site sur chaque IP, de la registry et de la fraîcheur des sauvegardes. La fraîcheur des sauvegardes est lue directement sur le NFS (montage en lecture seule). Il tourne toutes les 5 minutes via `cron` et écrit dans un journal.

## ⚠️ Limites assumées

- **MariaDB** n'est pas en haute disponibilité au sens strict : un seul réplica, relancé automatiquement ailleurs (basculement). Un cluster Galera à 3 nœuds serait l'étape suivante.
- **Deux managers** ne tolèrent aucune panne sans intervention (le quorum Raft exige la majorité) : trois managers sont recommandés en production.
- Le **serveur NFS** est un point de défaillance unique.
- La **registry** utilise une CA auto-signée (laboratoire) et le mot de passe de connexion est stocké en clair dans `~/.docker/config.json` du manager.
- Docker publie les ports 80, 5000 et 8443 en contournant `ufw` ; en production, on filtrerait via la chaîne `DOCKER-USER`.
- La supervision tourne sur un seul manager et n'envoie pas d'alertes.

## 📁 Structure du dépôt

```
swarm/
├── README.md
├── .gitignore
├── stack/
│   ├── registry.yml        # stack infra : registry HTTPS + auth
│   ├── docker-stack.yml    # stack swarm : MariaDB, PHP, Nginx
│   ├── code.yml            # stack dev : VSCode Server
│   ├── backup.yml          # stack ops : dump horaire
│   ├── nginx/default.conf
│   └── php/Dockerfile
├── app/index.php           # page de test (PHP + MariaDB)
├── scripts/
│   ├── healthcheck.sh      # supervision du cluster
│   ├── firewall.sh         # ufw par rôle (manager|worker|nfs)
│   └── ssh-harden.sh       # SSH par clé uniquement
└── docs/
    ├── installation.md
    ├── tests.md
    └── pca-pra.md
```

## 🎓 Compétences démontrées

- **Orchestration** : déployer et exploiter un cluster Docker Swarm multi-nœuds (managers, workers, overlay, stacks, secrets, contraintes de placement).
- **Conteneurisation** : construire une image applicative, la publier dans une registry interne et la déployer depuis celle-ci.
- **Haute disponibilité** : répliquer les services, comprendre le quorum Raft et le routing mesh, assumer les limites d'une base en basculement.
- **Continuité et reprise** : concevoir, tester et chronométrer un PCA/PRA (RTO, RPO, sauvegardes, restauration, reconstruction d'un cluster).
- **Sécurité** : TLS et authentification, secrets, pare-feu au moindre privilège, durcissement SSH.
- **Supervision et documentation** : contrôle de santé automatisé, procédures de test écrites et reproductibles.

## 👤 Auteur

**Alexis Noiret** — Bachelor IT Cybersécurité, La Plateforme

- 🌐 Portfolio : [alexis-noiret.students-laplateforme.io](https://alexis-noiret.students-laplateforme.io)
- 🐙 GitHub : [github.com/alexis-noiret](https://github.com/alexis-noiret)
