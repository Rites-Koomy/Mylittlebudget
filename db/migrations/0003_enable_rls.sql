BEGIN;

CREATE SCHEMA IF NOT EXISTS app;
CREATE FUNCTION app.current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['accounts','payment_cards','pockets','categories','budgets','budget_lines','transfers','transactions','debts','debt_repayments','recurring_operations','csv_imports','csv_import_rows','audit_events']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('CREATE POLICY %I_user_isolation ON %I USING (user_id = app.current_user_id()) WITH CHECK (user_id = app.current_user_id())', table_name, table_name);
  END LOOP;
END;
$$;

COMMIT;
