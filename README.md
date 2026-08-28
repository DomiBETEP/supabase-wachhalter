# Supabase wachhalten

Ein einzelner GitHub-Ablauf, der alle zwei Tage eine Tabelle eines
Supabase-Projekts abfragt — damit das Projekt im kostenlosen Tarif nicht nach
sieben Tagen Inaktivität pausiert wird.

## Warum es das gibt

Supabase pausiert Projekte im Free-Plan nach **sieben Tagen ohne Aktivität**.
Für eine App mit noch wenigen Nutzern heißt das: Die Anmeldung steht eines
Morgens still, der Projektname löst im DNS nicht mehr auf, und in der App
kommt „keine Verbindung" an — obwohl das Netz einwandfrei läuft.

Besonders unangenehm ist das während einer App-Store-Prüfung: Der Prüfer
öffnet die App Tage nach dem Einreichen und findet eine Anmeldung, die nicht
funktioniert.

## Warum eine Tabellenabfrage und kein Health-Ping

Gemessen über den Transaktionszähler der Datenbank (`pg_stat_database`), je
fünf Aufrufe gegen ein Grundrauschen von zwei Transaktionen pro Messpaar:

| Aufruf | Datenbanktransaktionen |
|---|---|
| `GET /auth/v1/health` | **+0** |
| `POST /auth/v1/token` (ungültiges Token) | +1 |
| `GET /rest/v1/<tabelle>` | **+7** |

**Ein Health-Ping berührt die Datenbank überhaupt nicht.** Ein Wachhalter, der
nur pingt, wäre womöglich wirkungslos — und das fällt erst auf, wenn das
Projekt trotzdem einschläft.

Supabase schreibt nirgends auf, was genau als „Aktivität" zählt. Ein Aufruf
über PostgREST ist zugleich eine API-Anfrage **und** eine Datenbanktransaktion
und fällt damit unter beide denkbaren Maßstäbe.

## Warum das Verzeichnis öffentlich ist

Für öffentliche Verzeichnisse sind GitHub Actions unbegrenzt kostenlos. In
einem privaten Verzeichnis hängt schon dieser winzige Lauf am Ausgabenlimit
des Kontos — und wenn das auf Null steht, startet er nie.

## Einrichtung

Drei Secrets unter **Settings → Secrets and variables → Actions**:

| Secret | Wert |
|---|---|
| `SUPABASE_URL` | `https://<projekt>.supabase.co` |
| `SUPABASE_ANON_KEY` | der **anon**-Schlüssel |
| `SUPABASE_TABELLE` | Name einer Tabelle, die `anon` lesen darf |

> Der `anon`-Schlüssel ist nicht geheim — er steht in jedem ausgelieferten
> Client. Der **`service_role`-Schlüssel gehört niemals hierher.**

Gibt es keine passende Tabelle, genügt eine leere:

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

## Was diesen Ablauf selbst einschläfern kann

GitHub schaltet zeitgesteuerte Abläufe in Verzeichnissen ab, in die **60 Tage**
lang nichts eingecheckt wurde, und schickt vorher eine E-Mail. Wer sie bekommt,
muss den Ablauf einmal von Hand wieder anschalten.
