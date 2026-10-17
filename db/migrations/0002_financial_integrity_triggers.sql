BEGIN;

CREATE FUNCTION validate_pocket_usage() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pocket_type pocket_kind;
BEGIN
  IF NEW.pocket_id IS NULL THEN RETURN NEW; END IF;
  SELECT kind INTO pocket_type FROM pockets WHERE user_id = NEW.user_id AND id = NEW.pocket_id;
  IF TG_TABLE_NAME = 'budget_lines' AND pocket_type <> 'virtual' THEN
    RAISE EXCEPTION 'A budget line can only use a virtual pocket';
  ELSIF TG_TABLE_NAME = 'transactions' AND pocket_type <> 'real' THEN
    RAISE EXCEPTION 'A transaction can only use a real pocket';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER budget_lines_virtual_pocket_trigger
  BEFORE INSERT OR UPDATE ON budget_lines FOR EACH ROW EXECUTE FUNCTION validate_pocket_usage();
CREATE TRIGGER transactions_real_pocket_trigger
  BEFORE INSERT OR UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION validate_pocket_usage();

CREATE FUNCTION reject_financial_hard_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Financial records must be soft-deleted for auditability';
END;
$$;

CREATE TRIGGER transactions_no_hard_delete BEFORE DELETE ON transactions FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER transfers_no_hard_delete BEFORE DELETE ON transfers FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER debts_no_hard_delete BEFORE DELETE ON debts FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();
CREATE TRIGGER debt_repayments_no_hard_delete BEFORE DELETE ON debt_repayments FOR EACH ROW EXECUTE FUNCTION reject_financial_hard_delete();

COMMIT;
