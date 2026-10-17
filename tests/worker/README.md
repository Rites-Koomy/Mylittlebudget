# Tests Worker

Les tests exécutables du squelette sont dans `worker/src/index.test.ts` afin de tester directement le handler. Ce dossier est réservé aux futurs tests d’intégration ou de contrat nécessitant une organisation séparée.

Convention SQL prévue : `NNNN_description_courte.sql`, avec un numéro séquentiel et une description en minuscules séparée par des underscores. Aucune migration métier n’est créée à cette étape.
