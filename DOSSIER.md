# Dossier — Durcissement du serveur de *Chiffres & Co* (contexte B)

Groupe : Hugo, Ilyes, Camille — XTI302-CYB

Les numéros « R » renvoient au guide ANSSI-BP-028 v2.0, *Recommandations de configuration d'un système GNU/Linux*.
Les références « OpenSSH » renvoient au guide ANSSI *Usage sécurisé d'(Open)SSH*.
**À relire dans les guides avant le rendu.**

## 1. Tableau de conformité

| ID | Ce qui est fait | Test(s) de `verifier.sh` | Référence ANSSI |
|---|---|---|---|
| C1 | `creer_comptes.sh` lit `comptes.csv` et crée les groupes manquants. Il crée les comptes (`useradd`) ou les remet en conformité (`usermod -g -G`). Il est idempotent. | `test_C1_csv`, `test_C1_comptes`, `test_C1_groupes_metier`, `test_C1_doublons`, `test_C1_hors_csv` | R30 (comptes inutilisés) |
| C2 | Répertoires `root:root` en 0770 (`depot` : 1770). Les ACL nommées par groupe se règlent avec `setfacl --set`, l'ACL par défaut avec `setfacl -d --set`, et `g::---`. | `test_C2_structure`, `test_C2_droits` (16 cas), `test_C2_heritage`, `test_C2_depot` | R50, R54 |
| C3 | `/etc/sudoers.d/projet` : `%admins ALL=(ALL:ALL) ALL` et `support … NOPASSWD: /usr/local/sbin/analyse_logs.sh`. Le groupe `sudo` est vidé. | `test_C3_fichier`, `test_C3_admins`, `test_C3_support`, `test_C3_personne_d_autre` | R33, R38, R39, R43 |
| C4 | `passwd -l root`, appliqué en dernier par `installer.sh`. Répertoires personnels en 0700 et `HOME_MODE 0700`. | `test_C4_root`, `test_C4_maisons`, `test_C4_lecture` | R33, R50 |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey` | `test_S1` (`sshd -T`, puis essai réel par mot de passe) | OpenSSH : authentification par clé |
| S2 | `PermitRootLogin no` | `test_S2` | OpenSSH : interdire root ; R33 |
| S3 | `AllowGroups acces_ssh`. Clés installées par `creer_comptes.sh`. | `test_S3`, `test_S3_cles` | OpenSSH : restreindre les utilisateurs |
| S4 | `MaxAuthTries 3`, `ClientAliveInterval 300` × `ClientAliveCountMax 2`, `TMOUT=600` | `test_S4` | R32 (expiration des sessions) |
| S5 | Fichier `01-durcissement.conf` dans `sshd_config.d/`, validé par `sshd -t` avant `systemctl reload ssh`. Retour arrière en cas d'erreur. | `test_S5` | — |
| J1 | Prison `sshd` (backend systemd, action nftables) : 3 échecs en 10 min, bannissement 15 min | `test_J1`, `test_J1_J2_cohabitation` | R79 |
| J2 | Table `inet filtre`, entrée et transit en `policy drop`. Seuls `lo`, les connexions établies, NDP IPv6 et tcp/22 sont acceptés. Service activé. Pas de `flush ruleset`. | `test_J2` | R80 |
| J3 | `Storage=persistent` (journald.conf.d) et `/var/log/journal` | `test_J3` | R71 |
| J4 | `analyse_logs.sh -s SEUIL -p PERIODE`. Code de sortie 0 = normal, 1 = alerte, 2 = erreur. | `test_J4` | R71 |
| B1 | `sauvegarde.sh` : `rsync -aAXH --link-dest`, versions datées, 14 versions gardées. Second disque en ext4 « SAUVEGARDES » sur `/sauvegardes`. | `test_B1_disque`, `test_B1_versions` | — |
| B2 | `sauvegarde.timer` quotidien (`Persistent=true`), journalisé dans `/var/log/sauvegarde.log` et le journal | `test_B2` | — |
| B3 | `/sauvegardes` en `root:admins` 0750 | `test_B3` | R50 |
| B4 | Procédure de restauration (section 4), testée automatiquement vers un répertoire temporaire | `test_B4` | — |
| D1 | `unattended-upgrades` et `20auto-upgrades` (origine Debian-Security) | `test_D1` | R61 |
| D2 | `ss -tulpn` : seul sshd:22 est joignable (voir 2.6) | `test_D2` | R62, R80 |
| D3 | Recherche des fichiers modifiables par tous, et liste des SUID expliqués (voir 2.7) | `test_D3` | R54, R56, R57 |

## 2. Choix techniques

### 2.1 Comptes et droits

- **Répertoires personnels en 0700, pas en 0750.** Les groupes principaux sont partagés (`comptables`, `rh`…). En 0750, un comptable pourrait lire le répertoire personnel de son collègue. `test_C4_lecture` vérifie le contraire.
- **ACL `g::---`.** Un fichier appartient au groupe principal de son créateur. Avec `g::---`, aucun droit ne passe par ce groupe : seules les entrées nommées du tableau comptent. C'est indispensable pour `depot`. Un fichier déposé par un stagiaire appartient au groupe `stagiaire`, et les autres stagiaires ne doivent pas pouvoir le lire.
- **« Dépôt seul »** :
  - `g:stagiaire:-wx` sur `depot` : créer un fichier (w) et entrer dans le répertoire (x), sans pouvoir le lister (pas de r) ;
  - aucune entrée `stagiaire` dans l'ACL par défaut : seul l'auteur et les trois autres groupes lisent un dépôt ;
  - **sticky bit** : un stagiaire qui devinerait le nom d'un fichier ne pourrait ni le supprimer ni le remplacer.
  - Contrepartie assumée : les comptables, RH et direction ne peuvent pas non plus supprimer le fichier d'un autre (seul un administrateur le peut).
- **Mots de passe** : `comptes.csv` n'en contient aucun.
  - Les administrateurs reçoivent un mot de passe provisoire saisi pendant l'installation, avec changement forcé (`chage -d 0`). Ce mot de passe sert pour `sudo`, ce qui rend chaque action imputable, et pour la console de secours une fois root verrouillé.
  - Les comptes métier n'ont pas de mot de passe ni d'accès SSH : ce sont des comptes de test des droits.
- **Support en `NOPASSWD`** : le compte n'a pas de mot de passe (connexion par clé). Le risque est contenu de trois façons :
  - la règle n'autorise qu'un chemin absolu ;
  - le script appartient à root en 0755 ;
  - il valide ses arguments et fixe son `PATH`.

  Si `support` pouvait modifier le script, il obtiendrait un shell root (cf. GTFOBins).
- **Root verrouillé en dernier**, et seulement si un administrateur a un mot de passe. Sinon on perdrait tout accès administrateur, même en console.

### 2.2 SSH

| Option | Valeur | Justification |
|---|---|---|
| `MaxAuthTries` | 3 | Une personne légitime a une clé : un essai suffit. Moins d'essais par connexion pour un attaquant. |
| `LoginGraceTime` | 30 s | Limite les connexions laissées ouvertes sans authentification. |
| `ClientAliveInterval` × `ClientAliveCountMax` | 300 s × 2 = 10 min | Ferme les sessions dont le client ne répond plus (coupure réseau, poste éteint). |
| `TMOUT` (profile.d) | 600 s, `readonly` | `ClientAlive` ne ferme pas une session dont le client répond. `TMOUT` ferme le shell sans frappe pendant 10 min. |
| Fichier `01-…` | — | Pour sshd, la première valeur lue l'emporte : notre fichier est lu avant tout autre. |
| Redirections, X11, agent | `no` | Fonctions inutiles ici : moins de surface d'attaque. |

### 2.3 fail2ban et nftables

- **fail2ban** : 3 échecs en 10 minutes, puis 15 minutes de bannissement.
  - Contre un robot (des milliers d'essais), cela réduit l'attaque à quelques essais par quart d'heure, tout en pénalisant peu un utilisateur qui se trompe.
  - La boucle locale est exclue (tests de `verifier.sh`). L'hôte ne l'est pas, pour la démonstration. Débannissement : `fail2ban-client set sshd unbanip <IP>`.
  - `backend = systemd` : Debian 13 n'a pas `/var/log/auth.log`.
- **nftables** :
  - entrée et transit en `drop`, sortie en `accept` (le serveur doit joindre les dépôts Debian) ;
  - la découverte de voisins ICMPv6 est autorisée, faute de quoi IPv6 ne fonctionne plus. Les messages d'erreur ICMP liés à une connexion passent par `ct state related` ;
  - le ping n'est pas autorisé (non demandé).
- **Cohabitation des deux** : `flush ruleset` effacerait la table `f2b-table` de fail2ban.
  - Notre fichier ne recrée que la table `inet filtre`.
  - Une surcharge systemd remplace l'`ExecStop` de Debian, qui exécute `nft flush ruleset`.
  - `installer.sh` utilise `reload`.

### 2.4 Journal et analyse

- **Journal** : `Storage=persistent`, plafonné à 300 Mo (disque système de 20 Go) et 180 jours, ce qui suffit pour enquêter après un incident.
- **Seuil d'`analyse_logs.sh`** : 10 échecs d'une même IP en 24 h. Comme fail2ban bannit à 3 échecs, atteindre 10 signifie que l'adresse revient après ses bannissements : c'est une attaque persistante qui mérite une alerte. Le seuil se règle avec `-s`.
- **Comptage** : on compte les lignes d'échec (`Invalid user`, `Failed …`, `not allowed because`, `ROOT LOGIN REFUSED`, `Connection closed by authenticating user`). Une même connexion peut produire deux lignes : le nombre est un ordre de grandeur, suffisant pour une alerte.

### 2.5 Sauvegarde

- **Rotation** : 14 versions quotidiennes, soit 2 semaines d'historique (exigence : au moins 7). Grâce à `--link-dest`, une version sans changement ne coûte presque rien : seuls les fichiers modifiés occupent de la place.
- **Planification** : `OnCalendar=02:00`, en dehors des heures de travail. `Persistent=true` rattrape la sauvegarde si la VM était éteinte à 2 h.
- **Robustesse** : écriture dans `.encours` puis renommage, pour qu'une version interrompue ne soit jamais prise pour une version complète. Verrou `flock` contre deux exécutions simultanées. Refus si le disque n'est pas monté, pour ne pas remplir le disque système.
- **Disque** : partitionné et formaté une seule fois. `installer.sh` ne touche pas un disque qui porte déjà l'étiquette `SAUVEGARDES` ou qui n'est pas vierge. Il est monté avec `nodev,nosuid,noexec,nofail`.

### 2.6 D2 : écoutes réseau

| Écoute (`ss -tulpn`) | Justification |
|---|---|
| tcp 0.0.0.0:22 et [::]:22 — `sshd` | Le seul service attendu. |
| udp :68 (et :546 en IPv6) — client DHCP | Client qui reçoit son adresse du réseau, il n'offre aucun service. Il est de toute façon filtré par nftables : seules les réponses passent. |

Les écoutes limitées à 127.0.0.1 ou ::1 ne sont pas joignables depuis le réseau.

### 2.7 D3 : fichiers SUID présents

| Fichier | Rôle, et pourquoi il est SUID |
|---|---|
| `passwd`, `chfn`, `chsh` | Un utilisateur modifie son mot de passe ou ses informations dans `/etc/shadow` et `/etc/passwd`, fichiers réservés à root. |
| `gpasswd`, `newgrp` | Gestion et changement de groupe. |
| `su` | Changer d'identité (après authentification). |
| `sudo` | Élévation contrôlée par `/etc/sudoers`. |
| `mount`, `umount` | Montages autorisés aux utilisateurs dans `/etc/fstab` (option `user`). |
| `dbus-daemon-launch-helper` | Démarrage de services D-Bus système à la demande. |
| `ssh-keysign` | Authentification « hostbased » d'OpenSSH (inutilisée ici). |

**À compléter avec le résultat réel** de `find / -xdev -type f -perm -4000` sur la VM. Pistes d'amélioration (ANSSI R56 et R57) :
- retirer le SUID de `chfn`, `chsh`, `newgrp` et `ssh-keysign`, inutiles ici ;
- les noter dans la section bonus.

## 3. Défense

| Attaque | Ce que notre configuration rend plus difficile |
|---|---|
| **Force brute SSH** | Aucun mot de passe n'est accepté en SSH (S1), donc rien à deviner. 3 essais par connexion (S4). Bannissement après 3 échecs (J1). Alerte d'`analyse_logs.sh` au-delà de 10 échecs. |
| **Vol d'un mot de passe** | Inutile pour se connecter à distance : il faut la clé privée. Le mot de passe d'un administrateur ne sert qu'à `sudo` une fois connecté, ou en console. |
| **Utilisateur curieux** | Répertoires personnels en 0700. Les ACL de `/srv` limitent chaque groupe à son besoin : un RH ne voit pas les dossiers clients, un comptable ne voit pas les dossiers RH. Ces droits s'appliquent aussi aux nouveaux fichiers (ACL par défaut). |
| **Compte stagiaire compromis** | Pas de SSH, pas de sudo. Lecture seule sur `/srv/commun`. Dans `depot`, il ne peut ni lister, ni lire, ni supprimer les fichiers des autres. |
| **Compte support compromis** | Un seul programme lancé en root, non modifiable et dont les arguments sont validés : pas d'élévation de privilèges par sudo. |
| **Suppression ou chiffrement de `/srv` (erreur, rançongiciel d'un utilisateur)** | 14 versions datées sur un disque réservé aux administrateurs. Un utilisateur ne peut pas toucher aux sauvegardes. |

**Ce que la configuration ne couvre pas :**
- un administrateur malveillant, ou un compte administrateur compromis avec son mot de passe : il a tous les droits ;
- le vol de la clé privée d'un membre sur son poste, car les clés n'ont pas forcément de phrase de passe ;
- les sauvegardes stockées sur la même machine : une panne, un vol de la VM ou un rançongiciel qui obtient root les détruit aussi (pas de règle 3-2-1) ;
- les failles logicielles pas encore corrigées (0-day), même avec les mises à jour automatiques ;
- le déni de service réseau, et l'accès physique à la console ou au disque (disque non chiffré).

## 4. Procédure de restauration d'une sauvegarde

Exemple : un fichier de `/srv/dossiers_clients` a été supprimé ou chiffré par erreur.

1. **Lister les versions** (en administrateur) :
   ```bash
   sudo ls -l /sauvegardes/versions/
   ```
2. **Retrouver le fichier** dans une version antérieure à l'incident :
   ```bash
   sudo ls -l /sauvegardes/versions/2026-11-05_020312/srv/dossiers_clients/
   ```
3. **Restaurer en conservant les droits et les ACL**. `-a` conserve les droits, propriétaires et dates ; `-A` les ACL ; `-X` les attributs étendus :
   ```bash
   sudo rsync -aAX /sauvegardes/versions/2026-11-05_020312/srv/dossiers_clients/bilan_2025.ods \
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

**Test réalisé** : *(à remplir par le groupe, avec la date, le fichier restauré et le résultat de `getfacl`)*.
`verifier.sh` (`test_B4`) répète automatiquement cette procédure vers un répertoire temporaire. Il compare ensuite le contenu, les droits et les ACL.
