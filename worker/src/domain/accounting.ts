import Decimal from 'decimal.js';

export type AccountKind = 'bank' | 'cash' | 'savings' | 'other';
export type AdjustmentDirection = 'credit' | 'debit';
export type MoneyInput = Decimal.Value;

export const MONEY_DECIMAL_PLACES = 4;

export function toMoney(value: MoneyInput): Decimal {
  return new Decimal(value).toDecimalPlaces(MONEY_DECIMAL_PLACES, Decimal.ROUND_HALF_UP);
}

export function moneyToString(value: MoneyInput): string {
  return toMoney(value).toFixed(MONEY_DECIMAL_PLACES);
}

export type AccountSnapshot = {
  openingBalance: MoneyInput;
  income: MoneyInput;
  expenses: MoneyInput;
  adjustments: Array<{ direction: AdjustmentDirection; amount: MoneyInput }>;
  transfersIn: MoneyInput;
  transfersOut: MoneyInput;
};

export function calculateAccountBalance(snapshot: AccountSnapshot): Decimal {
  const adjustmentTotal = snapshot.adjustments.reduce(
    (total, adjustment) => adjustment.direction === 'credit'
      ? total.plus(toMoney(adjustment.amount))
      : total.minus(toMoney(adjustment.amount)),
    new Decimal(0),
  );
  return toMoney(snapshot.openingBalance)
    .plus(toMoney(snapshot.income))
    .minus(toMoney(snapshot.expenses))
    .plus(adjustmentTotal)
    .plus(toMoney(snapshot.transfersIn))
    .minus(toMoney(snapshot.transfersOut))
    .toDecimalPlaces(MONEY_DECIMAL_PLACES, Decimal.ROUND_HALF_UP);
}

export function calculateBudgetAvailability(allocated: MoneyInput, paidExpenses: MoneyInput): Decimal {
  return toMoney(allocated).minus(toMoney(paidExpenses)).toDecimalPlaces(MONEY_DECIMAL_PLACES, Decimal.ROUND_HALF_UP);
}

export type BudgetExpense = {
  categoryId: string;
  occurredOn: string;
  amount: MoneyInput;
  kind: 'expense' | 'income' | 'adjustment';
};

export function calculatePaidExpensesForMonth(
  entries: BudgetExpense[],
  categoryId: string,
  monthStart: string,
): Decimal {
  const month = monthStart.slice(0, 7);
  return entries
    .filter((entry) => entry.kind === 'expense' && entry.categoryId === categoryId && entry.occurredOn.slice(0, 7) === month)
    .reduce<Decimal>((total, entry) => total.plus(toMoney(entry.amount)), new Decimal(0))
    .toDecimalPlaces(MONEY_DECIMAL_PLACES, Decimal.ROUND_HALF_UP);
}

export function calculateTotalFunds(accounts: MoneyInput[], virtualEnvelopeBalances: MoneyInput[]): Decimal {
  void virtualEnvelopeBalances;
  return accounts.reduce<Decimal>((total, balance) => total.plus(toMoney(balance)), new Decimal(0))
    .toDecimalPlaces(MONEY_DECIMAL_PLACES, Decimal.ROUND_HALF_UP);
}

export type AnalyticalEntry = {
  kind: 'income' | 'expense' | 'adjustment';
  amount: MoneyInput;
};

export function calculateAnalyticalTotals(entries: AnalyticalEntry[]): { income: Decimal; expenses: Decimal } {
  return entries.reduce(
    (totals, entry) => {
      if (entry.kind === 'income') totals.income = totals.income.plus(toMoney(entry.amount));
      if (entry.kind === 'expense') totals.expenses = totals.expenses.plus(toMoney(entry.amount));
      return totals;
    },
    { income: new Decimal(0), expenses: new Decimal(0) },
  );
}
