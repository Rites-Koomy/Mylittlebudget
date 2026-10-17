\set ON_ERROR_STOP on

-- Test PostgreSQL local uniquement : toutes les identités et valeurs sont fictives.
CREATE ROLE budget_perso_test_app NOSUPERUSER NOBYPASSRLS;
GRANT USAGE ON SCHEMA public, app TO budget_perso_test_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO budget_perso_test_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO budget_perso_test_app;

INSERT INTO app_users (id, access_subject, email) VALUES
  ('00000000-0000-0000-0000-000000000001', 'test-sub-a', 'a@example.invalid'),
  ('00000000-0000-0000-0000-000000000002', 'test-sub-b', 'b@example.invalid');

INSERT INTO accounts (id, user_id, name, kind) VALUES
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'Compte A principal', 'bank'),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', 'Compte A épargne', 'savings'),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000002', 'Compte B principal', 'bank');

INSERT INTO categories (id, user_id, name) VALUES
  ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000001', 'Tests');
INSERT INTO pockets (id, user_id, name, kind) VALUES
  ('00000000-0000-0000-0000-000000000041', '00000000-0000-0000-0000-000000000001', 'Poche réelle A', 'real'),
  ('00000000-0000-0000-0000-000000000042', '00000000-0000-0000-0000-000000000001', 'Enveloppe virtuelle A', 'virtual');
INSERT INTO budgets (id, user_id, month_start) VALUES
  ('00000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000001', '2026-10-01');
INSERT INTO debts (id, user_id, kind, counterparty, label, original_amount) VALUES
  ('00000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000001', 'owed_to_me', 'Test', 'Dette fictive', 100.0000);

SET ROLE budget_perso_test_app;

BEGIN;
SELECT set_config('app.user_id', '00000000-0000-0000-0000-000000000001', true);

DO $$
BEGIN
  IF (SELECT count(*) FROM accounts) <> 2 THEN RAISE EXCEPTION 'RLS should expose two accounts for user A'; END IF;
  IF (SELECT count(*) FROM accounts WHERE user_id = '00000000-0000-0000-0000-000000000002') <> 0 THEN RAISE EXCEPTION 'RLS leaked user B account'; END IF;
  IF (SELECT count(*) FROM app_users WHERE id = '00000000-0000-0000-0000-000000000002') <> 0 THEN RAISE EXCEPTION 'RLS leaked user B identity'; END IF;
END;
$$;

DO $$
BEGIN
  BEGIN
    INSERT INTO payment_cards (user_id, account_id, name)
      VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000021', 'Carte croisée');
    RAISE EXCEPTION 'Cross-user card relation should fail';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END;
$$;

INSERT INTO budget_lines (user_id, budget_id, category_id, pocket_id, allocated_amount)
  VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000051', '00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000042', 50.0000);

INSERT INTO payment_cards (id, user_id, account_id, name)
  VALUES ('00000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', 'Carte A');

DO $$
DECLARE rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO transactions (user_id, account_id, card_id, kind, amount, occurred_at, description)
      VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000013', 'expense', 10.0000, now(), 'Compte carte incohérent');
  EXCEPTION WHEN raise_exception THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Card and transaction accounts should match'; END IF;
  rejected := false;
  BEGIN
    INSERT INTO transactions (user_id, account_id, kind, amount, occurred_at, description)
      VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', 'adjustment', 1.0000, now(), 'Ajustement sans sens');
  EXCEPTION WHEN check_violation THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Adjustment direction should be mandatory'; END IF;
  rejected := false;
  BEGIN
    INSERT INTO transactions (user_id, account_id, kind, adjustment_direction, amount, occurred_at, description)
      VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', 'income', 'credit', 1.0000, now(), 'Direction sur revenu');
  EXCEPTION WHEN check_violation THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Adjustment direction should be absent from income'; END IF;
END;
$$;

DO $$
DECLARE rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO transactions (user_id, account_id, pocket_id, category_id, kind, amount, occurred_at, description)
      VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000042', '00000000-0000-0000-0000-000000000031', 'expense', 10.0000, now(), 'Dépense fictive');
  EXCEPTION WHEN raise_exception THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Virtual pocket transaction should fail'; END IF;
END;
$$;

INSERT INTO debt_repayments (id, user_id, debt_id, amount, occurred_at)
  VALUES ('00000000-0000-0000-0000-000000000071', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000061', 60.0000, now());
INSERT INTO debt_repayments (id, user_id, debt_id, amount, entry_kind, reverses_repayment_id, occurred_at)
  VALUES ('00000000-0000-0000-0000-000000000072', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000061', 60.0000, 'reversal', '00000000-0000-0000-0000-000000000071', now());

DO $$
DECLARE rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO debt_repayments (user_id, debt_id, amount, entry_kind, reverses_repayment_id, occurred_at)
      VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000061', 60.0000, 'reversal', '00000000-0000-0000-0000-000000000071', now());
    RAISE EXCEPTION 'Double reversal should fail';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO debt_repayments (user_id, debt_id, amount, occurred_at)
      VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000061', 101.0000, now());
  EXCEPTION WHEN raise_exception THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Debt overpayment should fail'; END IF;
  rejected := false;
  BEGIN
    UPDATE debt_repayments SET amount = 1.0000 WHERE id = '00000000-0000-0000-0000-000000000071';
  EXCEPTION WHEN raise_exception THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Original repayment update should fail'; END IF;
END;
$$;

DO $$
DECLARE audit_id bigint; rejected boolean := false;
BEGIN
  SELECT id INTO audit_id FROM audit_events
    WHERE user_id = '00000000-0000-0000-0000-000000000001' AND entity_type = 'accounts'
    ORDER BY id LIMIT 1;
  BEGIN
    UPDATE audit_events SET action = 'updated' WHERE id = audit_id;
  EXCEPTION WHEN raise_exception THEN rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Audit events should be append-only'; END IF;
END;
$$;

COMMIT;

-- SET LOCAL must disappear after COMMIT; a reused connection must not retain user A.
DO $$
BEGIN
  IF (SELECT count(*) FROM accounts) <> 0 THEN RAISE EXCEPTION 'RLS context leaked after transaction'; END IF;
END;
$$;

RESET ROLE;
SELECT 'financial hardening PostgreSQL tests passed' AS result;
