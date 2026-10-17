BEGIN;

CREATE TYPE transaction_adjustment_direction AS ENUM ('credit', 'debit');
CREATE TYPE debt_repayment_entry_kind AS ENUM ('original', 'reversal');

ALTER TABLE transactions
  ADD COLUMN adjustment_direction transaction_adjustment_direction;
ALTER TABLE transactions
  ADD CONSTRAINT transactions_adjustment_direction_check
  CHECK ((kind = 'adjustment') = (adjustment_direction IS NOT NULL));

ALTER TABLE recurring_operations
  ADD COLUMN adjustment_direction transaction_adjustment_direction;
ALTER TABLE recurring_operations
  ADD CONSTRAINT recurring_adjustment_direction_check
  CHECK ((kind = 'adjustment') = (adjustment_direction IS NOT NULL));

ALTER TABLE debt_repayments
  ADD COLUMN entry_kind debt_repayment_entry_kind NOT NULL DEFAULT 'original',
  ADD COLUMN reverses_repayment_id uuid;
ALTER TABLE debt_repayments
  ADD CONSTRAINT debt_repayment_reversal_target_fk
  FOREIGN KEY (user_id, reverses_repayment_id) REFERENCES debt_repayments(user_id, id);
ALTER TABLE debt_repayments
  ADD CONSTRAINT debt_repayment_reversal_shape_check
  CHECK ((entry_kind = 'original' AND reverses_repayment_id IS NULL)
      OR (entry_kind = 'reversal' AND reverses_repayment_id IS NOT NULL));
CREATE UNIQUE INDEX debt_repayment_one_reversal_idx
  ON debt_repayments(user_id, reverses_repayment_id)
  WHERE entry_kind = 'reversal';

ALTER TABLE accounts
  ADD CONSTRAINT accounts_eur_only_check CHECK (currency = 'EUR');
ALTER TABLE budgets
  ADD CONSTRAINT budgets_eur_only_check CHECK (currency = 'EUR');
ALTER TABLE debts
  ADD CONSTRAINT debts_eur_only_check CHECK (currency = 'EUR');

CREATE OR REPLACE FUNCTION validate_card_transaction_account() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE card_account uuid;
BEGIN
  IF NEW.card_id IS NULL THEN RETURN NEW; END IF;
  SELECT account_id INTO card_account
    FROM payment_cards
    WHERE user_id = NEW.user_id AND id = NEW.card_id;
  IF card_account IS NOT NULL AND card_account <> NEW.account_id THEN
    RAISE EXCEPTION 'Transaction account must match the linked card account';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER transactions_card_account_trigger
  BEFORE INSERT OR UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION validate_card_transaction_account();

CREATE OR REPLACE FUNCTION validate_debt_repayment_entry() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original_amount numeric(19,4); original_kind debt_repayment_entry_kind;
BEGIN
  IF NEW.entry_kind = 'original' THEN RETURN NEW; END IF;
  SELECT amount, entry_kind INTO original_amount, original_kind
    FROM debt_repayments
    WHERE user_id = NEW.user_id AND id = NEW.reverses_repayment_id;
  IF original_kind IS NULL OR original_kind <> 'original' THEN
    RAISE EXCEPTION 'A reversal must target an original repayment';
  END IF;
  IF NEW.debt_id IS DISTINCT FROM (SELECT debt_id FROM debt_repayments WHERE user_id = NEW.user_id AND id = NEW.reverses_repayment_id)
     OR NEW.amount <> original_amount THEN
    RAISE EXCEPTION 'A reversal must match its original repayment';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER debt_repayment_entry_validation_trigger
  BEFORE INSERT ON debt_repayments
  FOR EACH ROW EXECUTE FUNCTION validate_debt_repayment_entry();

CREATE OR REPLACE FUNCTION validate_debt_repayment_total() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE principal numeric(19,4); active_total numeric(19,4);
BEGIN
  PERFORM 1 FROM debts WHERE user_id = NEW.user_id AND id = NEW.debt_id FOR UPDATE;
  SELECT d.original_amount,
         COALESCE(SUM(CASE WHEN r.entry_kind = 'original' THEN r.amount ELSE -r.amount END), 0)
    INTO principal, active_total
    FROM debts d
    LEFT JOIN debt_repayments r ON r.user_id = d.user_id AND r.debt_id = d.id
    WHERE d.user_id = NEW.user_id AND d.id = NEW.debt_id
    GROUP BY d.original_amount;
  IF active_total < 0 OR active_total > principal THEN
    RAISE EXCEPTION 'Debt repayment total exceeds the principal or becomes negative';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER debt_repayment_total_trigger
  AFTER INSERT ON debt_repayments
  DEFERRABLE INITIALLY IMMEDIATE
  FOR EACH ROW EXECUTE FUNCTION validate_debt_repayment_total();

CREATE OR REPLACE FUNCTION prevent_repayment_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Repayments are immutable; add a reversal entry instead';
END;
$$;

CREATE TRIGGER debt_repayment_no_update_trigger
  BEFORE UPDATE ON debt_repayments
  FOR EACH ROW EXECUTE FUNCTION prevent_repayment_update();

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER app_users_updated_at_trigger BEFORE UPDATE ON app_users FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER accounts_updated_at_trigger BEFORE UPDATE ON accounts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER payment_cards_updated_at_trigger BEFORE UPDATE ON payment_cards FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER pockets_updated_at_trigger BEFORE UPDATE ON pockets FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER budgets_updated_at_trigger BEFORE UPDATE ON budgets FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER transfers_updated_at_trigger BEFORE UPDATE ON transfers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER transactions_updated_at_trigger BEFORE UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER debts_updated_at_trigger BEFORE UPDATE ON debts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER recurring_operations_updated_at_trigger BEFORE UPDATE ON recurring_operations FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION record_financial_audit_event() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit_events(user_id, entity_type, entity_id, action, new_data)
      VALUES (NEW.user_id, TG_TABLE_NAME, NEW.id, 'created', to_jsonb(NEW));
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO audit_events(user_id, entity_type, entity_id, action, old_data, new_data)
      VALUES (NEW.user_id, TG_TABLE_NAME, NEW.id,
        CASE WHEN (to_jsonb(OLD)->>'deleted_at') IS NULL AND (to_jsonb(NEW)->>'deleted_at') IS NOT NULL THEN 'deleted' ELSE 'updated' END,
        to_jsonb(OLD), to_jsonb(NEW));
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER accounts_audit_trigger AFTER INSERT OR UPDATE ON accounts FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER payment_cards_audit_trigger AFTER INSERT OR UPDATE ON payment_cards FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER pockets_audit_trigger AFTER INSERT OR UPDATE ON pockets FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER categories_audit_trigger AFTER INSERT OR UPDATE ON categories FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER budgets_audit_trigger AFTER INSERT OR UPDATE ON budgets FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER budget_lines_audit_trigger AFTER INSERT OR UPDATE ON budget_lines FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER transfers_audit_trigger AFTER INSERT OR UPDATE ON transfers FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER transactions_audit_trigger AFTER INSERT OR UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER debt_repayments_audit_trigger AFTER INSERT ON debt_repayments FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER debts_audit_trigger AFTER INSERT OR UPDATE ON debts FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER recurring_operations_audit_trigger AFTER INSERT OR UPDATE ON recurring_operations FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER csv_imports_audit_trigger AFTER INSERT OR UPDATE ON csv_imports FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();
CREATE TRIGGER csv_import_rows_audit_trigger AFTER INSERT OR UPDATE ON csv_import_rows FOR EACH ROW EXECUTE FUNCTION record_financial_audit_event();

CREATE OR REPLACE FUNCTION reject_audit_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Audit events are append-only';
END;
$$;

CREATE TRIGGER audit_events_no_update_trigger BEFORE UPDATE ON audit_events FOR EACH ROW EXECUTE FUNCTION reject_audit_mutation();
CREATE TRIGGER audit_events_no_delete_trigger BEFORE DELETE ON audit_events FOR EACH ROW EXECUTE FUNCTION reject_audit_mutation();

CREATE TRIGGER accounts_no_hard_delete BEFORE DELETE ON accounts FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER payment_cards_no_hard_delete BEFORE DELETE ON payment_cards FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER pockets_no_hard_delete BEFORE DELETE ON pockets FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER categories_no_hard_delete BEFORE DELETE ON categories FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER budgets_no_hard_delete BEFORE DELETE ON budgets FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER budget_lines_no_hard_delete BEFORE DELETE ON budget_lines FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER recurring_operations_no_hard_delete BEFORE DELETE ON recurring_operations FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER csv_imports_no_hard_delete BEFORE DELETE ON csv_imports FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER csv_import_rows_no_hard_delete BEFORE DELETE ON csv_import_rows FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();

CREATE UNIQUE INDEX csv_import_rows_match_once_idx
  ON csv_import_rows(user_id, matched_transaction_id)
  WHERE matched_transaction_id IS NOT NULL;
ALTER TABLE csv_import_rows
  ADD CONSTRAINT csv_import_row_match_status_check
  CHECK ((status IN ('matched', 'imported')) = (matched_transaction_id IS NOT NULL));
CREATE INDEX csv_import_rows_preview_idx
  ON csv_import_rows(user_id, import_id, row_fingerprint, status);

ALTER TABLE app_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_users FORCE ROW LEVEL SECURITY;
CREATE POLICY app_users_self_isolation
  ON app_users
  USING (id = app.current_user_id())
  WITH CHECK (id = app.current_user_id());

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['accounts','payment_cards','pockets','categories','budgets','budget_lines','transfers','transactions','debts','debt_repayments','recurring_operations','csv_imports','csv_import_rows','audit_events']
  LOOP
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', table_name);
  END LOOP;
END;
$$;

COMMIT;
