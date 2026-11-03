# Publier Tchipa sur le Google Play Store — guide pas à pas

Pour : Tarik. Préparé le 3 novembre 2026. Rien n'a été commité ni poussé : tu relis,
puis tu valides.

## Ce qui est déjà prêt dans le repo

| Fichier | Rôle |
|---|---|
| `.github/workflows/play-release.yml` | Construit l'**AAB signé** (format exigé par Play) et l'envoie sur Play si le secret `PLAY_SERVICE_ACCOUNT_JSON` existe. Lancement manuel uniquement. |
| `store/listing/fr-FR/*.txt`, `store/listing/en-US/*.txt` | Titre, description courte, description longue (FR + EN) |
| `store/whatsnew/` | Notes de version (FR + EN), envoyées automatiquement avec l'AAB |
| `store/graphics/icon-512.png` | Icône Play 512×512 |
| `store/graphics/feature-graphic-1024x500.png` | Bannière (« image de présentation ») 1024×500 |
| `store/FORMULAIRES_PLAY_CONSOLE.md` | Réponses prêtes : Data safety, classification, public cible, fonctionnalités financières, accès pour les testeurs Google |
| `website/privacy.html` | Politique de confidentialité FR + EN, avec la procédure de suppression de compte (`#suppression`) |

---

## ÉTAPE 0 — Décisions à prendre AVANT le tout premier envoi

### 0.1 L'identifiant de l'app (applicationId) — DÉFINITIF

Aujourd'hui : `com.nearpay.app` (nom hérité d'un ancien projet). Sur Google Play,
cet identifiant **ne peut plus jamais changer** après le premier envoi. Problèmes :

- « NearPay » est le nom d'une vraie société de paiement : risque de refus pour
  usurpation / confusion, et l'identifiant est peut-être **déjà pris** sur Play
  (dans ce cas l'envoi est refusé tout de suite).
- Il ne correspond pas à ta marque.

**Proposition : `uk.co.tchipa.app`** (tu possèdes le domaine `tchipa.co.uk`).

Pour changer : dans `android/app/build.gradle.kts`, remplacer **seulement** la ligne
`applicationId = "com.nearpay.app"` par `applicationId = "uk.co.tchipa.app"`
(laisser `namespace` tel quel, c'est interne au code). Je ne l'ai pas fait : c'est
ta décision.

Conséquence : l'APK actuel (GitHub) et l'app Play deviennent deux apps différentes
sur le téléphone. Les comptes clients ne sont pas perdus (ils sont sur le serveur,
liés au numéro de téléphone) : le client se reconnecte avec téléphone + PIN.

> Même si tu gardes `com.nearpay.app`, l'app Play **ne pourra pas mettre à jour**
> l'APK installé depuis GitHub (la clé de signature sera différente avec Play App
> Signing). Les clients devront désinstaller l'APK puis installer depuis Play.

### 0.2 Créer l'adresse `contact@tchipa.co.uk`

La politique de confidentialité et la procédure de suppression de compte utilisent
`contact@tchipa.co.uk`. Crée cette boîte (ou une redirection vers ton Gmail), ou
remplace l'adresse dans `website/privacy.html` par celle que tu veux afficher.
Ajoute aussi l'identité de l'éditeur (ton nom ou ta société) dans la section 1 si
tu le souhaites.

### 0.3 Mettre en ligne la politique de confidentialité

Relis `website/privacy.html`, puis commit + push sur `main` : GitHub Pages la publie
sur `https://tchipa.co.uk/privacy.html`. Vérifie qu'elle s'ouvre.

### 0.4 Suppression de compte depuis l'app — OBLIGATOIRE

Google exige que toute app qui permet de **créer un compte** permette aussi de
**demander sa suppression depuis l'app** ET depuis le web. Le web est prêt
(`privacy.html#suppression`). Il manque dans l'app un bouton dans l'onglet Profil,
par exemple « Supprimer mon compte » qui ouvre
`https://tchipa.co.uk/privacy.html#suppression` (ou envoie l'email). C'est une
petite modification de `lib/main.dart` que je n'ai pas faite (consigne) : demande-la.
Sans elle, l'app risque un refus.

### 0.5 Recommandé (petits changements dans l'app, à valider)

- Retirer la permission `CAMERA` de `AndroidManifest.xml` (l'app ne s'en sert pas)
  et la dépendance `image_picker`.
- Passer `android:usesCleartextTraffic` à `false` (tout est déjà en HTTPS).
- Mettre `android:label="Tchipa"` (majuscule) au lieu de `tchipa`.

---

## ÉTAPE 1 — Créer l'app dans la Play Console

1. Va sur <https://play.google.com/console> avec `nou72025@gmail.com`.
2. **Créer une application** :
   - Nom : `Tchipa`
   - Langue par défaut : **Français (France) – fr-FR**
   - Application ou jeu : **Application**
   - Gratuite ou payante : **Gratuite** (attention : définitif aussi)
   - Coche les déclarations (règles du programme, lois d'exportation des États-Unis).
3. Tu arrives sur le **Tableau de bord** avec une liste de tâches « Configurer votre
   application » : on les remplit aux étapes 4 et 5.

## ÉTAPE 2 — Construire l'AAB signé (sur GitHub, pas sur le Chromebook)

Le Chromebook n'a ni la place disque (disque plein) ni la mémoire pour construire
un AAB. GitHub le fait :

1. (Décision 0.1 appliquée et poussée.) Pousse aussi `.github/workflows/play-release.yml`.
2. GitHub → onglet **Actions** → **Play Store release (AAB)** → **Run workflow**
   → laisse `internal` et `draft` → **Run workflow**.
3. À la fin (≈10–15 min), ouvre le run → en bas, **Artifacts** → télécharge
   `tchipa-play-100XX` (zip) → dézippe : tu obtiens `app-release.aab`.

Le workflow :
- utilise Flutter 3.41.6 → **targetSdk 36**, exigé par Play depuis le 31 août 2026
  (le workflow APK actuel utilise Flutter 3.29.2 → targetSdk 35 → serait refusé) ;
- vérifie le targetSdk et échoue s'il est trop bas ;
- **désactive la mise à jour par APK GitHub** dans la version Play (Play interdit
  qu'une app se mette à jour elle-même en dehors de Play) ;
- numérote les versions `10000 + numéro du run` (toujours croissant) ;
- signe avec ton keystore existant (secrets `ANDROID_*` déjà en place).

## ÉTAPE 3 — Premier envoi à la main + Play App Signing

Le tout premier AAB **doit être envoyé à la main** (l'API Google refuse tant que
l'app n'a jamais reçu de version).

1. Play Console → **Tester → Tests internes** → **Créer une release**.
2. Section **Signature d'application par Google Play** : choisis
   **« Utiliser une clé générée par Google »** (recommandé).
   - Google garde la vraie clé de l'app (impossible à perdre).
   - Ton keystore `tchipa-release.jks` devient la **clé d'importation (upload key)**.
     Si un jour tu la perds, Google peut la réinitialiser (pas possible sans Play App
     Signing). Garde quand même une copie du `.jks` + mots de passe hors du Chromebook
     (clé USB, gestionnaire de mots de passe).
3. Glisse `app-release.aab` → nom de release : `3.3.0` → notes de version : copie
   `store/whatsnew/whatsnew-fr-FR` → **Suivant** → **Enregistrer**.
4. Onglet **Testeurs** : crée une liste (ton email + 1 ou 2 proches) → copie le
   **lien d'inscription** → ouvre-le sur ton téléphone → accepte → installe depuis Play.

Tant que l'app n'a jamais été validée par Google, les releases restent en
« brouillon » côté API : c'est pour ça que le workflow utilise `draft` par défaut.

## ÉTAPE 4 — Remplir « Contenu de l'application »

Play Console → **Règles et programmes → Contenu de l'application**. Toutes les
réponses sont dans **`store/FORMULAIRES_PLAY_CONSOLE.md`** :

1. Règles de confidentialité → `https://tchipa.co.uk/privacy.html`
2. Accès à l'application → compte de test (téléphone + PIN + petit solde)
3. Annonces → Non
4. Classification du contenu → questionnaire IARC
5. Public cible → **18 ans et plus**
6. Sécurité des données (Data safety)
7. Fonctionnalités financières → crédit boutique en circuit fermé
8. Suppression de compte → URL `https://tchipa.co.uk/privacy.html#suppression`
9. Applis d'actualités, gouvernementales, santé → Non

## ÉTAPE 5 — Fiche Play Store

Play Console → **Développer la visibilité → Fiche Play Store principale** :

| Champ | Source |
|---|---|
| Nom de l'application (≤ 30) | `store/listing/fr-FR/title.txt` |
| Description courte (≤ 80) | `store/listing/fr-FR/short_description.txt` |
| Description complète (≤ 4000) | `store/listing/fr-FR/full_description.txt` |
| Icône de l'application | `store/graphics/icon-512.png` (512×512 PNG) |
| Image de présentation | `store/graphics/feature-graphic-1024x500.png` |
| Captures d'écran téléphone | à faire toi-même, voir ci-dessous |
| Catégorie | **Shopping** |
| Email de contact | contact@tchipa.co.uk (redirigée vers Gmail) |
| Site web | https://tchipa.co.uk |

Puis **Gérer les traductions → Ajouter des traductions → Anglais (États-Unis)** et
colle les textes de `store/listing/en-US/`.

### Captures d'écran à faire

Exigences Google (téléphone) : **minimum 2, maximum 8**, PNG ou JPEG (sans
transparence), côtés entre 320 et 3840 px, le grand côté **au plus 2 fois** le petit.
Format conseillé : **1080 × 1920 portrait**. (Attention : une capture brute
1080×2400 d'un téléphone récent dépasse le rapport 2:1 → à recadrer.)

Captures recommandées (dans l'ordre) :
1. Boutique — page d'accueil avec bannières et catégories
2. Une catégorie (liste de produits avec prix)
3. Fiche produit (photos, tailles, prix « livraison et douane comprises »)
4. Panier + formulaire de livraison (wilaya, commune, adresse)
5. Onglet Solde (solde + historique)
6. Onglet Commandes (suivi : payée → achetée → expédiée → livrée)
7. Profil (PIN, verrouillage par empreinte)

Règles : utilise le compte de test (pas de vrais numéros/noms de clients), n'affiche
**pas** l'espace Agent ni d'adresse USDT, pas de mention « VCC / carte Visa / crypto ».

Pour recadrer une capture au bon format sur le Chromebook :
```bash
convert capture.png -resize 1080x1920^ -gravity center -extent 1080x1920 capture_play.png
```

Tablettes (7" et 10") : facultatif.

## ÉTAPE 6 — Envoi automatique depuis GitHub (compte de service)

Une fois l'étape 3 faite, les versions suivantes peuvent partir sur Play
directement depuis le workflow.

1. <https://console.cloud.google.com> (même compte Google) → crée un projet
   `tchipa-play` (ou choisis-en un existant).
2. **API et services → Bibliothèque** → cherche **Google Play Android Developer API**
   → **Activer**.
3. **IAM et administration → Comptes de service → Créer un compte de service** :
   nom `github-play-upload` → Créer → (aucun rôle Cloud nécessaire) → OK.
4. Clique sur le compte créé → onglet **Clés → Ajouter une clé → Créer une clé →
   JSON** → un fichier `.json` est téléchargé. **C'est un secret** : ne l'envoie à
   personne, ne le mets pas dans le repo.
5. Play Console → **Utilisateurs et autorisations → Inviter de nouveaux
   utilisateurs** → colle l'email du compte de service
   (`github-play-upload@tchipa-play.iam.gserviceaccount.com`) → onglet **Autorisations
   de l'application** → ajoute Tchipa → coche **« Publier des versions dans les
   canaux de test »** (et plus tard « Publier en production ») → **Inviter**.
6. GitHub → repo `tchipa-app` → **Settings → Secrets and variables → Actions →
   New repository secret** : nom `PLAY_SERVICE_ACCOUNT_JSON`, valeur = **tout le
   contenu** du fichier JSON → Add secret. Puis supprime le fichier JSON du
   Chromebook (Téléchargements).
7. Test : Actions → Play Store release (AAB) → Run workflow (`internal`, `draft`).
   La release apparaît en brouillon dans Tests internes → tu la publies d'un clic.

L'autorisation peut mettre jusqu'à 24–36 h à fonctionner : si l'envoi échoue avec
« The caller does not have permission », réessaie le lendemain.

## ÉTAPE 7 — Test fermé : 12 testeurs pendant 14 jours (obligatoire)

Pour les **comptes développeur personnels créés après le 13 novembre 2023**, Google
exige, avant de pouvoir publier en production, un **test fermé** avec **au moins
12 testeurs inscrits sans interruption pendant au moins 14 jours** (règle vérifiée sur
l'aide Play Console, article 14151465). Si ton compte est un compte **organisation**
(entreprise avec numéro D-U-N-S), cette règle ne s'applique pas. Dans le doute :
Play Console → **Tableau de bord** : la tâche « Tester votre application » s'affiche
si tu es concerné.

1. **Tester → Tests fermés → Alpha (Closed testing)** → **Créer une release** → ajoute
   le même AAB (« Ajouter depuis la bibliothèque ») ou lance le workflow avec
   `track = alpha`.
2. **Testeurs** : crée une liste avec **au moins 12 adresses Gmail** (prévois 15–20,
   certains oublient). Exemples : agents, famille, clients fidèles, membres du groupe
   Telegram t.me/tchipa_UK.
3. Envoie-leur le **lien d'inscription**. Chacun doit : ouvrir le lien avec son compte
   Gmail → « Devenir testeur » → installer l'app depuis Play → **la garder installée
   et rester inscrit 14 jours** (un testeur qui se désinscrit remet son compteur à 0).
4. Demande-leur d'ouvrir l'app plusieurs fois et de donner un avis (Google regarde
   l'engagement). Publie au moins une mise à jour pendant les 14 jours si tu corriges
   quelque chose.
5. Après 14 jours : Tableau de bord → **Demander l'accès à la production** →
   questionnaire (comment tu as recruté les testeurs, retours reçus, changements faits,
   pourquoi l'app est prête). Réponse de Google en général sous 7 jours.

## ÉTAPE 8 — Production

1. **Production → Pays/régions** : ajoute **Algérie** (et les autres pays visés).
2. **Créer une release** (ou workflow avec `track = production`, `release_status =
   completed` une fois l'app validée).
3. Conseillé : **déploiement progressif** (20 % puis 100 %).
4. **Envoyer pour examen**. Premier examen : de quelques heures à plusieurs jours.

## Mises à jour ensuite

1. Change `version:` dans `pubspec.yaml` (ex. `3.4.0+7` — seul `3.4.0` compte, le
   numéro de build est calculé par le workflow).
2. Actions → Play Store release (AAB) → Run workflow (`internal` → vérifie → promeus
   vers `production` dans la Console, ou relance avec `production`).

---

## Risques de refus — analyse honnête

Je ne peux pas garantir l'acceptation. Voici les points qui comptent, du plus au moins
risqué.

1. **Services financiers / solde en dollars.** L'app tient un **solde en $** rechargé
   par des agents payés en dinars (BaridiMob) à un taux fixe (242 DZD/$). Présenté
   comme **crédit boutique fermé** (seulement pour acheter des vêtements, non retirable,
   non transférable), ce n'est normalement pas un « service financier » au sens Play.
   Mais si un relecteur le voit comme un **portefeuille électronique / change de
   devises**, Google peut demander une licence (que Tchipa n'a pas). Règle Play :
   l'app doit respecter les lois des pays où elle est distribuée ; en Algérie, la
   réglementation des changes encadre strictement les opérations en devises. Je ne
   suis pas juriste : avant la production, fais vérifier ce point par quelqu'un qui
   connaît le droit algérien.
   → Dans la fiche et les réponses : parler de **« solde boutique »**, jamais de
   « portefeuille », « dollars à échanger », « transfert ».

2. **Cryptomonnaies.** Côté client, il n'y a plus rien de crypto (les cartes VCC/USDT
   ont été retirées en septembre 2026). Mais **l'espace Agent** (Profil → Agent)
   affiche des **adresses de recharge USDT (Polygon/Solana)**. Si un relecteur y
   accède, l'app peut être classée « crypto » → exigences de licence (MiCA en Europe,
   etc.) et refus probable. Le code contient aussi d'anciens textes « USDT / Polygon /
   VCC » non affichés. Recommandation : dans la version Play, **masquer les adresses
   USDT de l'espace Agent** (ou sortir l'espace Agent de l'app Play) et nettoyer les
   anciens textes VCC/USDT. Ne jamais mentionner USDT/crypto dans la fiche.

3. **Suppression de compte depuis l'app** (étape 0.4) : obligatoire, manque aujourd'hui.

4. **Auto-mise à jour par APK** : réglé dans la version Play (le workflow ne définit
   pas `BUILD_NUMBER`, donc le module de mise à jour GitHub reste éteint). Ne pas
   ajouter `--dart-define=BUILD_NUMBER` au workflow Play.

5. **Identifiant `com.nearpay.app`** : risque de confusion avec la société NearPay /
   identifiant déjà pris (étape 0.1).

6. **Paiement** : les achats sont des **biens physiques** → Google Play Billing n'est
   **pas** exigé, le paiement hors Play est autorisé. OK.

7. **Accès pour les relecteurs** : sans compte de test avec du solde, Google refuse
   souvent (« impossible d'accéder aux fonctionnalités »). Voir
   `FORMULAIRES_PLAY_CONSOLE.md` §2.

8. **Vérification d'identité du compte développeur** : Google peut demander une
   pièce d'identité et un numéro de téléphone vérifié avant toute publication.

9. **Images produits** : photos de fournisseurs 1688/Yupoo. Si une marque se plaint
   (contrefaçon / photos protégées), Google peut retirer l'app. Éviter les articles
   portant des logos de grandes marques.
