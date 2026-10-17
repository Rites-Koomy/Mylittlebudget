BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE account_kind AS ENUM ('bank', 'cash', 'savings', 'other');
CREATE TYPE pocket_kind AS ENUM ('real', 'virtual');
CREATE TYPE transaction_kind AS ENUM ('income', 'expense', 'adjustment');
CREATE TYPE debt_kind AS ENUM ('owed_to_me', 'owed_by_me');
CREATE TYPE recurring_frequency AS ENUM ('weekly', 'monthly', 'quarterly', 'yearly');
CREATE TYPE import_row_status AS ENUM ('pending', 'duplicate_candidate', 'matched', 'ignored', 'imported');

CREATE TABLE app_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  access_subject text NOT NULL UNIQUE,
  email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  name text NOT NULL CHECK (length(trim(name)) > 0),
  kind account_kind NOT NULL,
  currency char(3) NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
  opening_balance numeric(19,4) NOT NULL DEFAULT 0,
  is_savings boolean NOT NULL DEFAULT false,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id)
);

CREATE TABLE payment_cards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  account_id uuid,
  name text NOT NULL CHECK (length(trim(name)) > 0),
  last_four char(4) CHECK (last_four IS NULL OR last_four ~ '^[0-9]{4}$'),
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, account_id) REFERENCES accounts(user_id, id)
);

CREATE TABLE pockets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  name text NOT NULL CHECK (length(trim(name)) > 0),
  kind pocket_kind NOT NULL,
  account_id uuid,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, account_id) REFERENCES accounts(user_id, id),
  CHECK (kind = 'real' OR account_id IS NULL)
);

CREATE TABLE categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  parent_id uuid,
  name text NOT NULL CHECK (length(trim(name)) > 0),
  is_archived boolean NOT NULL DEFAULT false,
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, parent_id) REFERENCES categories(user_id, id)
);

CREATE TABLE budgets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  month_start date NOT NULL CHECK (extract(day from month_start) = 1),
  currency char(3) NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  UNIQUE (user_id, month_start)
);

CREATE TABLE budget_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  budget_id uuid NOT NULL,
  category_id uuid NOT NULL,
  pocket_id uuid,
  allocated_amount numeric(19,4) NOT NULL CHECK (allocated_amount >= 0),
  UNIQUE (user_id, id),
  UNIQUE (budget_id, category_id, pocket_id),
  FOREIGN KEY (user_id, budget_id) REFERENCES budgets(user_id, id),
  FOREIGN KEY (user_id, category_id) REFERENCES categories(user_id, id),
  FOREIGN KEY (user_id, pocket_id) REFERENCES pockets(user_id, id)
);

CREATE TABLE transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  from_account_id uuid NOT NULL,
  to_account_id uuid NOT NULL,
  amount numeric(19,4) NOT NULL CHECK (amount > 0),
  occurred_at timestamptz NOT NULL,
  note text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, from_account_id) REFERENCES accounts(user_id, id),
  FOREIGN KEY (user_id, to_account_id) REFERENCES accounts(user_id, id),
  CHECK (from_account_id <> to_account_id)
);

CREATE TABLE transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  account_id uuid NOT NULL,
  card_id uuid,
  pocket_id uuid,
  category_id uuid,
  kind transaction_kind NOT NULL,
  amount numeric(19,4) NOT NULL CHECK (amount > 0),
  occurred_at timestamptz NOT NULL,
  description text NOT NULL CHECK (length(trim(description)) > 0),
  external_reference text,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, account_id) REFERENCES accounts(user_id, id),
  FOREIGN KEY (user_id, card_id) REFERENCES payment_cards(user_id, id),
  FOREIGN KEY (user_id, pocket_id) REFERENCES pockets(user_id, id),
  FOREIGN KEY (user_id, category_id) REFERENCES categories(user_id, id)
);

CREATE TABLE debts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  kind debt_kind NOT NULL,
  counterparty text NOT NULL CHECK (length(trim(counterparty)) > 0),
  label text NOT NULL CHECK (length(trim(label)) > 0),
  original_amount numeric(19,4) NOT NULL CHECK (original_amount > 0),
  currency char(3) NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id)
);

CREATE TABLE debt_repayments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  debt_id uuid NOT NULL,
  transaction_id uuid,
  amount numeric(19,4) NOT NULL CHECK (amount > 0),
  occurred_at timestamptz NOT NULL,
  note text,
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, debt_id) REFERENCES debts(user_id, id),
  FOREIGN KEY (user_id, transaction_id) REFERENCES transactions(user_id, id)
);

CREATE TABLE recurring_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  account_id uuid NOT NULL,
  category_id uuid,
  kind transaction_kind NOT NULL,
  amount numeric(19,4) NOT NULL CHECK (amount > 0),
  description text NOT NULL CHECK (length(trim(description)) > 0),
  frequency recurring_frequency NOT NULL,
  next_occurrence date NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, account_id) REFERENCES accounts(user_id, id),
  FOREIGN KEY (user_id, category_id) REFERENCES categories(user_id, id)
);

CREATE TABLE csv_imports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  account_id uuid NOT NULL,
  source_filename text NOT NULL,
  file_fingerprint text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, id),
  UNIQUE (user_id, file_fingerprint),
  FOREIGN KEY (user_id, account_id) REFERENCES accounts(user_id, id)
);

CREATE TABLE csv_import_rows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES app_users(id),
  import_id uuid NOT NULL,
  row_number integer NOT NULL CHECK (row_number > 0),
  raw_data jsonb NOT NULL,
  normalized_date date,
  normalized_amount numeric(19,4),
  normalized_description text,
  row_fingerprint text NOT NULL,
  status import_row_status NOT NULL DEFAULT 'pending',
  matched_transaction_id uuid,
  UNIQUE (user_id, id),
  UNIQUE (import_id, row_number),
  FOREIGN KEY (user_id, import_id) REFERENCES csv_imports(user_id, id),
  FOREIGN KEY (user_id, matched_transaction_id) REFERENCES transactions(user_id, id)
);

CREATE TABLE audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES app_users(id),
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('created', 'updated', 'deleted', 'restored', 'matched')),
  old_data jsonb,
  new_data jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX accounts_user_active_idx ON accounts(user_id) WHERE deleted_at IS NULL;
CREATE INDEX transactions_account_date_idx ON transactions(user_id, account_id, occurred_at) WHERE deleted_at IS NULL;
CREATE INDEX transactions_category_date_idx ON transactions(user_id, category_id, occurred_at) WHERE deleted_at IS NULL;
CREATE INDEX transfers_account_date_idx ON transfers(user_id, from_account_id, occurred_at) WHERE deleted_at IS NULL;
CREATE INDEX transfers_destination_date_idx ON transfers(user_id, to_account_id, occurred_at) WHERE deleted_at IS NULL;
CREATE INDEX budget_lines_budget_idx ON budget_lines(user_id, budget_id);
CREATE INDEX csv_rows_fingerprint_idx ON csv_import_rows(user_id, row_fingerprint);
CREATE INDEX audit_events_entity_idx ON audit_events(user_id, entity_type, entity_id, occurred_at);

COMMIT;
