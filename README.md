# Déploiement LobeChat — deux comptes isolés

Configuration et procédures pour héberger [LobeChat](https://github.com/lobehub/lobe-chat)
en **mode serveur avec base de données**, pour deux utilisateurs disposant
chacun de son compte et de son historique, sans aucune visibilité sur celui de
l'autre.

Ce dépôt ne contient pas l'application : LobeChat est déployé depuis le fork
`Ariion/lobehub`, qui porte trois correctifs et rien d'autre. Ici vivent la
configuration, les procédures de vérification et les raisons derrière chaque
choix.

**État : en service.** Deux comptes isolés, isolation vérifiée en base (7
contrôles sur 7), chat, génération d'images, stockage, recherche web, base de
connaissances et mémoire à long terme fonctionnels.

## Par où commencer

| Fichier | Contenu |
|---|---|
| **[DEPLOIEMENT.md](./DEPLOIEMENT.md)** | Le guide pas à pas, de zéro au site en ligne. **Commence ici.** |
| **[ISOLATION.md](./ISOLATION.md)** | Ce qui garantit la séparation des comptes, ce qui la casserait, et les limites de l'audit. |
| **[.env.vercel.example](./.env.vercel.example)** | Toutes les variables Vercel, commentées une par une. |
| `scripts/generer-secrets.sh` | Génère `AUTH_SECRET`, `KEY_VAULTS_SECRET` et `JWKS_KEY`. |
| `scripts/verifier-isolation-neon.sql` | **Contrôle en base — à coller dans le SQL Editor de Neon.** À relancer après chaque mise à jour. |
| `scripts/verifier-isolation.sql` | Même contrôle, version détaillée pour `psql` en ligne de commande. |

## Choix retenus

| | Retenu | Pourquoi |
|---|---|---|
| Base | **Neon** | LobeChat utilise le driver `@neondatabase/serverless` par défaut. « Vercel Postgres » est d'ailleurs Neon en marque blanche. |
| Auth | **Better Auth** (intégré) | Clerk et NextAuth ont été retirés de LobeChat v2 — Better Auth est la seule option. Aucun service tiers à créer. |
| Texte | **DeepSeek** | `deepseek-v4-flash`, `deepseek-v4-pro`. |
| Images | **OpenAI GPT Image 2** | fal.ai était le choix initial, mais le crédit OpenAI était déjà acheté et sert aussi aux embeddings de la mémoire. Un fournisseur de moins à gérer. |
| Mémoire | **OpenAI `text-embedding-3-small`** | À activer explicitement dans la liste des modèles du fournisseur, sinon l'intégration mémoire reste « non activée » sans le dire. |
| Recherche web | **Tavily** | `SEARCH_PROVIDERS` est vide par défaut : sans cette variable, aucun fournisseur n'est proposé. |
| Fichiers | **Cloudflare R2**, bucket privé | **Obligatoire même sans images** : chaque envoi de message construit un `FileService`. Bucket privé = fichiers servis par URL signée temporaire. |

## Correctifs portés par le fork

LobeChat suppose partout la présence de `pg_search`, l'extension de recherche
plein texte de ParadeDB. Neon l'a dépréciée et la refuse. Le code l'utilise à
trois endroits indépendants, d'où trois correctifs — chacun ne devient visible
qu'une fois le précédent posé :

| Commit | Ce qu'il débloque | Symptôme sans lui |
|---|---|---|
| `1bb48c3` | les migrations `0090` / `0093` | le déploiement échoue, schéma annulé en entier |
| `80522f5` | `model.ts` + couches `activity` / `experience` / `identity` | l'affichage de la mémoire échoue |
| `31e99b7` | `query.ts` — l'outil mémoire de l'agent | **écrire un souvenir marche, le relire échoue** |

Le repli remplace l'expression BM25 par un `ILIKE` sur les mêmes colonnes. Le
chemin BM25 reste intact mot pour mot quand l'extension est disponible :
migrer un jour vers un Postgres qui la supporte n'exige aucun retour arrière.

Conséquence assumée, distincte de la mémoire : **la recherche globale par
mot-clé** (barre de recherche sur les sujets, messages et fichiers) reste
indisponible — elle passe par `FTS_SEARCH_PROVIDER`, qui n'accepte que
`pg_search` ou `elasticsearch`, sans mode dégradé. → `ETAT-DES-LIEUX.md`

**Après un « Sync fork », vérifier que les trois correctifs sont toujours là.**
Un amont qui les écrase casse le déploiement au redémarrage suivant.

## Les trois règles à ne pas oublier

1. **Ne jamais créer de workspace.** C'est la seule chose qui sépare les deux
   comptes : LobeChat filtre par `user_id` tant que `workspace_id` est nul, et
   partage entre membres dès qu'un workspace existe. → `ISOLATION.md` §1
2. **Ne jamais définir `S3_SET_ACL` ni `S3_PUBLIC_DOMAIN`.** Les clés d'objets
   ne contiennent pas l'identifiant du propriétaire ; ces variables rendraient
   chaque fichier lisible par simple URL. → `ISOLATION.md` §2
3. **Toujours renseigner `AUTH_ALLOWED_EMAILS`** avec les deux adresses
   complètes. Sans elle, l'inscription est ouverte à tous. Une entrée sans `@`
   autorise un domaine entier. → `ISOLATION.md` §3

`ACCESS_CODE`, le mode mot de passe partagé qu'on voulait éviter, **n'existe
plus** dans LobeChat v2 : la variable a été entièrement retirée du code. Rien à
désactiver.

## Entretien

| Quand | Quoi |
|---|---|
| Une fois par mois | Relever la consommation sur les six tableaux de bord → `SUIVI-DES-COUTS.md` |
| Une fois par mois | Sauvegarder la base : Neon → Backups, ou un `pg_dump` de la chaîne de connexion |
| Après chaque « Sync fork » | Revérifier les trois correctifs, puis relancer `scripts/verifier-isolation-neon.sql` |
| Si un compte s'ajoute un jour | Ajouter l'adresse à `AUTH_ALLOWED_EMAILS` **et redéployer** — une variable Vercel ne prend effet qu'au déploiement suivant |

Deux pièges qui ont coûté du temps et qui se reproduiront :

- **Une variable d'environnement modifiée n'a aucun effet tant qu'on n'a pas
  redéployé.** Et le bouton « Redeploy » de Vercel redéploie *le même commit* —
  il ne récupère pas les nouveaux commits du fork.
- **Un modèle activé chez un fournisseur n'est pas un modèle disponible.** Il
  faut aussi l'affecter dans « Modèles de service » ; à défaut la fonction
  s'affiche « non activée » sans expliquer pourquoi.

---

Audit et procédures établis contre `lobehub/lobe-chat` **v2.2.13**
(commit `3ba4e60`). Après une mise à jour amont, relancer
`scripts/verifier-isolation-neon.sql` et revérifier les trois correctifs
ci-dessus.
