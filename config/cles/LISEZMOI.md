# Clés publiques SSH

Un fichier `<login>.pub` par compte du groupe `acces_ssh` : les trois administrateurs et `support`.
Le nom du fichier doit être **exactement** le login de `comptes.csv`.
`creer_comptes.sh` copie chaque clé dans `~<login>/.ssh/authorized_keys`.

**Ne mettez JAMAIS de clé privée ici** (c'est le fichier sans `.pub`).

## Clé d'un administrateur (chaque membre, sur son propre PC)

Dans PowerShell sous Windows (ou dans un terminal sous Linux ou macOS) :

```
ssh-keygen -t ed25519 -C "prenom.nom@projet-xti302"
```

Envoyez ensuite au groupe **uniquement** `C:\Users\<vous>\.ssh\id_ed25519.pub`, renommé en `<login>.pub`.

## Clé de test du compte support

Une seule paire, générée par un membre du groupe :

```
ssh-keygen -t ed25519 -f $HOME\.ssh\projet_support -C "support (test)"
```

Copiez `projet_support.pub` ici sous le nom `support.pub`. La clé privée `projet_support` reste sur le PC.
Connexion de test :

```
ssh -i $HOME\.ssh\projet_support support@<IP de la VM>
```
