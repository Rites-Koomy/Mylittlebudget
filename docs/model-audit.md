# Audit du modèle financier V1

## Périmètre et méthode

Audit statique réalisé le 17 octobre 2026, uniquement à partir des fichiers locaux. Les migrations SQL n’ont pas été exécutées et aucun service distant n’a été contacté. Le rapport couvre les migrations, le code comptable et les tests existants ; il ne considère pas une règle comme testée uniquement parce qu’elle est documentée ou codée.

Fichiers examinés :

- `db/migrations/0001_create_financial_schema.sql`
- `db/migrations/0002_financial_integrity_triggers.sql`
- `db/migrations/0003_enable_rls.sql`
- `worker/src/domain/accounting.ts`
- `worker/src/domain/accounting.test.ts`
- `worker/src/index.test.ts`
- `worker/src/middleware/access.ts`
- `docs/data-model.md`

## Synthèse

Le modèle fournit une bonne base structurelle : `user_id` est présent sur les tables financières, les relations utilisent généralement des clés composites, les transferts sont séparés des transactions et les enveloppes virtuelles ne sont pas reliées à un compte par contrainte SQL.

Le modèle n’est toutefois pas prêt pour une connexion Neon. Les points bloquants sont :

1. le type `number` du code comptable ne garantit pas l’exactitude décimale annoncée par PostgreSQL ;
2. le sens d’un ajustement n’est pas représentable ;
3. le contexte RLS `app.user_id` peut être résiduel sur une connexion réutilisée si le Worker n’utilise pas strictement `SET LOCAL` dans chaque transaction ;
4. l’audit est une table disponible mais pas une garantie : plusieurs tables restent supprimables physiquement et les mises à jour ne sont pas journalisées automatiquement ;
5. les remboursements et annulations de dettes ne disposent pas encore d’un modèle d’état suffisant ;
6. les tests comptables actuels sont utiles comme tests unitaires minimaux, mais ne démontrent pas les garanties SQL, RLS, décimales ou rapprochements annoncées.

## 1. Isolation des utilisateurs

### Constats confirmés

- Les tables financières portent un `user_id` non nullable et référencent `app_users(id)` : `accounts` (`0001:20-32`), cartes (`0001:34-46`), poches (`0001:48-60`), catégories (`0001:62-70`) et les tables opérationnelles jusqu’à `audit_events` (`0001:72-221`).
- Les relations sensibles utilisent correctement `(user_id, id)`, notamment carte → compte (`0001:44-45`), compte source/destination d’un transfert (`0001:108-111`), transaction → compte/carte/poche/catégorie (`0001:129-133`) et import → compte/lignes/transaction (`0001:189-209`). Cela empêche une référence croisée entre utilisateurs lorsque les contraintes sont actives.
- La liste RLS couvre les tables financières suivantes : comptes, cartes, poches, catégories, budgets, lignes budgétaires, transferts, transactions, dettes, remboursements, récurrences, imports, lignes importées et audit (`0003:8-17`).
- La fonction RLS lit `current_setting('app.user_id', true)` et renvoie une valeur nulle si le paramètre est absent (`0003:3-6`). Dans ce cas, la comparaison `user_id = NULL` ne donne aucune ligne visible.
- Les tests actuels vérifient qu’un en-tête `X-User-Email` arbitraire ne suffit pas (`worker/src/index.test.ts:20-23`), mais ils ne testent pas RLS.

### Risques

#### Critique — contexte RLS résiduel sur connexion réutilisée

`app.current_user_id()` lit un paramètre de session (`0003:4-6`). Si le futur Worker exécute un `SET app.user_id = ...` permanent sur une connexion réutilisée, puis traite une requête sans réinitialiser le contexte, la requête suivante peut voir les lignes du précédent utilisateur. Le risque existe même si le JWT Access est correctement vérifié.

Le document recommande déjà une valeur par transaction (`docs/data-model.md:73-75`), mais le code Worker ne met pas encore en œuvre cette garantie.

Correction recommandée : utiliser une transaction pour chaque requête privée, définir `app.user_id` avec `set_config('app.user_id', $1, true)` ou `SET LOCAL`, ne jamais utiliser un `SET` de session, puis confirmer la remise à zéro avant de libérer la connexion. Le rôle utilisé doit aussi être incapable de contourner RLS.

#### Haute — propriétaire de table ou rôle `BYPASSRLS`

La migration active RLS mais ne force pas RLS (`0003:13-14`). Le propriétaire de table, un superutilisateur ou un rôle doté de `BYPASSRLS` peut contourner les politiques PostgreSQL. Le futur rôle Worker ne doit donc pas être propriétaire des tables et ne doit pas disposer de `BYPASSRLS`. Après choix du rôle, il faudra décider si `FORCE ROW LEVEL SECURITY` est nécessaire.

#### Haute — `app_users` n’est pas couvert par RLS

`app_users` est exclue de la liste RLS (`0003:11`). C’est acceptable uniquement si cette table est strictement inaccessible au rôle applicatif ou si elle est traitée par une fonction contrôlée. Sinon, un accès applicatif pourrait lire les identités d’autres utilisateurs. Il faut décider si `app_users` est administrée séparément ou si elle reçoit une politique dédiée.

#### Moyenne — contrôle d’identité incomplet au niveau du modèle

`access_subject` est unique (`0001:12-18`), ce qui est utile. En revanche, la correspondance entre le `sub` validé de Cloudflare Access et `app_users.access_subject` reste une décision future (`docs/data-model.md:77-80`). Aucun e-mail fourni dans le corps ne doit participer à cette résolution.

## 2. Comptabilité

### Ce qui est correctement séparé

- Les transferts sont une table distincte avec source, destination, montant positif et interdiction du même compte (`0001:97-112`). Ils ne sont pas une valeur de `transaction_kind`, donc ils ne peuvent pas être automatiquement agrégés comme revenus/dépenses par le schéma.
- Les enveloppes virtuelles ne peuvent pas avoir de compte associé (`0001:53-59`). La fonction `calculateTotalFunds` ignore explicitement les soldes d’enveloppes (`worker/src/domain/accounting.ts:20-22`).
- Les allocations budgétaires sont séparées des transactions payées : `budget_lines.allocated_amount` (`0001:83-95`) et la différence `allocated - paidExpenses` (`worker/src/domain/accounting.ts:16-18`).
- Le calcul documenté distingue solde bancaire, réservé et disponible budgétaire (`docs/data-model.md:36-59`).

### Risques et limites

#### Critique — exactitude décimale non préservée dans le code comptable

PostgreSQL utilise `numeric(19,4)` (`0001:26`, `0001:89`, `0001:102`, `0001:122`), mais `AccountSnapshot` et les fonctions TypeScript utilisent `number` (`worker/src/domain/accounting.ts:3-22`). Les nombres JavaScript sont binaires et peuvent produire des erreurs d’arrondi sur des montants comme `0.1 + 0.2`. Les tests actuels utilisent des entiers et ne détectent pas ce défaut (`worker/src/domain/accounting.test.ts:6-17`).

Correction recommandée : faire circuler des chaînes décimales validées, des unités mineures entières avec une précision explicitement fixée, ou une bibliothèque décimale ; ajouter des tests sur `0.10`, `10.0050`, les limites de précision et les arrondis. Le choix doit rester cohérent avec les agrégations SQL.

#### Haute — les ajustements négatifs ne sont pas représentables

`transaction_kind` prévoit `adjustment`, mais `transactions.amount` doit être strictement positif (`0001:114-133`) et le calcul ajoute `adjustments` (`worker/src/domain/accounting.ts:12-13`). Rien ne distingue un ajustement positif d’une correction négative. Une correction de rapprochement diminuant le solde ne peut donc pas être exprimée correctement.

Correction recommandée : ajouter un sens explicite (`credit`/`debit`), ou un montant signé avec une convention stricte, puis tester les deux signes. Il faut aussi décider si un ajustement est autorisé dans les rapports de revenus/dépenses.

#### Haute — remboursements de dettes incomplets

`debt_repayments.amount` est positif et lié à une dette (`0001:150-161`), mais aucune contrainte ne limite la somme des remboursements à `debts.original_amount`. Il n’existe ni statut d’annulation, ni date d’annulation, ni lien obligatoire vers une transaction, ni écriture inverse. Les paiements partiels sont donc stockables mais leur solde restant doit être calculé par l’application ; les remboursements excédentaires et annulations peuvent être incohérents.

Correction recommandée : décider si une annulation crée une écriture compensatrice immuable, ajouter un statut/événement d’annulation, définir la règle d’overpayment et tester un remboursement partiel, complet, excédentaire et annulé.

#### Haute — réservations modifiables sans historique

`budget_lines.allocated_amount` est directement modifiable et aucune table d’événements d’allocation n’existe (`0001:83-95`). Une modification peut faire disparaître l’historique d’une somme réservée. La table `audit_events` existe (`0001:212-221`) mais aucun trigger ne l’alimente.

Correction recommandée : soit rendre les allocations versionnées/événementielles, soit imposer un audit applicatif transactionnel avant toute modification et le tester. Il faut également définir le comportement lors d’une baisse d’allocation déjà partiellement dépensée.

#### Moyenne — dépenses budgétaires non rattachées à un mois ou à une enveloppe

Une transaction possède une date et une catégorie, mais aucun `budget_id` ou identifiant de ligne budgétaire (`0001:114-134`). La formule documentaire doit donc filtrer la période du budget côté requête ; sinon une catégorie peut agréger des dépenses de plusieurs mois. Une transaction payée ne peut pas non plus être reliée explicitement à l’enveloppe virtuelle qui l’a financée.

Correction recommandée : décider si le rattachement budgétaire est déduit par mois/catégorie ou matérialisé par une table d’affectation. Tester les transactions à cheval entre deux mois, les remboursements et les dépenses sans catégorie.

#### Moyenne — cartes incohérentes avec le compte de la transaction

La carte peut être liée à un compte (`0001:34-46`) et la transaction à une carte et un compte (`0001:114-133`), mais aucune contrainte ne garantit que `transactions.account_id = payment_cards.account_id`. Une transaction peut donc utiliser une carte du compte A et être comptabilisée sur le compte B du même utilisateur.

Correction recommandée : ajouter une contrainte ou un trigger de cohérence, en tenant compte du cas d’une carte sans association.

#### Moyenne — devises et transferts multi-devises non définis

Les comptes, budgets et dettes portent une devise, mais les transactions et transferts n’en portent pas (`0001:20-32`, `0001:97-133`). Deux comptes de devises différentes peuvent être reliés par un transfert sans taux, montant source ou montant destination. La devise EUR est une convention documentaire, pas une contrainte globale.

Décision nécessaire : V1 impose-t-elle EUR partout, ou faut-il modéliser explicitement les devises et conversions ?

## 3. Intégrité et historique

### Constats confirmés

- Les montants positifs, les dates de transfert, les mois de budget au premier jour et plusieurs champs textuels sont contrôlés par `CHECK` (`0001:72-95`, `0001:97-124`).
- Les index principaux couvrent les recherches par utilisateur, compte, catégorie, transfert, budget, empreinte CSV et entité d’audit (`0001:223-230`).
- Les triggers empêchent la suppression physique des transactions, transferts, dettes et remboursements (`0002:22-31`).
- Les poches virtuelles sont imposées aux lignes budgétaires et les poches réelles aux transactions (`0002:3-20`).

### Risques

#### Haute — suppression physique encore possible sur plusieurs tables

Le trigger de suppression ne couvre pas `accounts`, `payment_cards`, `pockets`, `categories`, `budgets`, `budget_lines`, `recurring_operations`, `csv_imports`, `csv_import_rows` ou `audit_events` (`0002:28-31`). Certaines suppressions seront bloquées par les clés étrangères si des enfants existent, mais une entité sans enfant peut disparaître sans trace. `audit_events` n’est pas réellement append-only au niveau SQL.

Correction recommandée : généraliser le soft-delete lorsque pertinent, interdire les `DELETE` par triggers ou privilèges, et protéger la table d’audit contre UPDATE/DELETE. Les exceptions doivent être explicitement décidées.

#### Haute — l’audit n’est pas automatique

Les colonnes `updated_at` sont présentes mais aucun trigger ne les met à jour automatiquement (`0001:16-17`, `0001:29-30` et tables similaires). Aucun trigger ne crée d’événement dans `audit_events`. Une correction applicative oubliant l’audit ou `updated_at` sera silencieuse.

Correction recommandée : définir une stratégie unique, idéalement audit transactionnel dans le service ou triggers SQL contrôlés, puis tester insert/update/soft-delete/restauration.

#### Haute — détection CSV insuffisante contre les doublons

`file_fingerprint` est unique par utilisateur (`0001:182-192`), mais `row_fingerprint` n’est qu’indexée (`0001:194-210`). Plusieurs lignes identiques peuvent donc être importées. `matched_transaction_id` n’est pas unique, une transaction peut être rapprochée de plusieurs lignes, et les champs normalisés sont nullable.

Correction recommandée : définir une empreinte canonique incluant au minimum compte, date, montant, devise et libellé normalisé ; ajouter une contrainte ou une table de candidats ; rendre le rapprochement idempotent et expliciter les exceptions (vraies opérations identiques). Ne pas transformer automatiquement un candidat en transaction.

#### Moyenne — dates et fuseau non complètement spécifiés

Les opérations utilisent `timestamptz`, les budgets et imports utilisent `date` (`0001:103`, `0001:123`, `0001:188`, `0001:201`). La conversion du fuseau Europe/Paris, les dates bancaires, dates de valeur et changements d’heure ne sont pas définis. Une même opération peut changer de jour lors d’un affichage ou d’un import.

Correction recommandée : décider quelles dates sont des dates civiles de relevé et lesquelles sont des instants, puis appliquer Europe/Paris lors de la normalisation.

#### Moyenne — contraintes de normalisation et d’arrondi incomplètes

`numeric(19,4)` fixe quatre décimales, mais les valeurs CSV normalisées sont nullable et aucune règle d’arrondi n’est définie (`0001:194-205`). La précision des devises futures, les arrondis de conversion et les valeurs négatives importées ne sont pas spécifiés.

## 4. Évaluation des tests existants

Les tests exécutables existants sont dans `worker/src/index.test.ts` et `worker/src/domain/accounting.test.ts`.

### Tests réellement couverts

- La route de santé répond en JSON (`index.test.ts:7-12`).
- Une route privée sans jeton est refusée (`index.test.ts:14-18`).
- Un e-mail arbitraire dans un en-tête ne suffit pas (`index.test.ts:20-23`).
- Une route inconnue renvoie une erreur JSON (`index.test.ts:25-29`).
- Le calcul numérique simple d’un transfert conserve le total entre deux comptes (`accounting.test.ts:5-9`).
- Le calcul unitaire ignore une valeur d’enveloppe virtuelle fournie séparément (`accounting.test.ts:11-13`).
- Une soustraction simple entre réservé et payé est calculée (`accounting.test.ts:15-17`).

### Ce qui n’est pas démontré

Les tests ne prouvent pas que les migrations sont syntaxiquement exécutables, car aucune base PostgreSQL locale n’est utilisée. Ils ne prouvent pas non plus que RLS bloque un accès croisé, que les clés composites fonctionnent, que les triggers SQL sont actifs, que les montants sont exacts en décimal, ni que les transferts sont exclus d’un agrégat réel de revenus/dépenses.

Le test des enveloppes est partiellement tautologique : `calculateTotalFunds` ignore toujours son second paramètre (`accounting.ts:20-22`). Il confirme l’intention de ne pas additionner les enveloppes, mais ne vérifie pas un calcul financier complet avec allocation et solde bancaire.

## 5. Tests à ajouter avant connexion Neon

### Isolation et RLS

- Deux utilisateurs avec comptes, cartes, poches, catégories, transactions et budgets distincts ; vérifier qu’aucune clé composite croisée n’est acceptée.
- Contexte `app.user_id = A`, lecture/écriture de B refusée ; contexte absent refusé.
- Deux transactions successives sur une connexion réutilisée : A puis B puis absence de contexte ; vérifier qu’aucun contexte ne fuit.
- Rôle propriétaire, rôle applicatif et rôle `BYPASSRLS` explicitement testés/configurés avant production.
- Recherche d’utilisateur uniquement par `sub` validé, jamais par un e-mail de requête.

### Comptabilité

- Revenus, dépenses, ajustements positifs et négatifs avec décimales.
- Transfert sortant/entrant : total consolidé inchangé et aucun revenu/dépense généré.
- Transfert vers le même compte refusé.
- Enveloppe virtuelle réservée mais absente du total des fonds.
- Poche réelle liée à un compte : absence de double comptage.
- Allocation réservée supérieure, égale et inférieure au payé ; dépenses sur deux mois.
- Remboursement de dette partiel, complet, excédentaire, annulé et rétabli.
- Carte associée à un compte différente du compte de transaction : refus.

### Historique et imports

- UPDATE et soft-delete créent un événement d’audit et mettent à jour `updated_at`.
- DELETE physique refusé sur toutes les tables concernées.
- Empreinte de fichier identique refusée ou explicitement réutilisée.
- Deux lignes CSV identiques, deux opérations bancaires réellement identiques et une ligne déjà rapprochée.
- Arrondis, dépassement de précision, devise invalide, montant nul, date invalide et fuseau Europe/Paris.

## 6. Décisions nécessitant un arbitrage

1. Représentation exacte des montants côté TypeScript : unités mineures, chaînes décimales ou bibliothèque dédiée.
2. Convention des ajustements négatifs et possibilité de corrections compensatrices immuables.
3. Politique des remboursements : limite au principal, surpaiement, annulation et écritures inverses.
4. Rattachement des dépenses à un budget mensuel et à une enveloppe virtuelle.
5. Politique d’audit : triggers SQL, service applicatif, ou combinaison ; protection stricte de `audit_events`.
6. Soft-delete obligatoire pour chaque table et stratégie de restauration.
7. Rôle PostgreSQL du Worker, `FORCE ROW LEVEL SECURITY` et définition transactionnelle de `app.user_id`.
8. Traitement de `app_users` sous RLS ou via un accès de résolution séparé.
9. Support EUR uniquement en V1 ou modèle multi-devise complet.
10. Définition des dates de relevé, dates de valeur et conversion Europe/Paris.
11. Empreinte CSV canonique, conservation des données brutes et règles de rapprochement.

## Conclusion

Le modèle est une base prometteuse, mais les garanties comptables et d’isolation annoncées ne sont pas encore entièrement démontrées. Les priorités avant toute connexion Neon sont : sécuriser le contexte RLS par transaction et le rôle PostgreSQL, corriger la représentation décimale et le signe des ajustements, définir le cycle de vie des dettes/réservations, puis rendre l’audit et l’idempotence CSV vérifiables par des tests d’intégration PostgreSQL locaux ou sur une branche explicitement autorisée.

## État des corrections après approbation

Mise à jour après validation du plan de correction. Les migrations existantes `0001` à `0003` n’ont pas été réécrites ; une migration additive `0004_financial_hardening.sql` a été ajoutée.

### Corrections réalisées localement

- **Montants exacts** : `decimal.js` est utilisé dans `worker/src/domain/accounting.ts`, avec conversion et arrondi centralisés à quatre décimales.
- **Ajustements** : les transactions et opérations récurrentes disposent désormais d’un sens `credit`/`debit`. Les agrégats analytiques TypeScript excluent les ajustements.
- **Remboursements** : `debt_repayments` distingue les opérations originales et les écritures inverses, conserve l’opération originale, interdit la double annulation et bloque les mises à jour directes.
- **Surpaiement** : un trigger PostgreSQL bloque un total actif supérieur au principal ou inférieur à zéro.
- **RLS** : `app_users` reçoit une politique dédiée et les tables financières sont forcées sous RLS dans `0004`. Le contexte doit rester transactionnel via `SET LOCAL`/`set_config(..., true)` lors de l’intégration du Worker.
- **Intégrité** : les cartes liées doivent utiliser le même compte que la transaction ; les devises V1 sont limitées à EUR ; les suppressions physiques supplémentaires sont bloquées.
- **Audit** : `updated_at` est maintenu par trigger, les écritures financières et budgétaires produisent des événements d’audit SQL, et `audit_events` est append-only.
- **CSV** : une transaction ne peut être rapprochée qu’une fois ; les statuts de rapprochement sont cohérents et un index de prévisualisation est ajouté. La validation manuelle reste obligatoire au niveau applicatif.
- **Budget** : le domaine TypeScript calcule maintenant les dépenses payées par mois civil et catégorie, en excluant revenus et ajustements.

### Vérifications réellement exécutées

- Suite Vitest : **11 tests unitaires réussis**.
- Typecheck TypeScript frontend et Worker : réussi après les dernières extensions.
- Migrations `0001` à `0004` : exécutées avec succès dans une instance PostgreSQL locale temporaire.
- `tests/sql/financial-hardening.sql` : réussi avec deux utilisateurs fictifs et un rôle non propriétaire sans `BYPASSRLS`. Ce test couvre notamment l’isolation, la remise à zéro du contexte transactionnel, les relations croisées, les poches, les ajustements, les cartes, les remboursements, la double annulation, le surpaiement et l’audit append-only.
- Aucun service Neon ou Cloudflare n’a été contacté et aucune migration distante n’a été exécutée.

### Limites et risques résiduels

- Le test PostgreSQL utilise une instance locale temporaire et un rôle de test ; la configuration réelle du rôle Worker, de ses privilèges et de son pool de connexions reste à vérifier avant connexion à Neon.
- Le code Worker ne configure pas encore réellement `app.user_id` autour d’une requête SQL, car le driver Neon n’est pas encore intégré.
- La création initiale de `app_users` doit utiliser une voie d’administration ou une fonction contrôlée : la nouvelle RLS dédiée ne permet pas à un rôle applicatif sans contexte de créer librement une identité.
- L’audit SQL est testé pour les opérations couvertes par la migration, mais l’audit applicatif, l’identité de l’acteur et la transaction Worker restent à implémenter.
- Les annulations de remboursements sont protégées au niveau SQL ; le flux applicatif de création d’une écriture inverse et de prévention des doubles clics reste à construire.
- Le calcul budgétaire mensuel/catégorie est testé comme fonction pure. Il n’existe pas encore de requête Worker qui agrège les données PostgreSQL réelles.
- La prévisualisation CSV, la normalisation canonique et la validation manuelle n’ont pas encore d’interface ni de service applicatif.
- Les migrations n’ont pas été testées contre une version exacte de Neon et aucune branche de test Neon n’a été créée.
