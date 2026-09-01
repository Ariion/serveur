# Déploiement LobeChat — deux comptes isolés

Configuration et procédures pour héberger [LobeChat](https://github.com/lobehub/lobe-chat)
en **mode serveur avec base de données**, pour deux utilisateurs disposant
chacun de son compte et de son historique, sans aucune visibilité sur celui de
l'autre.

Ce dépôt ne contient pas l'application : LobeChat est déployé depuis un fork du
dépôt amont, sans modification de code. Ici vivent la configuration, les
procédures de vérification et les raisons derrière chaque choix.

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
| Images | **fal.ai** | Together AI n'expose **aucun** modèle image dans LobeChat. fal.ai en propose cinq en Flux.1. |
| Fichiers | **Cloudflare R2**, bucket privé | **Obligatoire même sans images** : chaque envoi de message construit un `FileService`. Bucket privé = fichiers servis par URL signée temporaire. |

## Correctif porté par le fork

Le fork `Ariion/lobehub` porte un correctif de migration sans lequel le
déploiement échoue : LobeChat active l'extension `pg_search`, que Neon a
dépréciée et refuse. Toutes les migrations tournant dans une seule transaction,
ce refus annulait le schéma entier. → `DEPLOIEMENT.md`, « Panne connue »

Conséquence assumée : **la recherche par mot-clé dans les conversations est
indisponible**. Tout le reste fonctionne. Après un « Sync fork », vérifier que
le correctif est toujours présent.

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

---

Audit et procédures établis contre `lobehub/lobe-chat` **v2.2.13**
(commit `3ba4e60`). Après une mise à jour amont, relancer
`scripts/verifier-isolation.sql`.
