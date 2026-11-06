# Comment chaque membre fait son propre commit

Le sujet demande des **commits réguliers de chaque membre** du groupe. Voici comment s'y prendre.

## État actuel du dépôt (local, non poussé)

- Branches : `main`, `partie-1-comptes-droits-ssh` (Hugo), `partie-2-journaux-defense` (Ilyes), `partie-3-sauvegarde-integration` (Camille).
- Les trois branches ont été fusionnées dans `main` → `main` contient le projet complet.
- Les commits d'initialisation ont été faits par Hugo (mise en place) ; **il reste à ce qu'Ilyes et Camille ajoutent leurs propres commits** avec leur vraie identité.

> Pour que chacun commite depuis son poste, le dépôt doit d'abord être **poussé une fois** sur GitHub. C'est le point de départ obligatoire d'un travail à plusieurs.

## Étape 0 — chaque membre règle son identité Git (une seule fois, sur son PC)

```bash
git config --global user.name "Prénom Nom"
git config --global user.email "prenom.nom@efrei.net"
```

C'est **essentiel** : c'est ce nom/email qui apparaît dans l'historique et prouve qui a contribué.

## Étape 1 — Hugo pousse le dépôt une première fois

1. Créer un dépôt **vide et privé** sur https://github.com/new (nom : `projet-xti302-cyb`, ne rien cocher).
2. Depuis le dossier du projet :

```bash
git remote add origin https://github.com/<pseudo-hugo>/projet-xti302-cyb.git
git push -u origin main partie-1-comptes-droits-ssh partie-2-journaux-defense partie-3-sauvegarde-integration
```

3. Dans GitHub → Settings → Collaborators : **ajouter Ilyes et Camille** pour qu'ils puissent pousser.

## Étape 2 — Ilyes et Camille font leur vrai commit

Chacun sur **son** PC :

```bash
git clone https://github.com/<pseudo-hugo>/projet-xti302-cyb.git
cd projet-xti302-cyb
git checkout partie-2-journaux-defense     # Ilyes  (Camille : partie-3-sauvegarde-integration)
```

Il fait ensuite une **vraie contribution** à sa partie, par exemple :
- compléter sa section de `DOSSIER.md` (tableau de conformité, choix techniques, défense) ;
- ajouter un commentaire d'explication dans un de ses scripts ;
- ajuster une valeur et la justifier.

Puis :

```bash
git add -A
git commit -m "Ilyes : rédaction de la section J1-J4 du dossier"
git push
```

## Étape 3 — faire converger dans `main` (Pull Request)

Sur GitHub, chacun ouvre une **Pull Request** de sa branche vers `main`. Le groupe relit, puis fusionne. C'est la « convergence vers `main` », et ça laisse une trace claire de qui a fait quoi.

## Variante sans push immédiat (tous ensemble en TP)

Si vous préférez ne rien pousser pour l'instant et tout faire sur **un seul PC** en séance :
1. chaque membre s'installe à tour de rôle au clavier d'Hugo ;
2. il règle son identité le temps de son commit :

```bash
git checkout partie-2-journaux-defense
git commit --author="Ilyes <ilyes@efrei.net>" -am "Ilyes : ..."
```

3. une fois les trois passés, vous poussez le tout.

> Dans tous les cas, l'important pour la note : que l'historique montre **au moins un commit réel par membre**, et que chacun sache **expliquer** ce qu'il a committé.
