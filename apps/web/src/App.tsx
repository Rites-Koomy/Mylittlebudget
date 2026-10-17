import { DemoCard } from './components/DemoCard';
import { BottomNav } from './components/BottomNav';
import { AccessInfo } from './pages/AccessInfo';

const demoBalance = new Intl.NumberFormat('fr-FR', { style: 'currency', currency: 'EUR' });

export default function App() {
  return (
    <div className="app-shell">
      <header className="topbar">
        <div><span className="eyebrow">ESPACE LOCAL</span><h1>Budget Perso</h1></div>
        <span className="status-dot" aria-label="Mode démonstration" title="Mode démonstration" />
      </header>
      <main>
        <section className="hero" aria-labelledby="dashboard-title">
          <p className="eyebrow">TABLEAU DE BORD</p>
          <h2 id="dashboard-title">Votre aperçu financier</h2>
          <p className="muted">Un point de départ simple, pensé pour le quotidien.</p>
        </section>
        <div className="demo-banner" role="note">Données de démonstration fictives — aucune donnée personnelle n’est utilisée.</div>
        <section className="card balance-card" aria-label="Solde fictif">
          <span className="label">Solde du mois</span>
          <strong>{demoBalance.format(2450)}</strong>
          <span className="positive">Aperçu local uniquement</span>
        </section>
        <section className="summary-grid" aria-label="Résumé fictif">
          <DemoCard label="Revenus" value="3 200 €" tone="positive" />
          <DemoCard label="Dépenses" value="750 €" tone="neutral" />
        </section>
        <AccessInfo />
      </main>
      <BottomNav />
    </div>
  );
}
