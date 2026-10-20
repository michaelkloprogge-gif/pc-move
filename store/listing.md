# Microsoft Store listing - PC Move

Copy these into Partner Center. Screenshots: `store/screenshots/en` (English listing) and `store/screenshots/nl` (Dutch); the other languages use the English ones.

## Properties (all languages)

| Field | Value |
|---|---|
| Category | Utilities & tools |
| Privacy policy URL | https://github.com/michaelkloprogge-gif/pc-move#privacy |
| Website | https://github.com/michaelkloprogge-gif/pc-move |
| Support contact | https://github.com/michaelkloprogge-gif/pc-move/issues |
| Copyright | © 2026 Michael Kloprogge |
| Price | Free, all markets |
| System requirements | Windows 10 version 2004 or later, x64 |

## Notes for certification (Submission options)

Restricted capabilities - why they are needed:

- **runFullTrust**: PC Move is a classic desktop app (Windows Forms). On the old PC it reads the installed programs, personal folders, saved Wi-Fi profiles (netsh) and a few settings; on the new PC it copies them back.
- **allowElevation**: only when the user clicks "Run as administrator": then saved Wi-Fi passwords can be exported and programs install without a UAC prompt for each one.
- **unvirtualizedResources**: on the new PC the app installs programs with winget and applies the user's settings (dark mode, taskbar, File Explorer options, mouse speed, desktop background) in the user's registry and folders. With write virtualization these would land in the package's private copy and have no effect - and programs installed by winget would be tied to PC Move's package - so write virtualization is turned off. Changed settings can be put back under Settings > Undo.

Testing: no account needed. On one PC choose "This is my OLD PC", tick a few items and pack up to any folder or USB drive; then choose the folder on the Unpack page. Updates come from the Store only (the app's own updater is switched off in the Store version).

---

## English (en-us)

**Description**

Moving to a new Windows PC? PC Move packs up your programs, files, Wi-Fi networks and settings on the old PC, and unpacks them on the new one - with a USB drive or an external disk.

Programs are installed again in their newest version with winget. Your Desktop, Documents, Pictures, Music, Videos and Downloads are copied, and a file that is already on the new PC is never overwritten. Saved Wi-Fi networks, your desktop background, browser bookmarks and settings like dark mode and the taskbar come along too.

What no program can move for you - signing in to your browser, Microsoft 365, Steam games, printers - becomes a short to-do list with a button for each step.

Your old PC is never changed: PC Move only reads from it. Free and open source (MIT licence), no account, nothing uploaded.

**Product features**

- Moves programs (installed again with winget), personal files, Wi-Fi networks and settings
- Never overwrites a file that is already on the new PC
- Bookmarks from Chrome, Edge, Brave and Vivaldi, every profile
- A to-do list for what can't be moved, with a button for each step
- Only reads from the old PC
- Any USB drive or external disk - no cloud account needed
- English, Dutch, German, French, Spanish, Italian and Polish; light and dark theme

**Keywords**: migration, transfer, new PC, move files, backup, Wi-Fi, bookmarks

---

## Nederlands (nl-nl)

**Beschrijving**

Over naar een nieuwe Windows-pc? PC Move pakt je programma's, bestanden, wifi-netwerken en instellingen in op de oude pc en pakt ze uit op de nieuwe - met een usb-stick of externe schijf.

Programma's worden opnieuw geïnstalleerd in hun nieuwste versie, met winget. Je Bureaublad, Documenten, Afbeeldingen, Muziek, Video's en Downloads worden gekopieerd, en een bestand dat al op de nieuwe pc staat wordt nooit overschreven. Opgeslagen wifi-netwerken, je bureaubladachtergrond, bladwijzers en instellingen zoals de donkere modus en de taakbalk gaan ook mee.

Wat geen programma voor je kan verhuizen - inloggen in je browser, Microsoft 365, Steam-games, printers - wordt een korte takenlijst met een knop voor elke stap.

Je oude pc verandert nooit: PC Move leest er alleen van. Gratis en open source (MIT-licentie), geen account, er wordt niets geüpload.

**Productkenmerken**

- Verhuist programma's (opnieuw geïnstalleerd met winget), persoonlijke bestanden, wifi-netwerken en instellingen
- Overschrijft nooit een bestand dat al op de nieuwe pc staat
- Bladwijzers uit Chrome, Edge, Brave en Vivaldi, elk profiel
- Een takenlijst voor wat niet mee kan, met een knop voor elke stap
- Leest alleen van de oude pc
- Elke usb-stick of externe schijf - geen cloudaccount nodig
- Nederlands, Engels, Duits, Frans, Spaans, Italiaans en Pools; licht en donker thema

**Trefwoorden**: verhuizen, overzetten, nieuwe pc, bestanden, back-up, wifi, bladwijzers

---

## Deutsch (de-de)

**Beschreibung**

Umzug auf einen neuen Windows-PC? PC Move packt deine Programme, Dateien, WLAN-Netzwerke und Einstellungen auf dem alten PC ein und auf dem neuen wieder aus - mit einem USB-Stick oder einer externen Festplatte.

Programme werden mit winget in ihrer neuesten Version neu installiert. Desktop, Dokumente, Bilder, Musik, Videos und Downloads werden kopiert, und eine Datei, die schon auf dem neuen PC ist, wird nie überschrieben. Gespeicherte WLAN-Netzwerke, dein Desktophintergrund, Lesezeichen und Einstellungen wie der dunkle Modus und die Taskleiste kommen auch mit.

Was kein Programm für dich umziehen kann - die Anmeldung im Browser, Microsoft 365, Steam-Spiele, Drucker - wird eine kurze To-do-Liste mit einer Schaltfläche für jeden Schritt.

Dein alter PC wird nie verändert: PC Move liest nur von ihm. Kostenlos und Open Source (MIT-Lizenz), kein Konto, nichts wird hochgeladen.

**Produktfeatures**

- Zieht Programme (mit winget neu installiert), persönliche Dateien, WLAN-Netzwerke und Einstellungen um
- Überschreibt nie eine Datei, die schon auf dem neuen PC ist
- Lesezeichen aus Chrome, Edge, Brave und Vivaldi, jedes Profil
- Eine To-do-Liste für alles, was nicht mitkommen kann, mit einer Schaltfläche für jeden Schritt
- Liest nur vom alten PC
- Jeder USB-Stick oder jede externe Festplatte - kein Cloud-Konto nötig
- Deutsch, Englisch, Niederländisch, Französisch, Spanisch, Italienisch und Polnisch; helles und dunkles Design

**Suchbegriffe**: Umzug, Übertragung, neuer PC, Dateien, Sicherung, WLAN, Lesezeichen

---

## Français (fr-fr)

**Description**

Tu passes à un nouveau PC Windows ? PC Move emballe tes programmes, fichiers, réseaux Wi-Fi et paramètres sur l'ancien PC et les déballe sur le nouveau - avec une clé USB ou un disque externe.

Les programmes sont réinstallés dans leur dernière version avec winget. Ton Bureau, tes Documents, Images, Musique, Vidéos et Téléchargements sont copiés, et un fichier déjà présent sur le nouveau PC n'est jamais écrasé. Les réseaux Wi-Fi enregistrés, ton fond d'écran, tes favoris et des paramètres comme le mode sombre et la barre des tâches suivent aussi.

Ce qu'aucun programme ne peut déménager pour toi - te connecter à ton navigateur, Microsoft 365, les jeux Steam, les imprimantes - devient une courte liste de choses à faire, avec un bouton pour chaque étape.

Ton ancien PC n'est jamais modifié : PC Move ne fait que le lire. Gratuit et open source (licence MIT), sans compte, rien n'est envoyé en ligne.

**Fonctionnalités**

- Déménage les programmes (réinstallés avec winget), les fichiers personnels, les réseaux Wi-Fi et les paramètres
- N'écrase jamais un fichier déjà présent sur le nouveau PC
- Favoris de Chrome, Edge, Brave et Vivaldi, tous les profils
- Une liste à faire pour ce qui ne peut pas suivre, avec un bouton pour chaque étape
- Ne fait que lire l'ancien PC
- N'importe quelle clé USB ou disque externe - pas besoin de compte cloud
- Français, anglais, néerlandais, allemand, espagnol, italien et polonais ; thème clair et sombre

**Mots-clés** : migration, transfert, nouveau PC, fichiers, sauvegarde, Wi-Fi, favoris

---

## Español (es-es)

**Descripción**

¿Te cambias a un PC nuevo con Windows? PC Move empaqueta tus programas, archivos, redes Wi-Fi y configuración en el PC antiguo y los desempaqueta en el nuevo, con una memoria USB o un disco externo.

Los programas se vuelven a instalar en su versión más reciente con winget. Tu Escritorio, Documentos, Imágenes, Música, Vídeos y Descargas se copian, y un archivo que ya está en el PC nuevo nunca se sobrescribe. Las redes Wi-Fi guardadas, tu fondo de escritorio, los marcadores y ajustes como el modo oscuro y la barra de tareas también se vienen.

Lo que ningún programa puede trasladar por ti - iniciar sesión en el navegador, Microsoft 365, los juegos de Steam, las impresoras - se convierte en una breve lista de tareas con un botón para cada paso.

Tu PC antiguo nunca cambia: PC Move solo lee de él. Gratuito y de código abierto (licencia MIT), sin cuenta, no se sube nada.

**Características**

- Traslada programas (reinstalados con winget), archivos personales, redes Wi-Fi y configuración
- Nunca sobrescribe un archivo que ya está en el PC nuevo
- Marcadores de Chrome, Edge, Brave y Vivaldi, de todos los perfiles
- Una lista de tareas para lo que no se puede trasladar, con un botón para cada paso
- Solo lee del PC antiguo
- Cualquier memoria USB o disco externo, sin cuenta en la nube
- Español, inglés, neerlandés, alemán, francés, italiano y polaco; tema claro y oscuro

**Palabras clave**: migración, transferir, PC nuevo, archivos, copia de seguridad, Wi-Fi, marcadores

---

## Italiano (it-it)

**Descrizione**

Passi a un nuovo PC Windows? PC Move imballa programmi, file, reti Wi-Fi e impostazioni sul vecchio PC e li disimballa su quello nuovo, con una chiavetta USB o un disco esterno.

I programmi vengono reinstallati nella versione più recente con winget. Desktop, Documenti, Immagini, Musica, Video e Download vengono copiati, e un file che è già sul nuovo PC non viene mai sovrascritto. Le reti Wi-Fi salvate, lo sfondo del desktop, i preferiti e impostazioni come la modalità scura e la barra delle applicazioni vengono anch'essi trasferiti.

Ciò che nessun programma può trasferire per te - l'accesso al browser, Microsoft 365, i giochi Steam, le stampanti - diventa un breve elenco di cose da fare, con un pulsante per ogni passaggio.

Il vecchio PC non viene mai modificato: PC Move lo legge soltanto. Gratuito e open source (licenza MIT), senza account, nulla viene caricato online.

**Funzionalità**

- Trasferisce programmi (reinstallati con winget), file personali, reti Wi-Fi e impostazioni
- Non sovrascrive mai un file già presente sul nuovo PC
- Preferiti da Chrome, Edge, Brave e Vivaldi, tutti i profili
- Un elenco di cose da fare per ciò che non si può trasferire, con un pulsante per ogni passaggio
- Legge soltanto dal vecchio PC
- Qualsiasi chiavetta USB o disco esterno, senza account cloud
- Italiano, inglese, olandese, tedesco, francese, spagnolo e polacco; tema chiaro e scuro

**Parole chiave**: migrazione, trasferimento, nuovo PC, file, backup, Wi-Fi, preferiti

---

## Polski (pl-pl)

**Opis**

Przesiadasz się na nowy komputer z Windows? PC Move pakuje Twoje programy, pliki, sieci Wi-Fi i ustawienia na starym komputerze i rozpakowuje je na nowym - za pomocą pendrive'a lub dysku zewnętrznego.

Programy są instalowane ponownie w najnowszej wersji przez winget. Pulpit, Dokumenty, Obrazy, Muzyka, Wideo i Pobrane są kopiowane, a plik, który już jest na nowym komputerze, nigdy nie zostaje nadpisany. Zapisane sieci Wi-Fi, tapeta pulpitu, zakładki i ustawienia takie jak tryb ciemny i pasek zadań też są przenoszone.

To, czego żaden program nie przeniesie za Ciebie - logowanie do przeglądarki, Microsoft 365, gry ze Steam, drukarki - staje się krótką listą zadań z przyciskiem dla każdego kroku.

Stary komputer nigdy nie jest zmieniany: PC Move tylko z niego czyta. Bezpłatny i open source (licencja MIT), bez konta, nic nie jest wysyłane do sieci.

**Funkcje**

- Przenosi programy (instalowane ponownie przez winget), pliki osobiste, sieci Wi-Fi i ustawienia
- Nigdy nie nadpisuje pliku, który już jest na nowym komputerze
- Zakładki z Chrome, Edge, Brave i Vivaldi, z każdego profilu
- Lista zadań dla tego, czego nie da się przenieść, z przyciskiem dla każdego kroku
- Tylko czyta ze starego komputera
- Dowolny pendrive lub dysk zewnętrzny - bez konta w chmurze
- Polski, angielski, niderlandzki, niemiecki, francuski, hiszpański i włoski; jasny i ciemny motyw

**Słowa kluczowe**: migracja, przeniesienie, nowy komputer, pliki, kopia zapasowa, Wi-Fi, zakładki
