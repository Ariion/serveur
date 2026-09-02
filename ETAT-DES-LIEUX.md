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
| **Isolation des deux comptes** | **Vérifiée en base le 2 septembre 2026 : 7 contrôles sur 7 en OK** |
| Génération d'images | GPT Image 2, image produite et re-servie depuis R2 |

## Manquant, et pourquoi

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

## Piège rencontré : le nom de la variable OpenAI

La variable avait été saisie `OPEN_AI_KEY`. Le code lit `OPENAI_API_KEY`
(`packages/env/src/llm.ts:263`) et `OPEN_AI_KEY` n'est lu nulle part : la clé
n'atteignait donc jamais l'application. Le symptôme était trompeur — LobeChat
affiche « Clé API invalide » aussi bien quand la clé est absente (ligne 382 de
`openaiCompatibleFactory`) que quand OpenAI la refuse en 401 (ligne 1420),
alors que la clé était parfaitement valide et le crédit intact.

Rappel : dans Vercel, une variable n'est prise en compte qu'au **déploiement
suivant**. Renommer ou ajouter une variable sans redéployer ne change rien.

## Ordre recommandé

1. ~~Images~~ — fait, via GPT Image 2 (le crédit OpenAI couvre images ET mémoire)
2. Mémoire — à revérifier maintenant que la clé OpenAI arrive à l'application
3. Recherche — à trancher plus tard, en connaissance de cause

Le profil d'agent (barre latérale → « Profil de l'agent ») couvre gratuitement
le besoin « que l'assistant sache qui je suis », sans embeddings ni recherche.


## Résultat du contrôle d'isolation

Exécuté dans le SQL Editor de Neon sur la base de production, deux comptes
créés et chacun sa conversation témoin :

| Contrôle | Valeur | Verdict |
|---|---|---|
| Nombre de comptes | 2 | OK |
| Espaces partagés (doit être 0) | 0 | OK |
| Membres d'espaces partagés | 0 | OK |
| Conversations rattachées à un espace | 0 | OK |
| Images rattachées à un espace | 0 | OK |
| Messages chez le mauvais propriétaire | 0 | OK |
| Conversations sans propriétaire | 0 | OK |

Aucun workspace n'existe : le régime de partage est donc inatteignable, et
chaque lecture reste filtrée par `user_id`. Voir `ISOLATION.md` §1.

Note : le SQL Editor de Neon s'ouvre avec un exemple pré-rempli qui crée une
table `playing_with_neon`. Elle est sans rapport avec le schéma de LobeChat et
ne masque aucune de ses tables — les contrôles ont bien porté sur les vraies
données. Elle peut être supprimée : `DROP TABLE IF EXISTS playing_with_neon;`

**À relancer après chaque mise à jour de LobeChat.**
