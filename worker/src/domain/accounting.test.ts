import { describe, expect, it } from 'vitest';
import { calculateAccountBalance, calculateAnalyticalTotals, calculateBudgetAvailability, calculatePaidExpensesForMonth, calculateTotalFunds, moneyToString, toMoney } from './accounting';

describe('règles comptables V1', () => {
  it('exclut les transferts internes des revenus et dépenses', () => {
    const accountA = calculateAccountBalance({ openingBalance: 1000, income: 0, expenses: 0, adjustments: [], transfersIn: 0, transfersOut: 300 });
    const accountB = calculateAccountBalance({ openingBalance: 100, income: 0, expenses: 0, adjustments: [], transfersIn: 300, transfersOut: 0 });
    expect(accountA.plus(accountB).toFixed(4)).toBe('1100.0000');
  });

  it('ne compte pas une enveloppe virtuelle dans les fonds', () => {
    expect(calculateTotalFunds([1000], [250]).toFixed(4)).toBe('1000.0000');
  });

  it('sépare le réservé du payé dans le disponible budgétaire', () => {
    expect(calculateBudgetAvailability(500, 125).toFixed(4)).toBe('375.0000');
  });

  it('calcule le payé par mois et catégorie', () => {
    const paid = calculatePaidExpensesForMonth([
      { categoryId: 'food', occurredOn: '2026-10-05', amount: '12.50', kind: 'expense' },
      { categoryId: 'food', occurredOn: '2026-09-30', amount: '99.00', kind: 'expense' },
      { categoryId: 'transport', occurredOn: '2026-10-06', amount: '20.00', kind: 'expense' },
      { categoryId: 'food', occurredOn: '2026-10-07', amount: '40.00', kind: 'income' },
    ], 'food', '2026-10-01');
    expect(paid.toFixed(4)).toBe('12.5000');
  });

  it('calcule les décimales sans flottants binaires', () => {
    expect(moneyToString(toMoney('0.10').plus(toMoney('0.20')))).toBe('0.3000');
    expect(moneyToString('10.0050')).toBe('10.0050');
  });

  it('applique séparément les ajustements crédit et débit', () => {
    const balance = calculateAccountBalance({ openingBalance: 100, income: 0, expenses: 0, adjustments: [
      { direction: 'credit', amount: '10.25' },
      { direction: 'debit', amount: '3.25' },
    ], transfersIn: 0, transfersOut: 0 });
    expect(balance.toFixed(4)).toBe('107.0000');
  });

  it('exclut les ajustements des revenus et dépenses analytiques', () => {
    const totals = calculateAnalyticalTotals([
      { kind: 'income', amount: '100.10' },
      { kind: 'expense', amount: '20.10' },
      { kind: 'adjustment', amount: '5.00' },
    ]);
    expect(totals.income.toFixed(4)).toBe('100.1000');
    expect(totals.expenses.toFixed(4)).toBe('20.1000');
  });
});
