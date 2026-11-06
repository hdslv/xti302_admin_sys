# Répartition du travail — Projet XTI302-CYB (contexte B, *Chiffres & Co*)

Groupe : **Hugo, Ilyes, Camille**

## Principe

Le découpage suit les trois séances du cours, donc les parties sont **progressives** (chacune s'appuie sur la précédente) et **complémentaires** (ensemble elles couvrent tout le cahier des charges). Chacun **pilote** une partie : il la comprend à fond, écrit ses sections du dossier, fait ses commits et mène sa démo.

> **Règle d'or (soutenance)** : le jury pose des questions individuelles sur **tout** le projet, pas seulement sur « votre » partie, et chacun doit pouvoir expliquer **n'importe quelle ligne**. La répartition sert à se répartir la rédaction et la maîtrise principale — mais à la fin, **les trois relisent les trois parties ensemble**.

Le travail technique (scripts, config) est déjà en place et `verifier.sh` passe à 105/105. Il reste surtout à **comprendre, documenter, committer et savoir défendre** chaque partie.

---

## Partie 1 — Comptes, droits et accès SSH (séance 3) — **Hugo**

**Exigences :** C1, C2, C3, C4, S1, S2, S3, S4, S5.

**Fichiers à maîtriser :**
- `creer_comptes.sh`, `comptes.csv`
- `config/ssh/sshd_config.d/01-durcissement.conf`, `config/profile.d/tmout.sh`
- `config/sudoers.d/projet`, `config/cles/`

**Notions à savoir expliquer :**
- utilisateurs / groupes, groupe principal vs secondaires ;
- permissions Unix et **ACL** (`setfacl`, `getfacl`), **ACL par défaut** (héritage), **sticky bit**, le cas « **dépôt seul** » des stagiaires (`-wx`, `g::---`) ;
- `sudo` et le **moindre privilège** : pourquoi `support` n'a qu'un seul script, pourquoi ce script appartient à root (voir **GTFOBins**) ;
- durcissement SSH : clé uniquement, `PermitRootLogin no`, `AllowGroups`, `MaxAuthTries`, expiration des sessions ; validation par `sshd -t` ;
- verrouillage de root (`passwd -l`) et accès de secours.

**À rédiger dans `DOSSIER.md` :** lignes C1–C4 et S1–S5 du tableau de conformité ; sections *Choix techniques* 2.1 (comptes/droits) et 2.2 (SSH) ; dans *Défense* : vol de mot de passe, utilisateur curieux, compte stagiaire compromis.

**Démo soutenance :** montrer qu'un `rh` ne lit pas `/srv/dossiers_clients`, qu'un stagiaire ne peut pas lister `depot` ; connexion root refusée ; connexion par mot de passe refusée (seule la clé marche).

---

## Partie 2 — Journaux et défense réseau (séance 4) — **Ilyes**

**Exigences :** J1, J2, J3, J4, D1.

**Fichiers à maîtriser :**
- `analyse_logs.sh`
- `config/nftables.conf`, `config/systemd/nftables.service.d/projet.conf`
- `config/fail2ban/jail.d/projet-sshd.conf`
- `config/journald/persistant.conf`, `config/apt/20auto-upgrades`

**Notions à savoir expliquer :**
- pare-feu **nftables** : politique par défaut `drop`, `ct state established,related`, pourquoi autoriser seulement SSH, survie au redémarrage (service activé) ;
- **fail2ban** : détection des échecs, bannissement, et **cohabitation avec nftables** (pas de `flush ruleset`, surcharge systemd) ;
- où sont réellement les **journaux SSH** sur Debian 13 (journal `systemd`, pas `/var/log/auth.log`) ; journal **persistant** ;
- `analyse_logs.sh` : lecture du journal, rapport (échecs par IP, comptes visés, réussites), **code de sortie** et seuil d'alerte ;
- mises à jour de sécurité automatiques (`unattended-upgrades`).

**À rédiger dans `DOSSIER.md` :** lignes J1–J4 et D1 du tableau ; sections *Choix techniques* 2.3 (fail2ban/nftables) et 2.4 (journal/analyse) ; dans *Défense* : force brute SSH.

**Démo soutenance :** depuis l'hôte, lancer plusieurs connexions SSH ratées → **bannissement fail2ban** ; `fail2ban-client set sshd unbanip` ; scan de ports qui ne voit que le 22 ; exécuter `analyse_logs.sh` et montrer le code de sortie.

---

## Partie 3 — Sauvegarde, système et intégration (séance 5) — **Camille**

**Exigences :** B1, B2, B3, B4, D2, D3, et **`installer.sh`** (l'intégration complète).

**Fichiers à maîtriser :**
- `sauvegarde.sh`, `config/systemd/sauvegarde.service` + `sauvegarde.timer`
- `installer.sh`, `config/suid_attendus.txt`

**Notions à savoir expliquer :**
- sauvegarde **incrémentale** avec `rsync --link-dest`, **versions datées**, rotation (garder ≥ 7), conservation des droits/ACL (`-aAX`) ;
- planification par **timer systemd**, journalisation ; **restauration** d'un fichier ; pourquoi des versions plutôt qu'un miroir (règle **3-2-1**, rançongiciel) ;
- accès réseau : `ss -tulpn`, ne laisser que SSH (**D2**) ; fichiers **SUID** et world-writable (**D3**), et le piège de `find` sur `/proc`, `/sys` ;
- **`installer.sh`** : rôle d'orchestration, **idempotence**, reconstruction depuis le **snapshot vierge**, et pourquoi il ne reformate jamais le disque de sauvegarde.

**À rédiger dans `DOSSIER.md` :** lignes B1–B4, D2, D3 du tableau ; sections *Choix techniques* 2.5 (sauvegarde), 2.6 (D2) et 2.7 (D3) ; dans *Défense* : rançongiciel / perte de données ; **section 4 : procédure de restauration** (avec votre vrai test : date, fichier, résultat `getfacl`).

**Démo soutenance :** repartir du **snapshot vierge**, lancer `installer.sh` qui reconstruit tout, puis `verifier.sh` ; restaurer un fichier depuis une version antérieure ; montrer `ss -tulpn`.

---

## Tâches communes (les trois ensemble)

- **Dépôt Git** : chacun fait **ses propres commits** sur sa partie (le sujet demande des commits réguliers de chaque membre). README commun.
- **Relecture croisée** : chacun lit les deux autres parties et sait les expliquer.
- **Test d'intégration final** : ensemble, retour au snapshot vierge → `installer.sh` → `verifier.sh` à 105/105.
- **`verifier.sh`** : chacun comprend les tests `test_*` de sa partie (c'est votre meilleur allié pour la mise en situation de dépannage de la soutenance).

## Ordre conseillé (progressif)

1. **Hugo** (base : comptes, droits, SSH) — tout le reste s'appuie dessus.
2. **Ilyes** (défense : pare-feu, fail2ban, journaux) — protège l'accès mis en place en partie 1.
3. **Camille** (sauvegarde + intégration) — sauvegarde ce qui précède et assemble le tout dans `installer.sh`.

> Les noms sont une proposition : échangez les parties si vous préférez. L'essentiel est que chacun en pilote une **et** comprenne les trois.
