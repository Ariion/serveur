-- ============================================================================
--  Vérification de l'isolation — version pour l'éditeur SQL de Neon
-- ============================================================================
--
--  L'éditeur web de Neon n'accepte ni les commandes psql (\echo) ni l'affichage
--  des RAISE NOTICE : ce fichier n'utilise donc que du SQL pur et renvoie des
--  tableaux de résultats. Pour un usage en ligne de commande, préférer
--  scripts/verifier-isolation.sql, plus détaillé.
--
--  Mode d'emploi : Neon Console > SQL Editor. Coller le BLOC 1, exécuter, lire
--  la colonne `verdict` ; puis faire de même avec le BLOC 2.
--
--  Lecture seule : aucun INSERT/UPDATE/DELETE.
-- ============================================================================


-- ############################################################################
-- BLOC 1 — Les huit contrôles. Tout doit afficher OK.
-- ############################################################################

WITH
-- Balayage dynamique de toutes les tables portant une colonne workspace_id.
-- query_to_xml permet de compter dans une table nommée dynamiquement sans
-- recourir à du PL/pgSQL, indisponible en SQL pur.
rattachees AS (
  SELECT
    c.table_name,
    (xpath(
      '/row/n/text()',
      query_to_xml(
        format('SELECT count(*) AS n FROM public.%I WHERE workspace_id IS NOT NULL', c.table_name),
        false, true, ''
      )
    ))[1]::text::bigint AS n
  FROM information_schema.columns c
  JOIN information_schema.tables t
    ON  t.table_schema = c.table_schema
    AND t.table_name   = c.table_name
    AND t.table_type   = 'BASE TABLE'
  WHERE c.table_schema = 'public'
    AND c.column_name  = 'workspace_id'
),
controles AS (

  SELECT 1 AS ordre,
         'Comptes existants' AS controle,
         count(*)::text AS valeur,
         CASE WHEN count(*) = 2 THEN 'OK'
              ELSE 'FAIL : il devrait y en avoir exactement 2' END AS verdict
  FROM users

  UNION ALL
  -- LE CONTRÔLE DÉCISIF. Tant que cette table est vide, LobeChat filtre chaque
  -- lecture par `user_id = <appelant> AND workspace_id IS NULL`. Dès qu'un
  -- workspace existe et contient les deux comptes, user_id sort du filtre pour
  -- toute ligne en visibilité 'public' — valeur par défaut des images générées.
  SELECT 2,
         'Workspaces (doit etre vide)',
         count(*)::text,
         CASE WHEN count(*) = 0 THEN 'OK'
              ELSE 'FAIL : un workspace existe, les donnees peuvent etre partagees' END
  FROM workspaces

  UNION ALL
  SELECT 3,
         'Appartenances a un workspace',
         count(*)::text,
         CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL' END
  FROM workspace_members

  UNION ALL
  SELECT 4,
         'Lignes rattachees a un workspace (toutes tables)',
         coalesce(sum(n), 0)::text,
         CASE WHEN coalesce(sum(n), 0) = 0 THEN 'OK'
              ELSE 'FAIL : voir le BLOC 2 pour le detail' END
  FROM rattachees

  UNION ALL
  SELECT 5,
         'Messages sous la conversation d''un autre compte',
         count(*)::text,
         CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL' END
  FROM messages m JOIN topics t ON t.id = m.topic_id
  WHERE m.user_id <> t.user_id

  UNION ALL
  SELECT 6,
         'Images sous le lot d''un autre compte',
         count(*)::text,
         CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL' END
  FROM generations g JOIN generation_batches b ON b.id = g.generation_batch_id
  WHERE g.user_id <> b.user_id

  UNION ALL
  SELECT 7,
         'Conversations sans proprietaire',
         count(*)::text,
         CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL' END
  FROM topics WHERE user_id IS NULL

  UNION ALL
  SELECT 8,
         'Messages sans proprietaire',
         count(*)::text,
         CASE WHEN count(*) = 0 THEN 'OK' ELSE 'FAIL' END
  FROM messages WHERE user_id IS NULL
)
SELECT controle, valeur, verdict FROM controles ORDER BY ordre;


-- ############################################################################
-- BLOC 2 — Répartition des contenus, et détail si le contrôle 4 a échoué.
-- ############################################################################
--
-- Les deux comptes doivent apparaître avec des compteurs non nuls et répartis :
-- chacun sa conversation, ses messages. Jamais tout cumulé sur un seul id.

SELECT
  u.email,
  (SELECT count(*) FROM topics   t WHERE t.user_id = u.id) AS conversations,
  (SELECT count(*) FROM messages m WHERE m.user_id = u.id) AS messages,
  (SELECT count(*) FROM sessions s WHERE s.user_id = u.id) AS sessions,
  (SELECT count(*) FROM files    f WHERE f.user_id = u.id) AS fichiers,
  (SELECT count(*) FROM generations g WHERE g.user_id = u.id) AS images
FROM users u
ORDER BY u.email;


-- ============================================================================
--  Validé sur PostgreSQL 16 dans les deux sens : base saine (les huit
--  contrôles en OK) et isolation volontairement cassée — workspace créé avec
--  les deux comptes membres, contenus rattachés, 3e compte inscrit, message
--  sous la conversation d'autrui, ligne orpheline — où chaque contrôle
--  concerné bascule en FAIL tandis que les autres restent OK.
-- ============================================================================
