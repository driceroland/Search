# Version locale de Search

Cette variante conserve le navigateur WebKit natif du projet Search et ajoute :

- une navigation flottante centrée : précédent, suivant, adresse/recherche, actualiser/arrêter ;
- le réglage **Général → Afficher la navigation flottante**, indépendant de la barre latérale ;
- le réglage **Général → Langue de l’interface** : Système, Français, English, applicable immédiatement et mémorisé.

La navigation flottante est désactivée par défaut. Pour l’activer, ouvrir **Réglages → Général → Afficher la navigation flottante**. Elle fonctionne avec les onglets en haut ou dans la barre latérale. Pour masquer cette dernière au repos, ouvrir **Onglets**, activer les onglets dans une barre latérale puis son apparition au survol du bord. La navigation flottante reste disponible quand les onglets sont masqués. Lorsqu’elle est activée, le raccourci ⌘L place le curseur dans la capsule. Les suggestions et la recherche utilisent le moteur existant du navigateur.

Le choix **Système** utilise le français si la première langue préférée de macOS est le français, et l’anglais dans les autres cas. Choisir **Français** ou **English** force uniquement la langue de l’interface de Search.

Les ajouts prolongent l’interface existante : police système, SF Symbols, palette claire/sombre de `Sources/Search/Design.swift` et composants de réglages réutilisés. Le verre concerne les deux capsules de navigation ; l’espace entre elles laisse la page visible.

## Construire et ouvrir

```sh
./build-local.sh debug
open 'build/local/Search.app'
```

Sur un Mac Intel (ou avec `SEARCH_ARCH=x86_64`), l’application est produite dans `build/intel/local/Search.app`.

Xcode avec Swift 6 et le SDK macOS 26 ou ultérieur est nécessaire pour compiler la version utilisant le Liquid Glass natif. Le programme conserve un rendu de remplacement `regularMaterial` pour macOS 14 et 15. La réduction de transparence et de mouvement suit les préférences d’accessibilité du système.

La copie personnelle porte l’identifiant `local.searchbrowser`. Elle stocke ses fichiers dans `~/Library/Application Support/Search (local)/`, ses préférences dans son propre domaine et ses mots de passe sous une étiquette de trousseau distincte. Elle n’importe pas silencieusement les données de Search. Les mises à jour officielles ne remplacent pas cette copie ; les modifications du projet source doivent être intégrées dans le dépôt puis recompilées.

Le bundle est signé localement, sans notarisation. Il n’est pas installé dans Applications par le script. Les clés d’accès et certaines fonctions exigeant la signature officielle restent soumises aux restrictions du projet d’origine.

## Traductions

`Sources/Search/Localization.swift` gère les choix de langue et les interpolations, et `Sources/Search/Resources/fr.json` contient le catalogue français. Les appels `L(...)` concernent les textes d’interface, jamais les identifiants techniques, les URL ou les contenus des sites. Les titres de commandes sont traduits à l’affichage pour suivre un changement de langue sans redémarrage.

Le catalogue couvre les réglages, menus, navigation, signets, historique, téléchargements, mots de passe, importation et l’assistant. Les notes historiques de version, les textes fournis par des extensions, certaines erreurs du système et les boîtes de dialogue gérées par macOS peuvent conserver leur langue d’origine. Les pages web ne sont pas traduites.

`build.sh` embarque le bundle de ressources SwiftPM dans `Contents/Resources`; la résolution des traductions ne dépend pas de la présence du dossier de compilation sur le Mac qui ouvre l’application.

## Vérification

```sh
swift test
```

Les tests ajoutés couvrent le choix système/français/anglais, la substitution des arguments sans interpréter leur contenu, la cohérence des traductions, les titres des commandes après changement de langue, la dissimulation des identifiants d’URL et la persistance de l’affichage flottant indépendamment de la sidebar.

Le banc natif existant dispose aussi de paramètres `ui` réservés aux sessions de test : `floatingNavigation`, `language` et `settingsPage`. `probe` expose leurs valeurs et l’emplacement des ressources chargées. Une capture fidèle du Liquid Glass nécessite WindowServer : `SEARCH_PROBE=nom SEARCH_VISUAL_REVIEW=1` autorise explicitement une fenêtre visible pour cette inspection. Les probes ordinaires restent masquées et séparées des données personnelles.
