type DemoCardProps = { label: string; value: string; tone: 'positive' | 'neutral' };

export function DemoCard({ label, value, tone }: DemoCardProps) {
  return <article className="card mini-card"><span className="label">{label}</span><strong className={tone}>{value}</strong><span className="muted">Démonstration</span></article>;
}
