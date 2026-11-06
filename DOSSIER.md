# Dossier — Durcissement du serveur de *Chiffres & Co* (contexte B)

Groupe : Hugo, Ilyes, Camille — XTI302-CYB

Serveur : Debian 13 (`srv-xti`), installation minimale + serveur SSH, second disque de 2 Go pour les sauvegardes, carte réseau en accès par pont.
État vérifié par `verifier.sh` : **105 / 105 tests réussis**.

> **Références ANSSI.** La colonne « Référence ANSSI » ci-dessous renvoie aux **thèmes** du guide ANSSI‑BP‑028 *Recommandations de configuration d'un système GNU/Linux* (v2.0) et du guide *Usage sécurisé d'(Open)SSH*. **Avant le rendu, reportez les numéros exacts de recommandation (Rxx) depuis les PDF officiels** (liens en fin de dossier) : les numéros changent entre les versions du guide, nous ne les inventons pas ici.

## 1. Tableau de conformité

| ID | Ce qui est fait | Test(s) de `verifier.sh` | Thème ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv`, crée les groupes et les comptes (ou les remet en conformité) ; idempotent. | `test_C1_csv`, `test_C1_comptes`, `test_C1_groupes_metier`, `test_C1_doublons`, `test_C1_hors_csv` | Gestion des comptes et des groupes |
| C2 | Répertoires `/srv` en `root:root`, droits par **ACL** nommées et **ACL par défaut** ; `depot` en 1770 (sticky). | `test_C2_structure`, `test_C2_droits` (16 cas), `test_C2_heritage`, `test_C2_depot` | Droits d'accès au système de fichiers |
| C3 | `/etc/sudoers.d/projet` : `admins` tout, `support` uniquement `analyse_logs.sh` ; groupe `sudo` vidé. | `test_C3_fichier`, `test_C3_admins`, `test_C3_support`, `test_C3_personne_d_autre` | Comptes d'administration, `sudo`, moindre privilège |
| C4 | `passwd -l root` (en dernier) ; répertoires personnels en 0700 ; `HOME_MODE 0700`. | `test_C4_root`, `test_C4_maisons`, `test_C4_lecture` | Cloisonnement des comptes, compte root |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`. | `test_S1` (`sshd -T` + essai réel par mot de passe) | (Open)SSH : authentification par clé |
| S2 | `PermitRootLogin no`. | `test_S2` | (Open)SSH : interdiction de la connexion root |
| S3 | `AllowGroups acces_ssh` ; clés installées par `creer_comptes.sh`. | `test_S3`, `test_S3_cles` | (Open)SSH : restriction des utilisateurs |
| S4 | `MaxAuthTries 3`, `ClientAliveInterval 300` × `ClientAliveCountMax 2`, `TMOUT 600`. | `test_S4` | (Open)SSH / expiration des sessions |
| S5 | Config dans `sshd_config.d/`, validée par `sshd -t` avant rechargement ; retour arrière si erreur. | `test_S5` | (Open)SSH : organisation de la configuration |
| J1 | fail2ban (backend systemd, action nftables) : 3 échecs / 10 min → ban 15 min. | `test_J1`, `test_J1_J2_cohabitation` | Réaction aux tentatives d'intrusion |
| J2 | nftables : entrée et transfert en `drop`, seuls `lo`, connexions établies, NDP et tcp/22 acceptés ; service activé. | `test_J2` | Filtrage réseau local (pare-feu hôte) |
| J3 | `Storage=persistent` (journald) + `/var/log/journal`. | `test_J3` | Journalisation persistante |
| J4 | `analyse_logs.sh` : rapport SSH + code de sortie (0/1/2) et seuil d'alerte. | `test_J4` | Journalisation et supervision |
| B1 | `sauvegarde.sh` : `rsync -aAXH --link-dest`, versions datées, ≥ 7 gardées ; disque ext4 « SAUVEGARDES ». | `test_B1_disque`, `test_B1_versions` | Sauvegarde (hors périmètre détaillé du guide) |
| B2 | `sauvegarde.timer` quotidien (`Persistent=true`), journalisé. | `test_B2` | — |
| B3 | `/sauvegardes` en `root:admins` 0750. | `test_B3` | Droits d'accès au système de fichiers |
| B4 | Restauration testée (voir section 4) ; `verifier.sh` la rejoue sur `/srv/commun`. | `test_B4` | — |
| D1 | `unattended-upgrades` + `20auto-upgrades` (origine Debian‑Security). | `test_D1` | Mises à jour de sécurité |
| D2 | `ss -tulpn` : seul SSH est joignable (voir 2.6). | `test_D2` | Réduction de la surface d'attaque / services |
| D3 | Aucun fichier modifiable par tous hors des répertoires temporaires ; SUID listés et expliqués (2.7). | `test_D3` | Fichiers `setuid`/`setgid`, droits sensibles |

## 2. Choix techniques

### 2.1 Comptes et droits

- **Répertoires personnels en 0700, pas 0750.** Les groupes principaux sont partagés (`comptables`, `rh`…) ; en 0750, un comptable pourrait lire le dossier personnel de son collègue. `test_C4_lecture` vérifie le contraire.
- **ACL `g::---`.** Un fichier appartient au groupe principal de son créateur ; avec `g::---`, aucun droit ne passe par ce groupe, seules les entrées nommées comptent. Indispensable pour `depot` : un fichier déposé par un stagiaire appartient au groupe `stagiaire`, et les autres stagiaires ne doivent pas pouvoir le lire.
- **« Dépôt seul » des stagiaires :** `g:stagiaire:-wx` sur `depot` (créer et traverser, mais pas lister) ; aucune entrée `stagiaire` dans l'ACL par défaut (un dépôt n'est lisible que par son auteur et les trois autres groupes) ; **sticky bit** (un stagiaire ne peut pas supprimer le fichier d'un autre).
- **Mots de passe :** aucun dans `comptes.csv`. Les administrateurs reçoivent un mot de passe provisoire (changement forcé via `chage -d 0`) nécessaire à `sudo` et à la console de secours une fois root verrouillé. Les comptes métier n'ont ni mot de passe ni accès SSH : ils servent à tester les droits.
- **`support` en `NOPASSWD`** : une seule commande, chemin absolu, script appartenant à root en 0755 ; s'il pouvait modifier le script, il obtiendrait un shell root (cf. GTFOBins).
- **Root verrouillé en dernier**, et seulement si un administrateur a un mot de passe (sinon plus aucun accès d'administration).

### 2.2 SSH

| Option | Valeur | Justification |
|---|---|---|
| `MaxAuthTries` | 3 | Une personne légitime a une clé : un essai suffit. |
| `LoginGraceTime` | 30 s | Limite les connexions ouvertes sans authentification. |
| `ClientAliveInterval` × `ClientAliveCountMax` | 300 × 2 = 10 min | Ferme les sessions dont le client ne répond plus. |
| `TMOUT` (profile.d, lecture seule) | 600 s | Ferme un shell interactif sans frappe pendant 10 min (ce que `ClientAlive` ne couvre pas). |
| Fichier `01-durcissement.conf` | — | Pour sshd, la **première** valeur lue l'emporte : notre fichier est lu avant les autres. |

### 2.3 fail2ban et nftables

- **fail2ban** : 3 échecs en 10 min → 15 min de ban. Contre un robot, l'attaque est réduite à quelques essais par quart d'heure. La boucle locale est exclue (tests de `verifier.sh`) ; l'hôte **n'est pas** exclu, pour la démonstration. Débannir : `fail2ban-client set sshd unbanip <IP>`. `backend = systemd` car Debian 13 n'a pas `/var/log/auth.log`.
- **nftables** : entrée et transfert en `drop`, sortie en `accept` ; NDP IPv6 autorisé (sinon IPv6 cesse de fonctionner) ; le ping n'est pas ouvert.
- **Cohabitation** : un `flush ruleset` effacerait la table de fail2ban. Notre fichier ne recrée que la table `inet filtre` ; une surcharge systemd remplace l'`ExecStop` de Debian ; `installer.sh` utilise `reload`.

### 2.4 Journal et analyse

- **Journal** : `Storage=persistent`, plafonné à 300 Mo et 180 jours.
- **Seuil d'`analyse_logs.sh`** : 10 échecs d'une même IP en 24 h. fail2ban bannit déjà à 3 ; atteindre 10 signifie une adresse qui revient après ses bannissements, donc une attaque persistante. Réglable par `-s`.

### 2.5 Sauvegarde

- **Rotation** : 14 versions quotidiennes (≥ 7 demandé). Grâce à `--link-dest`, une version sans changement ne coûte presque rien.
- **Planification** : `OnCalendar=02:00`, `Persistent=true` (rattrapage si la VM était éteinte).
- **Robustesse** : écriture dans `.encours` puis renommage (jamais de version incomplète prise pour complète) ; verrou `flock` ; refus si le disque n'est pas monté.
- **Disque préparé une seule fois** : `installer.sh` ne touche pas un disque déjà étiqueté `SAUVEGARDES` ou non vierge ; monté `nodev,nosuid,noexec,nofail`.
- **Ordre dans `installer.sh`** : la toute **première** sauvegarde est lancée *à la fin* de l'installation (fonction `premiere_sauvegarde`), après le durcissement SSH et le pare-feu, pour qu'elle contienne déjà la configuration complète. Les sauvegardes suivantes sont quotidiennes.

### 2.6 D2 — écoutes réseau (`ss -tulpn` réel)

| Écoute | Justification |
|---|---|
| `tcp 0.0.0.0:22` et `[::]:22` — `sshd` | Le seul service attendu. |
| `udp :68` (IPv4) et `udp :546` (IPv6) — client DHCP | Client qui **reçoit** l'adresse du réseau ; n'offre aucun service, et nftables ne laisse entrer que les réponses. |

Aucune autre écoute : aucun service accessible depuis le réseau en dehors de SSH.

### 2.7 D3 — fichiers SUID présents (liste réelle, 11 fichiers)

`find / -xdev -type f -perm -4000` sur la VM durcie donne exactement la liste de `config/suid_attendus.txt` :

| Fichier | Rôle (pourquoi SUID) |
|---|---|
| `/usr/bin/passwd`, `/usr/bin/chfn`, `/usr/bin/chsh` | Modifier son mot de passe / ses informations dans `/etc/shadow` et `/etc/passwd`. |
| `/usr/bin/gpasswd`, `/usr/bin/newgrp` | Gestion et changement de groupe. |
| `/usr/bin/su` | Changer d'identité après authentification. |
| `/usr/bin/sudo` | Élévation contrôlée par `/etc/sudoers`. |
| `/usr/bin/mount`, `/usr/bin/umount` | Montages autorisés dans `/etc/fstab`. |
| `/usr/lib/dbus-1.0/dbus-daemon-launch-helper` | Démarrage de services D‑Bus système. |
| `/usr/lib/openssh/ssh-keysign` | Authentification « hostbased » d'OpenSSH (inutilisée ici). |

Piste bonus (ANSSI, réduction des binaires privilégiés) : retirer le bit SUID de `chfn`, `chsh`, `newgrp` et `ssh-keysign`, non utilisés dans ce contexte, et ajouter un test dans `verifier.sh`.

## 3. Défense

| Attaque | Ce que notre configuration rend plus difficile |
|---|---|
| **Force brute SSH** | Aucun mot de passe accepté en SSH (S1) : rien à deviner. 3 essais par connexion (S4). Ban après 3 échecs (J1). Alerte d'`analyse_logs.sh` au-delà de 10 échecs. |
| **Vol d'un mot de passe** | Inutile pour se connecter à distance : il faut la clé privée. Le mot de passe d'un administrateur ne sert qu'à `sudo` une fois connecté, ou en console. |
| **Utilisateur curieux** | Répertoires personnels en 0700 ; ACL de `/srv` limitant chaque groupe à son besoin (un RH ne voit pas les dossiers clients) ; droits appliqués aussi aux nouveaux fichiers (ACL par défaut). |
| **Compte stagiaire compromis** | Ni SSH ni sudo ; lecture seule sur `/srv/commun` ; dans `depot`, ni lister, ni lire, ni supprimer les fichiers des autres. |
| **Compte `support` compromis** | Un seul programme en root, non modifiable, arguments validés : pas d'élévation par sudo. |
| **Suppression / chiffrement de `/srv` (erreur, rançongiciel d'un utilisateur)** | 14 versions datées sur un disque réservé aux administrateurs ; un utilisateur ne peut pas toucher aux sauvegardes. |

**Ce que la configuration ne couvre pas :**
- un administrateur malveillant, ou un compte administrateur compromis avec son mot de passe ;
- le vol de la clé privée d'un membre sur son poste (les clés n'ont pas forcément de phrase de passe) ;
- les sauvegardes sur la **même machine** : une panne, un vol de la VM ou un rançongiciel obtenant root les détruit aussi (pas de règle 3‑2‑1) ;
- les failles non corrigées (0‑day), même avec les mises à jour automatiques ;
- le déni de service réseau, et l'**accès physique** à la console ou au disque (disque non chiffré) — nous l'avons constaté nous‑mêmes : via le menu de démarrage (GRUB, `init=/bin/bash`), on obtient un shell root sans mot de passe et on peut réinitialiser les comptes. Contre‑mesures possibles (bonus) : mot de passe GRUB, chiffrement du disque (LUKS).

## 4. Procédure de restauration d'une sauvegarde

Exemple : un fichier a été supprimé ou chiffré par erreur.

1. **Lister les versions** (en administrateur) :
   ```bash
   sudo ls -l /sauvegardes/versions/
   ```
2. **Retrouver le fichier** dans une version antérieure à l'incident :
   ```bash
   sudo ls -l /sauvegardes/versions/2026-11-06_083946/srv/dossiers_clients/
   ```
3. **Restaurer en conservant droits et ACL** (`-a` droits/propriétaires/dates, `-A` ACL, `-X` attributs étendus) :
   ```bash
   sudo rsync -aAX /sauvegardes/versions/<date>/srv/dossiers_clients/bilan_2025.ods \
                   /srv/dossiers_clients/
   ```
   Pour un répertoire entier, terminer la source par `/` :
   ```bash
   sudo rsync -aAX /sauvegardes/versions/<date>/srv/commun/ /srv/commun/
   ```
4. **Vérifier** :
   ```bash
   getfacl /srv/dossiers_clients/bilan_2025.ods
   sudo -u pmartin cat /srv/dossiers_clients/bilan_2025.ods
   ```

**Test réalisé (06/11/2026).** Depuis la version `2026-11-06_083946`, restauration de `/etc/hostname` vers un fichier temporaire :
- contenu **identique** à l'original (`srv-xti`) ;
- droits et date de modification **conservés** (`-rw-r--r--`, `mtime` d'origine).
La sauvegarde contient 738 fichiers et conserve les permissions : un compte sans droit sur `/srv/commun` (comme un administrateur hors des groupes métier) **ne peut pas** lire ces données dans la sauvegarde non plus — preuve que droits et ACL sont bien restitués.
De plus, `verifier.sh` (`test_B4`) rejoue automatiquement une **restauration complète de `/srv/commun`** (en root) et confirme contenu, droits et ACL identiques à l'original.

## Références

- ANSSI‑BP‑028 — *Recommandations de configuration d'un système GNU/Linux* (v2.0) :
  https://cyber.gouv.fr/sites/default/files/document/fr_np_linux_configuration-v2.0.pdf
  (page du guide : https://messervices.cyber.gouv.fr/guides/recommandations-de-securite-relatives-un-systeme-gnulinux)
- ANSSI — *Usage sécurisé d'(Open)SSH* : https://messervices.cyber.gouv.fr/guides/usage-securise-dopenssh
- GTFOBins (danger d'un sudo/SUID trop large) : https://gtfobins.github.io/
- Pages de manuel : `sshd_config`, `sudoers`, `setfacl`, `nft`, `jail.conf`, `rsync`, `systemd.timer`, `journald.conf`, `chage`.
