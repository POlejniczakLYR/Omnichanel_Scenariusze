# Omnichanel_Scenariusze

Model segmentacji klientów omnichannel (M1–M7) na danych Lyreco PL (HALO / Oracle).

Podejście **multi-tag**: jeden wiersz na klienta (`SOLDTO_NUMBER`) z kolumnami-tagami
`M1 … M7` o wartości `TAK` / `NIE` / `DO_UZUPELNIENIA`. Klient może należeć do wielu
scenariuszy jednocześnie (M4 rozłączny, M5/M6/M7 jako nakładki).

## Struktura

| Ścieżka | Opis |
|---|---|
| `sql/segmentacja_omnichannel_M1-M7.sql` | Zapytanie Oracle liczące metryki 12m rolling i tagi M1–M7 |
| `docs/model_omnichannel_scenariusze.pdf` | Opis wszystkich scenariuszy i algorytmu TAK/NIE |
| `docs/model_omnichannel_scenariusze.html` | Źródło dokumentacji (HTML) |

## Scenariusze

| Tag | Nazwa | Typ | Status |
|---|---|---|---|
| M1 | Digital Self-Service Scale | rdzeń | gotowe |
| M2 / M2A | Assisted Digital Adoption | rdzeń | gotowe |
| M3 | Expert Advisory Expansion | rdzeń | częściowe (brak mapy PKD) |
| M4 | Strategic Contract & Retention | rdzeń | gotowe |
| M5 | Price Fighter / Marketplace Defense | nakładka | blokada (brak listy KVI) |
| M6 | Recovery / Churn Prevention | nakładka | blokada (źródło churn) |
| M7 | Specialist Vertical Solution | nakładka | częściowe (brak mapy PKD) |

Szczegółowe definicje metryk, mapowania kodów (IS=1603, PF=1601, MM=1605,
Corporate) oraz reguły kwalifikacji (m.in. MidMarket tylko przy zatrudnieniu 0–249)
znajdują się w dokumencie PDF.
