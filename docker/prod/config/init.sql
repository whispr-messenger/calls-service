-- Initialisation de la base de données du service de calls (prod).
-- Ce script est exécuté une seule fois au premier démarrage du conteneur
-- `postgres` (monté via `/docker-entrypoint-initdb.d/init.sql`).
--
-- Les migrations Ecto créent les tables applicatives au démarrage du service
-- (cf. docker/prod/entrypoint.sh → WhisprCalls.Release.migrate/0).

-- Extensions requises ---------------------------------------------------------

-- Génération d'UUID pour les clés primaires `:binary_id`
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Fonctions cryptographiques (gen_random_uuid, digest, etc.)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Statistiques de requêtes pour le monitoring (pg_stat_statements)
-- Requires shared_preload_libraries — active automatiquement par Postgres 15
-- si l'image l'a pré-chargée. Silently ignored sinon.
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";

-- Commentaire identifiant la DB ----------------------------------------------
DO $$
BEGIN
  EXECUTE format(
    'COMMENT ON DATABASE %I IS ''WhisprMessenger calls service database''',
    current_database()
  );
END
$$;
