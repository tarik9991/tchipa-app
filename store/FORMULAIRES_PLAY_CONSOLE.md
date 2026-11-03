# Brouillon des réponses Play Console — section « Contenu de l'application »

Basé sur le code réel (`lib/main.dart`, `android/app/src/main/AndroidManifest.xml`,
`backend/server.js`) au 3 novembre 2026. **À relire par Tarik** : si l'app change
(nouveau SDK, analytics, publicité…), ces réponses doivent changer aussi.

Play Console → ton app → **Règles et programmes → Contenu de l'application**.

---

## 1. Règles de confidentialité

URL : `https://tchipa.co.uk/privacy.html`
(le fichier `website/privacy.html` doit d'abord être poussé sur `main` pour être en ligne).

## 2. Accès à l'application (App access)

L'onglet Solde et le paiement exigent un compte (téléphone + PIN) → choisir
**« Tout ou partie des fonctionnalités sont restreintes »** et fournir à Google :

- un **compte de test** : numéro de téléphone + PIN d'un compte client créé exprès
  (email vérifié), avec **un petit solde** (ex. 20 $) crédité par un agent, pour que
  le testeur puisse passer une commande ;
- des instructions (en anglais) :
  > Open the app, go to the "Solde" (Wallet) tab, tap "Me connecter avec mon PIN" and
  > log in with phone `<NUMÉRO>` / PIN `<PIN>`. The test balance can then be used in
  > the "Boutique" (Shop) tab: add an item to the cart and pay with the balance. Top-ups are made offline by human agents
  > (cash/postal transfer in Algeria), so there is no in-app payment screen.
- Ne **pas** donner le PIN agent ni l'accès Agent (fonction réservée aux revendeurs).
- Annule ensuite manuellement les commandes de test dans `/admin`.

## 3. Annonces (Ads)

**Non**, l'application ne contient pas d'annonces.

## 4. Classification du contenu (questionnaire IARC)

- Email de contact : nou72025@gmail.com (ou contact@tchipa.co.uk une fois créé)
- Catégorie : **« Toutes les autres types d'applications »** (« All Other App Types »)
  — pas Jeu, pas Réseau social.

Réponses (toutes basées sur le contenu réel de l'app) :

| Question | Réponse |
|---|---|
| Violence, sang, contenu effrayant | Non |
| Sexualité, nudité | Non (vérifier qu'aucune photo produit du catalogue — lingerie, maillots — n'est suggestive ; sinon la retirer) |
| Langage grossier | Non |
| Substances contrôlées (drogue, alcool, tabac) | Non |
| Jeux d'argent / simulation de jeux d'argent | Non |
| Les utilisateurs peuvent-ils interagir ou échanger du contenu entre eux ? | **Non** (pas de chat ni de contenu publié dans l'app ; le lien Telegram ouvre une app externe) |
| L'app partage-t-elle la position de l'utilisateur avec d'autres ? | Non |
| L'app permet-elle l'achat de biens numériques ? | **Non** (seulement des **biens physiques** : vêtements) |
| Contenu généré par les utilisateurs | Non |
| Navigation web non restreinte | Non |

Classification attendue : **PEGI 3 / ESRB Everyone / USK 0** (à confirmer par le questionnaire).

## 5. Public cible et contenu (Target audience)

- Tranches d'âge : **18 ans et plus uniquement**.
  Raison : achats, solde en dollars, livraison à domicile. Choisir des tranches
  < 18 ans ferait entrer l'app dans les règles « Familles » (beaucoup plus strictes).
- « L'app pourrait-elle attirer les enfants ? » → **Non**.

## 6. Application d'actualités / Applis gouvernementales / Santé

Non / Non / Non.

## 7. Fonctionnalités financières (Financial features declaration)

Formulaire obligatoire pour toutes les apps. C'est **le point le plus sensible**
(voir aussi « Risques » dans `GUIDE_PLAY_STORE.md`).

Réponse recommandée, honnête et cohérente avec le produit actuel :

- L'app propose un **crédit de boutique en circuit fermé** (« solde ») : utilisable
  uniquement pour acheter les articles Tchipa, non retirable en espèces, non
  transférable entre utilisateurs, sans intérêts.
- Il n'y a **ni** prêt, **ni** banque/carte de paiement, **ni** échange/portefeuille
  de cryptomonnaies **pour les utilisateurs**, **ni** transfert d'argent entre personnes.
- Si le formulaire propose une case du type « Aucune des fonctionnalités ci-dessus »
  ou « Autre », cocher **Autre** et décrire :
  > Closed-loop store credit used only to pay for physical goods (clothing) sold in
  > the app. Credit is topped up offline by our resellers in Algeria; it cannot be
  > withdrawn, transferred to other users or used outside the app.
- **Ne pas** cocher « portefeuille numérique / e-money / crypto » sauf si l'app
  redevient un portefeuille (cartes VCC, USDT côté client) : dans ce cas une licence
  serait exigée et l'app serait très probablement refusée.

## 8. Sécurité des données (Data safety)

### Questions générales

| Question | Réponse |
|---|---|
| L'app collecte-t-elle ou partage-t-elle des types de données requis ? | **Oui** |
| Toutes les données collectées sont-elles chiffrées en transit ? | **Oui** (HTTPS vers `api.tchipa.co.uk`) |
| Proposez-vous un moyen de demander la suppression des données ? | **Oui** — URL : `https://tchipa.co.uk/privacy.html#suppression` (voir aussi l'obligation de suppression de compte dans le guide) |

### Types de données collectées

« Collectée » = envoyée à notre serveur. « Partagée » au sens de Google = transférée à
un **tiers indépendant**. Les prestataires qui agissent pour nous (hébergeur, envoi
d'email, transporteur exécutant la livraison demandée par l'utilisateur) **ne comptent
pas** comme « partage » d'après les définitions de Google → **Partagée : Non** partout.

| Catégorie Play | Type | Collecté | Partagé | Obligatoire ? | Finalités à cocher |
|---|---|---|---|---|---|
| Informations personnelles | **Nom** | Oui | Non | Obligatoire (pour commander) | Fonctionnalité de l'app ; Gestion du compte |
| Informations personnelles | **Adresse e-mail** | Oui | Non | Obligatoire | Gestion du compte ; Communications du développeur |
| Informations personnelles | **Numéro de téléphone** | Oui | Non | Obligatoire | Fonctionnalité de l'app ; Gestion du compte ; Prévention des fraudes, sécurité |
| Informations personnelles | **Adresse** (adresse de livraison) | Oui | Non | Obligatoire pour commander | Fonctionnalité de l'app |
| Informations financières | **Historique des achats** | Oui | Non | Obligatoire | Fonctionnalité de l'app ; Gestion du compte |
| Informations financières | **Autres informations financières** (solde, recharges : montant en dinars, référence de paiement saisis par l'agent) | Oui | Non | Obligatoire | Fonctionnalité de l'app ; Prévention des fraudes |

Pour chaque type : « Les données sont-elles traitées de façon éphémère ? » → **Non**.

### Ce qu'il ne faut PAS déclarer (et pourquoi)

- **Position** : jamais lue (la wilaya est saisie à la main → c'est une « Adresse »).
- **Identifiants de l'appareil** : `device_id` existe dans l'API mais l'app ne l'envoie pas.
- **Données biométriques** : traitées uniquement par Android (`local_auth`), jamais
  transmises à l'app ni au serveur.
- **Photos/vidéos, contacts, fichiers, audio** : non utilisés.
- **Diagnostics / plantages / analytics** : aucun SDK (Firebase n'est pas activé :
  `google-services.json` est présent mais le plugin n'est pas appliqué).
- **Identifiants utilisateur / mot de passe** : le PIN est un identifiant de connexion,
  pas une catégorie Data safety.

### Points à corriger pour que la déclaration reste exacte

- `AndroidManifest.xml` déclare `android.permission.CAMERA` alors que l'app n'utilise
  pas la caméra (`image_picker` est dans `pubspec.yaml` mais n'est appelé nulle part).
  Recommandé : retirer la permission et la dépendance → moins de questions des
  relecteurs. Tant qu'elle reste, ne rien déclarer de plus (aucune photo n'est envoyée).
- `android:usesCleartextTraffic="true"` : toutes les URL sont en HTTPS ; passer à
  `false` rendrait la réponse « chiffrées en transit » garantie.
