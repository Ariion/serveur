# État des lieux — ce qui marche, ce qui manque, et à quel prix

Établi contre le déploiement réel (Neon + Vercel + DeepSeek + R2), après
diagnostic dans le code de `lobehub/lobe-chat` v2.2.13.

## Opérationnel

| Fonction | Vérifié par |
|---|---|
| Comptes séparés, email + mot de passe | Deux comptes créés, chacun sa conversation |
| Inscription verrouillée à deux adresses | `AUTH_ALLOWED_EMAILS` + `email-whitelist.ts` |
| Chat texte DeepSeek | Réponses obtenues sur les deux comptes |
| Persistance des conversations | Écrites dans Neon |
| Stockage objet | R2 privé, URLs pré-signées |

## Manquant, et pourquoi

### Génération d'images — une variable

`FAL_API_KEY` n'a jamais été posée dans Vercel : elle avait été retirée
volontairement tant que le stockage n'existait pas, puisque la génération
échouait à l'enregistrement. R2 étant configuré, l'obstacle a disparu.

**Coût : nul.** La clé existe déjà, fal.ai facture à l'image.

### Mémoire à long terme — un fournisseur d'embeddings

`serverRuntimes/memory.ts` appelle `embed()` avant chaque écriture. Le défaut
est `openai/text-embedding-3-small` (`packages/const/src/settings/llm.ts`).
Sans clé OpenAI, l'appel échoue, l'erreur remonte vide, et l'agent conclut à
tort à un problème de format — il boucle en consommant du crédit DeepSeek.

Trois fournisseurs seulement exposent des embeddings dans le catalogue :
**OpenAI**, **Nebius**, **Vercel AI Gateway**. Ni DeepSeek ni fal.ai.

Contrainte technique : la mémoire demande des vecteurs de **1024 dimensions**
(`DEFAULT_USER_MEMORY_EMBEDDING_DIMENSIONS`), passées en paramètre `dimensions`
à l'appel. Les modèles `text-embedding-3-*` d'OpenAI acceptent ce paramètre et
réduisent leur sortie native ; un modèle qui l'ignorerait renverrait une taille
incompatible. D'où la préférence pour un `text-embedding-3-*`, en direct ou via
la passerelle Vercel.

**Coût : le minimum de rechargement du fournisseur**, pas l'usage — quelques
milliers de souvenirs coûtent des fractions de centime.

### Recherche par mot-clé — un service ou un autre hébergeur

Neon a déprécié `pg_search`. Le correctif de migration a rendu le déploiement
possible en désactivant les index BM25 ; en contrepartie l'opérateur `@@@`
n'existe plus et les requêtes de recherche échouent.

`FTS_SEARCH_PROVIDER` n'accepte que `pg_search` ou `elasticsearch` — il n'y a
pas de mode « sans recherche », ni de repli en `ILIKE` dans le code.

Deux voies, toutes deux lourdes pour deux personnes :
- un **Elasticsearch** (`ES_URL`, `ES_API_KEY`) — un service de plus ;
- un **Postgres supportant pg_search** (ParadeDB) — migration de la base.

**C'est le seul manque sans solution légère.** À arbitrer selon l'usage réel.

## Ordre recommandé

1. Images — une variable, effet immédiat
2. Mémoire — un compte, si la mémoire automatique est jugée nécessaire
3. Recherche — à trancher plus tard, en connaissance de cause

Le profil d'agent (barre latérale → « Profil de l'agent ») couvre gratuitement
le besoin « que l'assistant sache qui je suis », sans embeddings ni recherche.
