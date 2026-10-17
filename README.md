# Budget Perso

Squelette local d’une application personnelle de gestion budgétaire.

Cette étape ne contient aucune fonctionnalité métier, aucune connexion Neon et aucun déploiement. Les données affichées dans l’interface sont fictives et uniquement destinées à la démonstration locale.

## Prérequis

- Node.js 20 ou plus récent
- npm 10 ou plus récent

Aucun compte Cloudflare ou Neon n’est nécessaire pour le développement local de ce squelette.

## Installation et commandes

Depuis la racine :

```bash
npm install
npm run dev:web
npm run build:web
npm run typecheck
npm test
```

Le frontend est servi par Vite, habituellement sur `http://localhost:5173`. Le Worker peut être lancé avec `npm run dev --workspace worker` après installation de Wrangler. Il expose `GET /api/health` sur le port Wrangler par défaut.

## Sécurité actuelle

`GET /api/health` est public et ne révèle aucune donnée. La route privée de démonstration est fermée par défaut. Les futures routes privées devront passer par le middleware centralisé Access, qui vérifiera cryptographiquement le JWT Cloudflare Access, son émetteur, son audience et son expiration. Un simple e-mail ou en-tête arbitraire ne sera jamais considéré comme une preuve d’identité.

La configuration réelle Cloudflare Access et les secrets Worker ne sont pas présents localement. Aucun secret ne doit être ajouté au dépôt.

## Structure

- `apps/web/` : React, TypeScript, Vite et préparation PWA.
- `worker/` : Worker TypeScript et middleware d’accès.
- `db/migrations/` : futures migrations SQL brutes, nommées `NNNN_description.sql`.
- `tests/worker/` : emplacement documentaire pour les tests ; les tests exécutables du Worker sont regroupés dans `worker/src/*.test.ts` pour rester proches du code testé.

Le manifeste PWA est présent comme préparation, mais l’installation n’est pas déclarée fonctionnelle : les icônes et le service worker seront ajoutés et testés dans une étape dédiée.

## Avant un futur déploiement

Il faudra configurer le domaine, Cloudflare Access pour `ritesmassamba@gmail.com`, les paramètres de validation JWT, les secrets du Worker et la compatibilité du driver Neon serverless. Il faudra également définir le schéma métier, ajouter les migrations et compléter les tests d’intégration sans exposer les données financières.
