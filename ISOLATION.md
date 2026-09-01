# Isolation des deux comptes — ce qui la garantit, ce qui la casserait

Audit du code de `lobehub/lobe-chat` **v2.2.13** (commit `3ba4e60`, 1er septembre 2026).
Les chemins de fichiers ci-dessous renvoient au dépôt amont.

---

## 1. Comment LobeChat sépare les données

Toutes les tables de contenu (`topics`, `messages`, `sessions`, `agents`,
`files`, `generation_topics`, `generations`…) portent deux colonnes :
`user_id` et `workspace_id`.

Le filtre appliqué à chaque lecture est construit par une seule fonction,
`buildWorkspaceWhere` — `packages/database/src/utils/workspace.ts`. Elle a
**deux régimes**, et c'est toute la question :

### Régime « personnel » — `workspace_id IS NULL`

```sql
WHERE user_id = <utilisateur appelant> AND workspace_id IS NULL
```

Chaque ligne appartient à un utilisateur et un seul. Aucune requête ne peut
remonter les lignes d'un autre compte. **C'est le régime que vous voulez, et
c'est celui obtenu par défaut** tant qu'aucun workspace n'est créé.

### Régime « workspace » — `workspace_id` renseigné

```sql
WHERE workspace_id = <workspace>
  AND (visibility IS NULL OR visibility = 'public'
       OR (visibility = 'private' AND user_id = <appelant>))
```

`user_id` **sort du filtre** pour toute ligne dont la visibilité est `public`
ou `NULL`. Autrement dit : deux comptes membres du même workspace se voient
mutuellement. Ce n'est pas un bug, c'est la fonctionnalité d'équipe.

Et le défaut penche du mauvais côté :
`generation_topics.visibility` vaut **`'public'`** par défaut
(`packages/database/src/schemas/generation.ts`) — donc les images générées
seraient partagées d'office entre membres d'un même workspace.

### Conclusion

> **La seule chose qui sépare vos deux comptes, c'est qu'aucun workspace
> n'existe.** Tant que la table `workspaces` est vide, le régime partagé est
> inatteignable : `workspace_id` porte une clé étrangère vers `workspaces.id`,
> donc aucune valeur ne peut y être écrite sans qu'un workspace existe
> réellement.

C'est vérifiable en une requête (`scripts/verifier-isolation.sql`, contrôle 2),
et c'est le contrôle à refaire après chaque mise à jour de LobeChat.

**Ne créez donc jamais de workspace, et n'invitez jamais l'un des comptes dans
le workspace de l'autre.** Si l'interface propose un jour « créer un espace de
travail » ou « inviter un membre », c'est précisément l'action à ne pas faire :
elle ferait basculer les données concernées dans le régime partagé.

---

## 2. Le point faible réel : le stockage des fichiers

C'est le seul écart sérieux entre « la base est bien cloisonnée » et
« tout est cloisonné ».

Les clés d'objets S3 sont construites dans `src/services/upload.ts` :

```
files/<horodatage en heures>/<uuid v4>.<extension>
```

**L'identifiant du propriétaire n'y figure pas.** L'autorisation vit
uniquement dans la base : c'est Postgres qui dit « ce fichier appartient à ce
compte », le bucket, lui, ne sait rien.

Conséquence pratique, selon la configuration :

| Configuration | Ce qui se passe |
|---|---|
| `S3_SET_ACL` et `S3_PUBLIC_DOMAIN` **absents** *(recommandé)* | Les fichiers sont servis par des URLs pré-signées expirant après 2 h, délivrées au seul utilisateur authentifié. Le bucket reste privé. |
| `S3_SET_ACL=1` et/ou `S3_PUBLIC_DOMAIN` défini | Chaque objet est écrit en `public-read` et servi par une URL permanente. **Toute personne connaissant une URL lit le fichier sans authentification** — y compris une image générée par l'autre compte. |

Le code des URLs signées est dans `apps/server/src/modules/S3/index.ts`
(`createPreSignedUrlForPreview`, expiration `S3_PREVIEW_URL_EXPIRE_IN`).

**Donc : laissez ces deux variables non définies.** Beaucoup de tutoriels
LobeChat les activent pour « que les images s'affichent » — ce n'est pas
nécessaire, et c'est exactement ce qui ouvrirait vos images générées.

À noter que même dans la configuration recommandée, l'isolation des fichiers
repose sur des UUID non devinables plutôt que sur un contrôle d'accès au
niveau du bucket. Entre vous deux, cela suffit largement : aucun des deux ne
peut énumérer les objets de l'autre. Mais si une URL signée est transmise à un
tiers avant expiration, elle reste utilisable jusqu'à son échéance.

---

## 3. Fermer les inscriptions

Sans configuration, **le site est en inscription ouverte** : n'importe qui
tombant sur l'URL peut se créer un compte sur votre instance. Ses données
seraient isolées des vôtres, mais il consommerait vos clés API et occuperait
votre base.

Le verrou est `AUTH_ALLOWED_EMAILS`
(`src/libs/better-auth/plugins/email-whitelist.ts`) : la création d'un
utilisateur est interceptée avant écriture en base et rejetée
(`EMAIL_NOT_ALLOWED`) si l'adresse n'est pas dans la liste.

```
AUTH_ALLOWED_EMAILS=ton.adresse@exemple.fr,son.adresse@exemple.fr
```

Attention au piège : **une entrée sans `@` est traitée comme un domaine
entier**. `AUTH_ALLOWED_EMAILS=gmail.com` autoriserait tous les comptes Gmail
du monde. Mettez les deux adresses complètes.

---

## 4. Ce qui n'est plus un risque

Vous vouliez éviter le mode `ACCESS_CODE`, le mot de passe unique partagé qui
ne sépare pas les utilisateurs. **Cette variable n'existe plus** : aucune
occurrence de `ACCESS_CODE` dans le code de la v2, elle a été entièrement
retirée. Il n'y a rien à désactiver et aucun moyen d'y retomber par erreur de
configuration.

De même, `NEXT_PUBLIC_SERVICE_MODE` a disparu. En v2, c'est la simple présence
de `DATABASE_URL` qui met l'application en mode serveur — et son absence fait
échouer le démarrage plutôt que de basculer silencieusement en mode local.

---

## 5. Limite de cet audit

J'ai lu le modèle de données, la fonction de filtrage commune, la construction
du contexte d'authentification et la couche de stockage. Je n'ai **pas** audité
un par un les quelque cent routeurs applicatifs, et je n'ai pas exécuté
l'application (le monorepo v2 ne se construit pas dans le temps d'une session).

Un point mérite d'être signalé en toute franchise : pour une requête
authentifiée par cookie, le `workspaceId` du contexte est lu directement dans
l'en-tête HTTP `X-Workspace-Id` fourni par le client
(`packages/trpc/src/lambda/context.ts`), sans vérification d'appartenance à ce
niveau — la vérification existe pour les clés d'API, pas sur ce chemin-là. Le
contrôle d'appartenance a lieu plus bas dans certains routeurs, que je n'ai pas
tous parcourus.

Cela ne vous expose pas, précisément parce que la table `workspaces` est vide :
un `X-Workspace-Id` inventé ne correspond à aucune ligne et ne ramène rien.
Mais c'est une raison de plus de ne jamais créer de workspace, et de refaire
tourner `scripts/verifier-isolation.sql` après chaque mise à jour.

La vérification qui compte vraiment reste le test manuel à deux comptes —
procédure en §6 de `DEPLOIEMENT.md`.
