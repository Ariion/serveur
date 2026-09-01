# Déployer LobeChat en mode serveur pour deux comptes isolés

Guide pas à pas. À chaque fois que j'ai besoin de quelque chose de ta part,
c'est marqué **[À TOI DE JOUER]**.

Cible : LobeChat v2 sur Vercel, base Postgres Neon, comptes email + mot de
passe (Better Auth), DeepSeek pour le texte, fal.ai pour les images Flux.1.

Compte trois quarts d'heure, dont une bonne partie d'attente de build.

---

## Les trois décisions, et pourquoi

### Neon plutôt que Vercel Postgres

**Neon.** Deux raisons concrètes, pas des préférences :

1. Le code de LobeChat utilise le driver `@neondatabase/serverless` **par
   défaut** (`packages/database/src/core/web-server.ts`). C'est le chemin le
   plus testé par le projet, celui que suit sa documentation Vercel.
2. « Vercel Postgres » *est* Neon depuis que Vercel a remplacé son offre
   maison par Neon en marque blanche. En passant par Neon directement, tu as
   la console complète (branches, historique des requêtes, éditeur SQL — dont
   tu auras besoin au §6 pour vérifier l'isolation) et une facturation qui ne
   dépend pas de ton plan Vercel.

L'offre gratuite de Neon suffit très largement pour deux personnes.

Supabase fonctionnerait aussi, mais il faudrait passer par le pooler en mode
transaction et poser `DATABASE_DRIVER=node` : plus de pièces mobiles pour zéro
bénéfice ici.

### Better Auth, parce que Clerk n'existe plus

Ta question était « Clerk ou Better Auth ». Elle est tranchée par le code :
**Clerk a été entièrement retiré de LobeChat v2**. Aucune dépendance
`@clerk/*` dans le `package.json`, aucune variable Clerk dans le code ; il ne
reste qu'un chemin de compatibilité pour re-hasher les mots de passe bcrypt de
gens qui *migrent depuis* Clerk. NextAuth a disparu de la même façon.

**Better Auth est donc la seule option**, et elle est intégrée : les comptes
vivent dans ta propre base Postgres, il n'y a pas de service tiers à créer, à
payer ni à connecter. Pour deux comptes, c'est aussi le bon choix sur le fond.

**Tu n'as donc pas de compte Clerk à créer.** Une chose en moins sur ta liste.

### fal.ai, pas Together AI

Tranché par le code aussi : dans le catalogue de modèles de LobeChat,
**Together AI n'expose aucun modèle image** — zéro entrée `type: 'image'`,
aucune mention de Flux. fal.ai en expose dix, dont cinq Flux (`flux/schnell`,
`flux/krea`, `flux-kontext/dev`, `flux-pro/kontext`, plus les variantes
d'édition).

Si tu veux Flux.1 dans LobeChat, c'est **fal.ai**. Together AI resterait
utilisable pour du texte, mais tu as déjà DeepSeek pour ça.

---

## 1. Forker le dépôt

**[À TOI DE JOUER]**

1. Va sur <https://github.com/lobehub/lobe-chat>
2. Bouton **Fork** en haut à droite → crée `Ariion/lobe-chat`
3. Laisse « Copy the main branch only » coché

Garde bien un **fork**, pas une copie : le bouton « Sync fork » te permettra de
récupérer les mises à jour amont en un clic. Ne modifie aucun fichier dedans —
toute la configuration passe par des variables d'environnement Vercel, donc le
fork reste propre et se met à jour sans conflit.

Le dépôt `Ariion/serveur` (celui-ci) ne contient pas l'application : il tient
la configuration, ce guide, l'audit d'isolation et les scripts de
vérification. C'est ce qu'on regarde dans six mois pour se rappeler pourquoi
telle variable est là.

---

## 2. Créer la base Neon

**[À TOI DE JOUER]**

1. Compte sur <https://neon.tech> (connexion via GitHub, offre gratuite)
2. **Create project** — région **Europe (Frankfurt)** si vous êtes en France
3. Sur le tableau de bord, panneau **Connection string**
4. Vérifie que le sélecteur est sur **Pooled connection**
5. Copie l'URL complète, de la forme :
   `postgres://neondb_owner:xxxxx@ep-xxx-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require`

**Garde-la sous la main pour l'étape 4.** C'est un identifiant complet
d'accès à la base : ne la colle nulle part ailleurs que dans Vercel, et pas
dans cette conversation.

---

## 3. Générer les trois secrets

**[À TOI DE JOUER]** — sur ta machine, il faut juste Node :

```bash
git clone https://github.com/Ariion/serveur
cd serveur
./scripts/generer-secrets.sh
```

Tu obtiens `AUTH_SECRET`, `KEY_VAULTS_SECRET` et `JWKS_KEY`. Garde la sortie
ouverte pour l'étape suivante.

Si tu n'as pas Node sous la main, les deux premiers se génèrent aussi avec
`openssl rand -base64 32` ; en revanche `JWKS_KEY` (paire RSA au format JWKS)
a vraiment besoin du script.

Deux d'entre eux ne doivent **jamais** être changés après coup :
`KEY_VAULTS_SECRET` chiffre les clés API stockées en base — le modifier les
rend illisibles ; `AUTH_SECRET` signe les sessions — le modifier vous
déconnecte tous les deux (sans perte de données, ça).

---

## 4. Créer les clés API

**[À TOI DE JOUER]**

**DeepSeek** — <https://platform.deepseek.com> → API keys → Create.
Prépaiement, quelques euros suffisent pour des mois d'usage à deux.
Modèles disponibles dans LobeChat : `deepseek-v4-flash` et `deepseek-v4-pro`.

**fal.ai** — <https://fal.ai/dashboard/keys> → Add key.
Facturation à l'image. `flux/schnell` est le moins cher pour tester ;
`flux-pro/kontext` pour la qualité.

**Cloudflare R2** (stockage des images générées et des pièces jointes) —
sans lui, la génération d'images ne fonctionne pas : Vercel n'a pas de disque
persistant.

> **Démarrage en texte seul.** fal.ai et R2 sont facultatifs au premier
> déploiement : sans eux, LobeChat fonctionne pleinement en texte (seules la
> génération d'images et les pièces jointes sont indisponibles). Pour les
> ajouter plus tard, il suffit de créer le bucket, d'ajouter `FAL_API_KEY` et
> les cinq variables `S3_*` dans Vercel, puis de redéployer — rien à refaire,
> et les conversations existantes ne bougent pas.

1. <https://dash.cloudflare.com> → R2 → **Create bucket**, nomme-le `lobechat`
2. **Laisse le bucket privé.** Ne l'expose sur aucun domaine public, n'active
   pas l'accès public — c'est ce qui garde vos images inaccessibles sans
   authentification (détail dans `ISOLATION.md` §2)
3. R2 → **Manage API tokens** → Create token, permission **Object Read & Write**
4. Note `Access Key ID`, `Secret Access Key`, et l'**endpoint S3** de la forme
   `https://<account_id>.r2.cloudflarestorage.com` — **sans** le nom du bucket
   à la fin

---

## 5. Déployer sur Vercel

**[À TOI DE JOUER]**

1. <https://vercel.com/new> → importe ton fork `Ariion/lobe-chat`
2. **Avant de cliquer sur Deploy**, déplie **Environment Variables** et saisis
   tout le bloc ci-dessous.

C'est le point le plus délicat du guide : le build Vercel lance
`bun run build:vercel`, qui construit l'application **puis migre la base**. Si
`DATABASE_URL` ou `KEY_VAULTS_SECRET` manquent au premier déploiement, le
build échoue à l'étape de migration. Tout saisir d'un coup, maintenant.

| Variable | Valeur |
|---|---|
| `DATABASE_URL` | l'URL Neon de l'étape 2 |
| `KEY_VAULTS_SECRET` | étape 3 |
| `AUTH_SECRET` | étape 3 |
| `JWKS_KEY` | étape 3, sur une seule ligne |
| `AUTH_ALLOWED_EMAILS` | **vos deux adresses complètes, séparées par une virgule, sans espace** |
| `DEEPSEEK_API_KEY` | étape 4 |
| `FAL_API_KEY` | étape 4 — *omettre si démarrage en texte seul* |
| `S3_ACCESS_KEY_ID` | R2 — *omettre si texte seul* |
| `S3_SECRET_ACCESS_KEY` | R2 — *omettre si texte seul* |
| `S3_BUCKET` | `lobechat` — *omettre si texte seul* |
| `S3_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` — *omettre si texte seul* |
| `S3_REGION` | `auto` — *omettre si texte seul* |

`.env.vercel.example` reprend cette liste avec le détail de chaque variable.

Sur `AUTH_ALLOWED_EMAILS`, un piège à connaître : **une entrée sans `@` est
lue comme un domaine entier**. Écrire `gmail.com` autoriserait tout Gmail à
s'inscrire chez vous. Les deux adresses complètes, rien d'autre.

Et **ne mets pas** `S3_SET_ACL` ni `S3_PUBLIC_DOMAIN` : ces deux variables
rendraient chaque fichier lisible par simple URL, sans authentification.

3. **Deploy.** Compte 10 à 20 minutes — le monorepo est gros.
4. Une fois en ligne, ajoute `APP_URL` avec l'URL de production
   (`https://xxx.vercel.app` ou ton domaine), puis **Redeploy**.

### Si le build échoue

- *Erreur de migration / connexion base* → `DATABASE_URL` mal copiée, ou tu as
  pris la connexion « direct » au lieu de « pooled ».
- *`KEY_VAULTS_SECRET is not set`* → la variable n'était pas là au premier
  build. Ajoute-la et redéploie.
- *Manque de mémoire* → rare, le build réserve déjà 8 Go
  (`NODE_OPTIONS=--max-old-space-size=8192`). Relance simplement.

---

### Panne connue : `pg_search is deprecated` (corrigée)

Si le journal se termine par :

```
❌ Database migrate failed
extension "pg_search" is deprecated and no longer allowed
```

…le build applicatif a **réussi** ; seule la création des tables a échoué.

`pg_search` est l'extension de recherche plein texte que LobeChat active dans
sa migration `0090`. Neon l'a dépréciée et la refuse désormais. Comme drizzle
applique toutes les migrations dans **une seule transaction**, ce refus annulait
le schéma entier — donc tout le déploiement — pour une fonctionnalité
optionnelle. Ce n'est pas une erreur de configuration, et ce n'était pas
corrigé en amont.

Le fork porte le correctif (commit `1bb48c3`) : `0090` tente l'activation et
poursuit si l'hôte refuse ; `0093` ne crée ses 14 index BM25 que si l'extension
est réellement présente. Les instructions d'origine sont conservées à
l'identique sous une garde, donc le comportement reste inchangé sur un Postgres
qui supporte `pg_search`.

**Conséquence à connaître : la recherche par mot-clé dans les conversations est
indisponible** (elle renvoie une erreur — l'opérateur `bm25` n'existe pas sans
l'extension). Le chat, l'historique, les comptes et l'isolation ne sont pas
affectés. Pour la retrouver, il faudrait un Postgres supportant `pg_search` ou
un Elasticsearch via `FTS_SEARCH_PROVIDER=elasticsearch` — disproportionné à
deux.

Ce correctif fait diverger le fork de l'amont. Après un « Sync fork », vérifier
qu'il est toujours là : sans lui, le déploiement échouera de nouveau.

---

## 6. Vérifier l'isolation

**Ne considère pas le déploiement terminé avant d'avoir fait passer cette
section.** Elle a deux moitiés : ce que tu vois dans le navigateur, et ce que
dit la base. Les deux sont nécessaires — l'interface peut masquer une donnée
qu'elle a pourtant le droit de lire.

### 6a. Créer les deux comptes

**[À TOI DE JOUER]**

1. Ouvre l'URL de production → **Sign up** → crée le compte **A** (aardesign)
2. Lance une conversation reconnaissable, par exemple :
   > `Retiens ce mot de passe secret : ARTICHAUT-42. Répète-le.`
3. Génère une image (« un artichaut violet ») — *sauter si démarrage en texte seul*
4. **Déconnecte-toi complètement**
5. **Fenêtre de navigation privée**, ou un autre navigateur — pas un simple
   onglet : il faut être sûr qu'aucun cookie de session ne traîne
6. **Sign up** → compte **B** (procomsolution)
7. Conversation distincte :
   > `Retiens ce mot de passe secret : BROCOLI-99. Répète-le.`
8. Génère une image différente (« un brocoli doré ») — *idem, sauter si texte seul*

### 6b. Contrôles dans le navigateur

Depuis le compte **B**, encore connecté :

| # | Contrôle | Attendu |
|---|---|---|
| 1 | Liste des conversations dans la barre latérale | **Seule** la conversation BROCOLI-99. Aucune trace d'ARTICHAUT. |
| 2 | Demander à l'assistant : `Quel mot de passe secret t'ai-je donné ?` | Il répond BROCOLI-99, ou ne sait pas. **Jamais ARTICHAUT-42.** |
| 3 | Galerie d'images | Seul le brocoli. Pas l'artichaut. |
| 4 | *(recherche par mot-clé indisponible — voir la panne `pg_search` ci-dessus)* | — |
| 5 | Paramètres → clés API | Aucune clé saisie par le compte A n'apparaît. |

Puis le contrôle croisé, celui qu'on oublie : **reconnecte-toi sur le compte
A** et refais les points 1 à 3 en guettant toute trace de `BROCOLI`.
L'isolation doit tenir dans les deux sens.

Enfin, le contrôle d'inscription : en navigation privée, tente de créer un
compte avec une **troisième** adresse. Ce doit être refusé
(`EMAIL_NOT_ALLOWED`). Si ça passe, `AUTH_ALLOWED_EMAILS` est mal réglé —
supprime le compte parasite et corrige avant d'aller plus loin.

### 6c. Contrôle en base

C'est la vérification qui compte : l'interface peut très bien ne pas afficher
une donnée qu'elle aurait pourtant le droit de lire.

**[À TOI DE JOUER]** — Neon Console → **SQL Editor** → colle le contenu de
`scripts/verifier-isolation.sql` → Run.

Ou en ligne de commande :

```bash
psql "postgres://...ton_url_neon..." -f scripts/verifier-isolation.sql
```

Le script est en lecture seule. Six blocs, chacun avec une colonne `verdict` :

1. **Comptes existants** — exactement 2 lignes
2. **Workspaces** — table **vide**. *C'est le contrôle décisif* : tant
   qu'aucun workspace n'existe, LobeChat filtre chaque lecture par
   `user_id = <appelant>`. Dès qu'un workspace existe et contient les deux
   comptes, `user_id` sort du filtre pour tout ce qui est marqué « public » —
   et les images générées le sont par défaut. Voir `ISOLATION.md` §1.
3. **Balayage dynamique** — aucune ligne rattachée à un workspace, sur
   *toutes* les tables de la base (le contrôle reste valable après une mise à
   jour amont qui ajouterait des tables)
4. **Contenus par compte** — les deux comptes apparaissent avec des compteurs
   non nuls, répartis, jamais cumulés sur un seul identifiant
5. **Contamination croisée** — aucun message rattaché à la conversation d'un
   autre compte, aucune image rattachée au lot d'un autre
6. **Contenus orphelins** — aucune ligne sans propriétaire

**Tout doit afficher `OK`.** Un seul `FAIL` : arrête-toi, envoie-moi la sortie,
on regarde ensemble avant que vous mettiez quoi que ce soit de personnel
dedans.

---

## 7. Après la mise en route

**Ne créez jamais de workspace** et n'invitez jamais l'un des comptes chez
l'autre. Si l'interface propose « espace de travail » ou « inviter un
membre », c'est exactement l'action qui ferait basculer vos données dans le
régime partagé décrit en `ISOLATION.md` §1.

**Après chaque mise à jour** de LobeChat (bouton « Sync fork » puis redéploiement
Vercel), refais tourner `scripts/verifier-isolation.sql`. Deux minutes, et ça
détecte une régression amont ou une table nouvellement rattachée à un
workspace.

**Sauvegardes** : Neon garde un historique permettant de restaurer à un instant
passé (7 jours sur l'offre gratuite). Suffisant pour un accident ; si ces
conversations comptent vraiment, prévois un `pg_dump` périodique.

**Coûts** : Neon gratuit, Vercel Hobby gratuit, R2 gratuit jusqu'à 10 Go.
Tu ne paies en pratique que DeepSeek (quelques centimes par mois à deux) et
fal.ai (à l'image). Pense à `AI_IMAGE_DEFAULT_IMAGE_NUM=1` : LobeChat génère
**quatre** images par requête par défaut, donc quatre fois la facture.
