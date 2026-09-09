# Supabase wachhalten

Ein GitHub-Ablauf, der zweimal täglich an bis zu fünf Supabase-Projekte
anklopft — damit sie im kostenlosen Tarif nicht wegen Inaktivität pausiert
werden.

## Warum es das gibt

Supabase pausiert Projekte im Free-Plan wegen zu geringer Aktivität. Für eine
App mit noch wenigen Nutzern heißt das: Die Anmeldung steht eines Morgens
still, der Projektname löst im DNS nicht mehr auf, und in der App kommt „keine
Verbindung" an — obwohl das Netz einwandfrei läuft.

Besonders unangenehm ist das während einer App-Store-Prüfung: Der Prüfer
öffnet die App Tage nach dem Einreichen und findet eine Anmeldung, die nicht
funktioniert.

## Was die erste Fassung falsch gemacht hat

Am **9. September 2026** war das Projekt pausiert, obwohl der Wachhalter lief.
Das Protokoll zeigt, dass er zwei Tage vorher noch sauber `HTTP 200` bekam:

| Lauf | Antwort |
|---|---|
| 01.09. | 200 |
| 03.09. | 200 |
| 05.09. | 200 |
| 07.09. | 200 |
| **09.09.** | **Name löst nicht auf** |

Bei einer Sieben-Tage-Frist kann fehlende Aktivität das nicht erklären — es
gab welche, 47 Stunden vorher. Der Denkfehler steckte in der Annahme, die
Frist sei eine **Sanduhr**, die jede Abfrage umdreht. Die Doku beschreibt aber
eine **Schwelle über ein rollierendes Wochenfenster**:

> A Free plan project is considered inactive if it does not receive
> **sufficient** user database activity over the past week. […] Typically a
> few user requests to the database **each day** over the previous week is
> enough to keep the project from being paused.

Der Maßstab ist *ein paar Anfragen an jedem Tag*. Geliefert wurde **eine
Anfrage an vier von sieben Tagen** — an drei Tagen der Woche war das Projekt
in Supabases Messung vollkommen still.

Deshalb jetzt: **zweimal täglich, je vier Anfragen mit Abstand.**

## Warum eine Tabellenabfrage und kein Health-Ping

Gemessen über den Transaktionszähler der Datenbank (`pg_stat_database`), je
fünf Aufrufe gegen ein Grundrauschen von zwei Transaktionen pro Messpaar:

| Aufruf | Datenbanktransaktionen |
|---|---|
| `GET /auth/v1/health` | **+0** |
| `POST /auth/v1/token` (ungültiges Token) | +1 |
| `GET /rest/v1/<tabelle>` | **+7** |

**Ein Health-Ping berührt die Datenbank überhaupt nicht.** Ein Wachhalter, der
nur pingt, wäre wirkungslos — und das fällt erst auf, wenn das Projekt
trotzdem einschläft.

## Warum es einen Rückfall gibt

Am Tag des Aufweckens antwortete die eingetragene Tabelle mit `404` —
PostgREST kannte sie nicht mehr. Ein Wachhalter, der nur eine Tabelle kennt,
erzeugt dann **null** Aktivität, und das Projekt schläft trotz grünem
Zeitplan wieder ein.

`wachhalten.sh` probiert darum der Reihe nach:

1. die eingetragene Tabelle,
2. irgendeine lesbare Tabelle aus dem Schema — hält das Projekt wach, auch
   wenn die Einstellung veraltet ist,
3. eine bewusst ungültige Anmeldung; der Endpunkt existiert immer.

Greift nur Weg 2 oder 3, **wird der Lauf trotzdem rot.** Das Projekt bleibt
wach, aber die kaputte Einstellung soll nicht unbemerkt bleiben.

Ein `401` gilt dabei ausdrücklich **nicht** als Erfolg, obwohl es nach einer
Antwort aussieht: Das ist der abgelehnte API-Schlüssel, die Anfrage erreicht
Postgres nie. Genau diese Verwechslung ergäbe einen Wachhalter, der täglich
grün meldet, während das Projekt in Ruhe einschläft.

## Einrichtung

Drei Secrets unter **Settings → Secrets and variables → Actions**:

| Secret | Wert |
|---|---|
| `SUPABASE_URL` | `https://<projekt>.supabase.co` |
| `SUPABASE_ANON_KEY` | der **anon**-Schlüssel |
| `SUPABASE_TABELLE` | Name einer Tabelle, die `anon` lesen darf |

**Weitere Projekte:** dieselben drei Secrets mit `_2` bis `_5` am Ende, also
`SUPABASE_URL_2`, `SUPABASE_ANON_KEY_2`, `SUPABASE_TABELLE_2` und so fort. Am
Ablauf ist dafür nichts zu ändern.

> Der `anon`-Schlüssel ist nicht geheim — er steht in jedem ausgelieferten
> Client. Der **`service_role`-Schlüssel gehört niemals hierher.**

### Eine eigene Tabelle ist am haltbarsten

Zeigt `SUPABASE_TABELLE` auf eine Tabelle der App, bricht der Wachhalter beim
nächsten Umbau des Schemas. Eine Tabelle, die nur ihm gehört, überlebt das:

```sql
create table if not exists public.wachhalter (
  id smallint primary key default 1,
  angelegt timestamptz not null default now(),
  constraint nur_eine_zeile check (id = 1)
);
insert into public.wachhalter (id) values (1) on conflict (id) do nothing;
alter table public.wachhalter enable row level security;
grant select on table public.wachhalter to anon, authenticated;
create policy wachhalter_lesen on public.wachhalter
  for select to anon, authenticated using (true);
```

## Wogegen auch dieser Wachhalter nichts ausrichtet

Der kostenlose Tarif erlaubt höchstens **zwei aktive Projekte**, gezählt über
alle Organisationen, in denen du Eigentümer oder Administrator bist. Pausierte
Projekte zählen nicht mit. Ein drittes Projekt pausiert Supabase unabhängig
von jeder Aktivität — dagegen hilft kein Wachhalter, nur ein Tarif.

## Was diesen Ablauf selbst einschläfern könnte

GitHub schaltet zeitgesteuerte Abläufe in Verzeichnissen ab, in die **60 Tage**
lang nichts eingecheckt wurde — lautlos, ohne roten Lauf. Der Ablauf schreibt
sich deshalb alle 14 Tage selbst ein Lebenszeichen ins Verzeichnis und setzt
die Frist damit zurück.

Geplante Läufe starten bei GitHub außerdem selten pünktlich: Der erste
Wachhalter war auf 06:00 UTC gesetzt und lief tatsächlich zwischen 09:34 und
11:59. Bei Auslastung fallen sie auch ganz aus. Deshalb zwei Läufe pro Tag zu
krummen Minuten — fällt einer aus, trägt der andere den Tag.

## Wenn etwas nicht stimmt

Der Ablauf öffnet dann ein **Issue** mit dem Label `wachhalter` und einem Link
aufs Protokoll. E-Mails von GitHub gehen leicht unter; ein Issue bleibt
stehen, bis es jemand schließt. Solange eins offen ist, kommt kein zweites
dazu.

## Warum das Verzeichnis öffentlich ist

Für öffentliche Verzeichnisse sind GitHub Actions unbegrenzt kostenlos. In
einem privaten Verzeichnis hängt schon dieser winzige Lauf am Ausgabenlimit
des Kontos — und wenn das auf Null steht, startet er nie.

Weil die Laufprotokolle damit ebenfalls öffentlich sind, schreibt
`wachhalten.sh` keine Tabellennamen und keine URLs ins Protokoll, sondern
zählt die Projekte nur durch.
