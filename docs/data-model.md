# Modèle de données V1

Ce modèle est préparé pour PostgreSQL/Neon, mais aucune migration n’est exécutée à distance dans cette étape. Il ne contient aucune donnée réelle.

## Principes

- `app_users` représente l’identité applicative future. L’identité Cloudflare Access sera reliée par `access_subject`, sans faire confiance à un e-mail fourni par le client.
- Toutes les tables financières possèdent un `user_id` direct.
- Les relations entre objets d’un même utilisateur utilisent des clés étrangères composites `(user_id, id)`. Cela empêche, par exemple, de rattacher une carte au compte d’un autre utilisateur.
- Les montants sont positifs et stockés en `NUMERIC(19,4)`. Le sens vient du type d’opération ou du rôle du transfert.
- Les suppressions sont remplacées par `deleted_at` sur les objets financiers. Les écritures et transferts ne doivent pas être supprimés physiquement.
- La devise V1 est EUR et les dates métier sont stockées en `timestamptz` ou `date` selon le besoin.

## Entités et relations

| Entité | Rôle | Relations principales |
| --- | --- | --- |
| `app_users` | propriétaire applicatif | possède toutes les données financières |
| `accounts` | compte bancaire, espèces ou épargne | possède des transactions et peut être source/destination d’un transfert |
| `payment_cards` | carte de paiement | appartient à un utilisateur, compte optionnel, plusieurs cartes par compte |
| `pockets` | poche réelle ou enveloppe virtuelle | une poche réelle peut être liée à un compte ; une virtuelle ne l’est jamais |
| `categories` | catégorie hiérarchique | utilisée par transactions et lignes budgétaires |
| `budgets` | budget d’un mois | possède des lignes de budget |
| `budget_lines` | montant réservé/affecté | relie un budget à une catégorie et éventuellement à une enveloppe virtuelle |
| `transactions` | revenu, dépense ou ajustement | liée à un compte, éventuellement carte, poche réelle et catégorie |
| `transfers` | mouvement interne | relie deux comptes du même utilisateur et n’est ni revenu ni dépense |
| `debts` | dette à recevoir ou à payer | possède des remboursements |
| `debt_repayments` | remboursement d’une dette | peut être rapproché d’une transaction |
| `recurring_operations` | définition d’une opération périodique | ne crée pas automatiquement de transaction à ce stade |
| `csv_imports` | fichier importé | possède des lignes importées et une empreinte de fichier |
| `csv_import_rows` | ligne CSV normalisée | détection de doublon et rapprochement prudents |
| `audit_events` | historique des changements | append-only au niveau applicatif |

## Règles comptables

### Soldes de comptes

Pour un compte bancaire :

```text
solde bancaire = solde initial
               + revenus
               + ajustements positifs
               - dépenses
               - transferts sortants
               + transferts entrants
```

Les transactions supprimées logiquement ne sont pas comptées. Les cartes ne possèdent pas de solde indépendant : la carte décrit le moyen de paiement et la transaction est portée par le compte associé au moment du paiement.

### Budget et enveloppes

```text
réservé = somme des budget_lines.allocated_amount
dépensé = somme des transactions de type expense pour la catégorie
disponible budgétaire = réservé - dépensé
```

Une enveloppe virtuelle sert à affecter une somme réservée ; elle ne possède pas de compte bancaire et n’entre jamais dans le total des fonds. Une poche réelle est un contenant physique ou une allocation réelle et est distincte d’une enveloppe virtuelle. Une poche réelle liée à un compte ne doit pas être additionnée une seconde fois au solde du compte.

### Épargne

L’épargne est calculée à partir des comptes/pockets réels explicitement marqués comme épargne ou des catégories décidées ultérieurement. Elle n’est pas déduite du disponible budgétaire par convention implicite.

### Transferts

Un transfert possède un montant positif, un compte source et un compte destination appartenant au même utilisateur. Il n’est jamais agrégé dans les revenus ou dépenses. Les contraintes empêchent un transfert vers le même compte.

## Import CSV

`csv_import_rows` conserve la ligne brute, une ligne normalisée, une empreinte calculée et un statut. Une empreinte identique dans le même import ou chez le même utilisateur est un signal de doublon, pas une preuve automatique : la date, le montant, le libellé et le compte doivent aussi être comparés avant rapprochement. L’import complet et la création automatique de transactions sont hors périmètre V1 de cette étape.

## Isolation PostgreSQL

La migration `0003_enable_rls.sql` active RLS et utilise `current_setting('app.user_id', true)`. Le Worker devra, dans une transaction future, établir cette valeur uniquement après validation cryptographique du JWT Cloudflare Access. Sans contexte utilisateur, les lignes financières ne sont pas visibles. Le Worker ne devra jamais construire ce contexte depuis un e-mail envoyé dans le JSON de la requête.

## Décisions à valider avant Neon

1. Le mapping exact entre le sujet Cloudflare Access (`sub`) et `app_users.access_subject`.
2. Le rôle PostgreSQL utilisé par le Worker et la manière sûre de définir `app.user_id` par transaction.
3. La politique d’audit : événements applicatifs obligatoires, triggers SQL, ou combinaison des deux.
4. La définition opérationnelle de l’épargne et des comptes de trésorerie.
5. La stratégie de gestion des remboursements de dette lorsqu’ils sont partiels ou annulés.
6. Les colonnes et formats CSV acceptés par établissement.
7. La politique de conservation des lignes brutes CSV et des données supprimées logiquement.
