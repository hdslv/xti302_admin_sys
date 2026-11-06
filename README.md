# Projet XTI302-CYB — Durcir un serveur Linux et le prouver

**Contexte B : cabinet comptable *Chiffres & Co***. Groupe : Hugo, Ilyes, Camille.

Le serveur Debian 13 est configuré et durci par des scripts : comptes, droits, SSH, pare-feu, journaux, sauvegardes.
Le script `verifier.sh` prouve automatiquement que chaque exigence est respectée.

## Prérequis

- **VM** : Debian 13 en installation minimale, sans interface graphique, avec le serveur SSH. 2 Go de RAM, disque système de 20 Go (`sda`).
- **Second disque** : 1 à 2 Go (`sdb`), **vierge**. `installer.sh` le partitionne et le formate une seule fois.
- **Réseau** : carte en « accès par pont », pour que les postes du groupe joignent la VM. Son adresse IP s'obtient avec `ip a`.
- **Snapshot « vierge »** pris juste après l'installation.
- **Clés publiques** des comptes du groupe `acces_ssh` dans `config/cles/` (voir `config/cles/LISEZMOI.md`).

## Avant la première installation

1. Dans `comptes.csv`, remplacez `membre1`, `membre2` et `membre3` par vos vrais logins et noms.
   Le compte créé pendant l'installation de Debian doit être l'un d'eux.
2. Déposez une clé publique par compte de `acces_ssh` : `config/cles/<login>.pub` (vos trois logins + `support`).
3. Faites un commit et un push.

## Installation (sur la VM vierge)

```bash
su -                                   # ou : sudo -i
apt update && apt install -y git
git clone <URL_DU_DEPOT> /opt/projet   # le dépôt doit appartenir à root
cd /opt/projet
./installer.sh
```

`installer.sh` :
- installe les paquets (dépôts Debian officiels uniquement) ;
- lance `creer_comptes.sh` ;
- copie les fichiers de `config/` ;
- prépare le second disque et planifie les sauvegardes ;
- applique le durcissement SSH, puis verrouille `root` en dernier.

Il demande un mot de passe provisoire pour chaque administrateur qui n'en a pas encore. Ce mot de passe sert pour `sudo` et la console, et doit être changé à la première connexion.

Le script peut être relancé sans danger : il ne crée pas de doublon et ne reformate jamais le disque de sauvegarde.

> **Attention :** gardez une session SSH ouverte pendant les modifications, et testez la connexion dans une seconde session avant de fermer la première.
> Une fois `root` verrouillé, l'accès de secours (console VirtualBox) se fait avec **un compte administrateur nominatif** et son mot de passe.

## Vérification

```bash
cd /opt/projet
./verifier.sh          # en root ; code de sortie 0 si tout est conforme
```

Redémarrez la VM au moins une fois, puis relancez `verifier.sh`. Cela prouve que le pare-feu et le journal persistent.

## Tests depuis l'hôte (PowerShell sous Windows)

```bash
ssh <login>@<IP_VM>                         # administrateur, par clé
ssh -i $HOME\.ssh\projet_support support@<IP_VM>
ssh root@<IP_VM>                            # doit être refusé (S2)
ssh -o PubkeyAuthentication=no <login>@<IP_VM>   # mot de passe refusé (S1)
Test-NetConnection <IP_VM> -Port 80         # doit échouer : seul 22 est ouvert (J2)
```

Démonstration fail2ban : faites 3 tentatives avec un compte inexistant, par exemple `ssh faux@<IP_VM>` trois fois. L'hôte est alors banni.
Pour le débannir sans attendre (sur la VM) :

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <IP_HOTE>
```

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `comptes.csv` | Comptes et groupes (format imposé, aucun mot de passe) |
| `creer_comptes.sh` | Comptes, groupes, répertoires `/srv` + ACL, clés SSH (C1, C2, C4) |
| `installer.sh` | Reconstruit toute la configuration sur la VM vierge |
| `analyse_logs.sh` | Rapport des connexions SSH, code de sortie 1 si alerte (J4) |
| `sauvegarde.sh` | Sauvegarde incrémentale versionnée de `/srv` et `/etc` (B1) |
| `verifier.sh` | Vérification automatique de toutes les exigences |
| `config/ssh/sshd_config.d/01-durcissement.conf` | S1 à S5 |
| `config/profile.d/tmout.sh` | Fermeture des shells inactifs (S4) |
| `config/sudoers.d/projet` | C3 |
| `config/nftables.conf`, `config/systemd/nftables.service.d/` | J2 |
| `config/fail2ban/jail.d/projet-sshd.conf` | J1 |
| `config/journald/persistant.conf` | J3 |
| `config/apt/20auto-upgrades` | D1 |
| `config/systemd/sauvegarde.{service,timer}` | B2 |
| `config/suid_attendus.txt` | Liste des SUID expliqués (D3) |
| `config/cles/*.pub` | Clés publiques des comptes de `acces_ssh` |
| `DOSSIER.md` | Conformité, choix techniques, défense, restauration |
