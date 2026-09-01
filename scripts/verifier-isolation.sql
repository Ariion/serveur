-- ============================================================================
--  Vérification de l'isolation entre les deux comptes LobeChat
-- ============================================================================
--
--  À exécuter APRÈS le test manuel (2 comptes créés, 1 conversation + 1 image
--  générée sur chacun), directement sur la base Neon :
--
--      psql "$DATABASE_URL" -f scripts/verifier-isolation.sql
--
--  ou en collant le contenu dans Neon Console > SQL Editor.
--
--  Chaque bloc renvoie une colonne `verdict` : tout doit afficher OK.
--  Un seul FAIL = ne pas considérer le déploiement comme terminé.
--
--  Ce script est en lecture seule : aucun INSERT/UPDATE/DELETE.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Inventaire des comptes
-- ----------------------------------------------------------------------------
-- Doit lister exactement 2 lignes : toi et ta compagne.
-- Une 3e ligne = quelqu'un d'autre s'est inscrit -> AUTH_ALLOWED_EMAILS est mal
-- réglé ou absent. Voir ISOLATION.md §"Fermer les inscriptions".

\echo '=== 1. Comptes existants (doit en montrer exactement 2) ==='
SELECT
  id,
  email,
  created_at,
  CASE WHEN count(*) OVER () = 2 THEN 'OK' ELSE 'FAIL: nombre de comptes != 2' END AS verdict
FROM users
ORDER BY created_at;


-- ----------------------------------------------------------------------------
-- 2. Aucun workspace ne doit exister
-- ----------------------------------------------------------------------------
-- C'EST LE CONTRÔLE LE PLUS IMPORTANT.
--
-- LobeChat a deux régimes de visibilité (packages/database/src/utils/workspace.ts) :
--   * workspace_id IS NULL  -> "personal mode" : le filtre SQL est
--                              `user_id = <appelant> AND workspace_id IS NULL`.
--                              Isolation stricte par utilisateur.
--   * workspace_id NOT NULL -> "workspace mode" : le filtre devient
--                              `workspace_id = <workspace>` et user_id SORT du
--                              filtre pour toutes les lignes dont la visibilité
--                              est 'public' ou NULL.
--
-- Or generation_topics.visibility vaut 'public' PAR DÉFAUT. Donc deux comptes
-- placés dans le même workspace voient mutuellement leurs images générées —
-- par conception, pas par bug. Tant qu'aucun workspace n'existe, ce régime est
-- inatteignable (workspace_id porte une clé étrangère vers workspaces.id).

\echo '=== 2. Workspaces (la table DOIT etre vide) ==='
SELECT
  count(*) AS nb_workspaces,
  CASE WHEN count(*) = 0
       THEN 'OK: aucun workspace, mode personnel garanti'
       ELSE 'FAIL: un workspace existe -> les donnees peuvent etre partagees'
  END AS verdict
FROM workspaces;

\echo '=== 2b. Membres de workspace (doit etre vide) ==='
SELECT
  count(*) AS nb_membres,
  CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL: appartenance a un workspace detectee' END AS verdict
FROM workspace_members;


-- ----------------------------------------------------------------------------
-- 3. Balayage dynamique : aucune ligne rattachée à un workspace
-- ----------------------------------------------------------------------------
-- Plutôt que d'énumérer les tables à la main (elles changent à chaque version
-- amont), on parcourt toutes les tables qui possèdent une colonne workspace_id
-- et on compte les lignes non nulles. Ce contrôle reste valable après une mise
-- à jour de LobeChat qui ajouterait de nouvelles tables.

\echo '=== 3. Lignes rattachees a un workspace, toutes tables (doit etre vide) ==='
DO $$
DECLARE
  r          record;
  n          bigint;
  total      bigint := 0;
  coupables  text   := '';
BEGIN
  FOR r IN
    SELECT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema
     AND t.table_name   = c.table_name
     AND t.table_type   = 'BASE TABLE'
    WHERE c.table_schema = 'public'
      AND c.column_name  = 'workspace_id'
    ORDER BY c.table_name
  LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE workspace_id IS NOT NULL', r.table_name)
      INTO n;

    IF n > 0 THEN
      total     := total + n;
      coupables := coupables || format(E'\n  - %s : %s ligne(s)', r.table_name, n);
    END IF;
  END LOOP;

  IF total = 0 THEN
    RAISE NOTICE 'OK: aucune ligne rattachee a un workspace dans toute la base.';
  ELSE
    RAISE WARNING 'FAIL: % ligne(s) rattachee(s) a un workspace :%', total, coupables;
  END IF;
END $$;


-- ----------------------------------------------------------------------------
-- 4. Répartition des contenus par compte
-- ----------------------------------------------------------------------------
-- Contrôle de cohérence du test manuel : après avoir lancé une conversation et
-- généré une image sur chaque compte, les deux comptes doivent apparaître avec
-- des compteurs non nuls, et les totaux doivent se répartir — jamais se cumuler
-- sur un seul id.

\echo '=== 4. Contenus par compte ==='
SELECT
  u.email,
  (SELECT count(*) FROM topics            t WHERE t.user_id = u.id) AS conversations,
  (SELECT count(*) FROM messages          m WHERE m.user_id = u.id) AS messages,
  (SELECT count(*) FROM sessions          s WHERE s.user_id = u.id) AS sessions,
  (SELECT count(*) FROM generation_topics g WHERE g.user_id = u.id) AS sujets_images,
  (SELECT count(*) FROM generations       g WHERE g.user_id = u.id) AS images,
  (SELECT count(*) FROM files             f WHERE f.user_id = u.id) AS fichiers
FROM users u
ORDER BY u.email;


-- ----------------------------------------------------------------------------
-- 5. Contamination croisée : un message sous la conversation d'autrui
-- ----------------------------------------------------------------------------
-- Détecte une ligne fille dont le propriétaire diffère de celui de son parent.
-- Ce cas ne devrait jamais se produire ; s'il apparaît, l'isolation applicative
-- a été contournée quelque part.

\echo '=== 5. Messages dont le proprietaire differe de celui de la conversation ==='
SELECT
  count(*) AS incoherences,
  CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL: message rattache a la conversation d''un autre compte' END AS verdict
FROM messages m
JOIN topics t ON t.id = m.topic_id
WHERE m.user_id <> t.user_id;

\echo '=== 5b. Images dont le proprietaire differe de celui du sujet ==='
SELECT
  count(*) AS incoherences,
  CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL: image rattachee au sujet d''un autre compte' END AS verdict
FROM generations g
JOIN generation_batches b ON b.id = g.generation_batch_id
WHERE g.user_id <> b.user_id;


-- ----------------------------------------------------------------------------
-- 6. Contenus orphelins
-- ----------------------------------------------------------------------------
-- Une ligne sans user_id échapperait au filtre `user_id = <appelant>`.

\echo '=== 6. Conversations/messages sans proprietaire ==='
SELECT 'topics'   AS table_, count(*) AS orphelins,
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL' END AS verdict
FROM topics   WHERE user_id IS NULL
UNION ALL
SELECT 'messages', count(*),
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL' END
FROM messages WHERE user_id IS NULL;


-- ============================================================================
--  Note : ce script a été validé sur PostgreSQL 16 contre un jeu d'essai
--  reproduisant le schéma de LobeChat v2.2.13, dans les deux sens — base saine
--  (tous les blocs en OK) et isolation volontairement cassée (workspace créé
--  avec les deux comptes membres, 3e compte inscrit, message rattaché à la
--  conversation d'autrui, ligne orpheline), où chaque contrôle concerné bascule
--  bien en FAIL.
-- ============================================================================
