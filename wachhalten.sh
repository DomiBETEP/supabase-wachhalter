#!/usr/bin/env bash
#
# Klopft an jedes eingetragene Supabase-Projekt, damit es im kostenlosen
# Tarif nicht pausiert wird.
#
# WAS SUPABASE MISST - und warum der erste Entwurf daran scheiterte:
# Die Doku sagt "sufficient user database activity over the past week",
# konkret "a few user requests to the database each day over the previous
# week". Das ist keine Sanduhr, die jede Abfrage umdreht, sondern eine
# Schwelle ueber ein rollierendes Wochenfenster. Der erste Wachhalter lief
# alle zwei Tage mit genau einer Abfrage - an drei von sieben Tagen war das
# Projekt in Supabases Messung vollkommen still. Am 09.09.2026 war es
# pausiert, zwei Tage nach einer nachweislich erfolgreichen Abfrage.
#
# WARUM EIN RUECKFALL: Am Tag des Aufweckens lieferte die Tabellenabfrage
# 404 - PostgREST fand die eingetragene Tabelle nicht. Ein Wachhalter, der
# nur eine Tabelle kennt, erzeugt dann NULL Aktivitaet und das Projekt
# schlaeft trotz gruenem Zeitplan wieder ein. Darum probiert dieses Skript
# der Reihe nach mehrere Wege und meldet trotzdem rot, damit die kaputte
# Einstellung nicht unbemerkt bleibt.
#
# ABBRUCH STATT WARNUNG: Jede Abweichung faerbt den Lauf rot. Ein Wachhalter,
# dessen Scheitern niemand sieht, ist schlimmer als keiner - er erzeugt das
# Gefuehl, abgesichert zu sein.

set -uo pipefail

# Wie viele Anfragen pro Lauf, mit welchem Abstand. Zusammen mit zwei
# Laeufen pro Tag ergibt das rund acht Anfragen taeglich, verteilt statt als
# ein einzelner Stoss - mit Abstand ueber "a few requests each day" statt
# knapp daneben.
ANFRAGEN="${ANFRAGEN:-4}"
ABSTAND="${ABSTAND:-45}"

# Bis zu fuenf Projekte. Slot 1 sind die bestehenden Secrets ohne Nummer,
# damit der Umbau die vorhandene Einrichtung nicht bricht.
MAX_SLOTS="${MAX_SLOTS:-5}"

gefunden=0
kaputt=""
wach=""

# Eine einzelne Anfrage. Gibt den HTTP-Status auf stdout aus; bei einem
# Verbindungsfehler "000". Faengt den curl-Fehler ab, statt daran
# abzubrechen - sonst verschluckt set -e die Diagnose, die wir brauchen.
anfrage() {
  local url="$1" key="$2" pfad="$3" methode="${4:-GET}" rumpf="${5:-}"
  local args=(-s -o /dev/null -w "%{http_code}" --max-time 25
              -H "apikey: $key" -H "Authorization: Bearer $key")

  if [ "$methode" = "POST" ]; then
    args+=(-X POST -H "Content-Type: application/json" -d "$rumpf")
  fi

  # curl schreibt den Status auch im Fehlerfall ("000"), liefert dann aber
  # einen Fehlercode. Ohne das "|| true" wuerde die Ersatzausgabe ANGEHAENGT
  # und aus "000" wuerde "000000" - womit die Erkennung des pausierten
  # Projekts weiter unten stillschweigend danebengreift.
  local ausgabe
  ausgabe=$(curl "${args[@]}" "$url$pfad" 2>/dev/null) || true
  echo "${ausgabe:-000}"
}

# Sucht im OpenAPI-Verzeichnis von PostgREST eine lesbare Tabelle. Damit
# heilt sich der Wachhalter selbst, wenn eine Tabelle umbenannt wurde.
# Der Name wird bewusst NICHT ins Protokoll geschrieben - die Laufprotokolle
# dieses Verzeichnisses sind oeffentlich.
tabelle_finden() {
  local url="$1" key="$2"
  curl -s --max-time 25 -H "apikey: $key" -H "Authorization: Bearer $key" \
    "$url/rest/v1/" 2>/dev/null \
    | grep -oE '"/[a-zA-Z0-9_]+"' \
    | tr -d '"/' \
    | grep -v '^rpc$' \
    | head -1
}

# Klopft an ein Projekt. Rueckgabe: 0 = Aktivitaet erzeugt, 1 = nichts erreicht.
# Setzt "hinweis", wenn es zwar geklappt hat, aber nicht auf dem gewollten Weg.
anklopfen() {
  local name="$1" url="$2" key="$3" tabelle="$4"
  hinweis=""

  # Weg 1: die eingetragene Tabelle. Laut Messung im ersten Entwurf der
  # wirksamste Weg - eine Tabellenabfrage erzeugte sieben Transaktionen,
  # ein Health-Ping keine einzige.
  if [ -n "$tabelle" ]; then
    local status
    status=$(anfrage "$url" "$key" "/rest/v1/$tabelle?select=*&limit=1")
    if [ "$status" = "200" ]; then
      echo "  Tabellenabfrage: $status"
      return 0
    fi
    echo "  Tabellenabfrage: $status - eingetragene Tabelle antwortet nicht"
    hinweis="Die eingetragene Tabelle antwortete mit $status statt 200."
    # 401 kommt vom Tuersteher, nicht aus der Datenbank: Der Schluessel wird
    # abgelehnt, die Anfrage erreicht Postgres nie. Dann sind auch die
    # weiteren Wege sinnlos - sie tragen denselben Schluessel.
    if [ "$status" = "401" ] || [ "$status" = "403" ]; then
      echo "  Der anon-Schluessel wird abgelehnt - kein Weg kann Aktivitaet erzeugen"
      hinweis="Der anon-Schluessel wird mit $status abgelehnt. Er ist abgelaufen oder gehoert zu einem anderen Projekt - bitte in den Secrets erneuern."
      return 1
    fi
  else
    hinweis="Keine Tabelle eingetragen."
  fi

  # Weg 2: irgendeine lesbare Tabelle aus dem Schema. Haelt das Projekt wach,
  # auch wenn die Einstellung veraltet ist.
  local ersatz
  ersatz=$(tabelle_finden "$url" "$key")
  if [ -n "$ersatz" ]; then
    local status
    status=$(anfrage "$url" "$key" "/rest/v1/$ersatz?select=*&limit=1")
    if [ "$status" = "200" ]; then
      echo "  Ersatztabelle aus dem Schema: $status"
      hinweis="$hinweis Eine Ersatztabelle aus dem Schema hat gegriffen - bitte SUPABASE_TABELLE korrigieren."
      return 0
    fi
  fi

  # Weg 3: eine bewusst ungueltige Anmeldung. Der Endpunkt existiert immer,
  # und der Nutzer-Nachschlag erzeugt eine Datenbanktransaktion. Schwaecher
  # als eine Tabellenabfrage, aber besser als gar nichts - und es ist der
  # einzige Weg, der ohne jede Kenntnis des Schemas funktioniert.
  local status
  status=$(anfrage "$url" "$key" "/auth/v1/token?grant_type=password" POST \
    '{"email":"wachhalter@invalid.example","password":"kein-echtes-konto"}')
  # 400 = Anmeldung abgelehnt. Genau das erwarten wir: Die Datenbank wurde
  # nach dem Konto befragt, es gibt keins.
  #
  # 401 waere hier KEIN Erfolg, auch wenn es nach einer Antwort aussieht: Das
  # ist der abgelehnte API-Schluessel, die Anfrage kam nie bei Postgres an.
  # Genau diese Verwechslung haette einen Wachhalter erzeugt, der jeden Tag
  # gruen meldet, waehrend das Projekt in Ruhe einschlaeft.
  if [ "$status" = "400" ]; then
    echo "  Anmeldeversuch (Rueckfall): $status"
    hinweis="$hinweis Nur der schwache Rueckfall ueber die Anmeldung hat gegriffen."
    return 0
  fi

  echo "  Kein Weg hat gegriffen (zuletzt: $status)"
  if [ "$status" = "000" ]; then
    hinweis="Der Name loest nicht auf - das Projekt ist vermutlich pausiert und muss im Dashboard wiederhergestellt werden."
  fi
  return 1
}

echo "Wachhalter, $(date -u '+%Y-%m-%d %H:%M UTC')"
echo

for slot in $(seq 1 "$MAX_SLOTS"); do
  url_var="SB_URL_$slot"
  key_var="SB_KEY_$slot"
  tab_var="SB_TAB_$slot"

  url="${!url_var:-}"
  key="${!key_var:-}"
  tab="${!tab_var:-}"

  [ -z "$url" ] && continue
  gefunden=$((gefunden + 1))

  # Der Projektname aus der URL ist im oeffentlichen Protokoll unbedenklich
  # nur als Nummer - die URL selbst ist ein Secret und wuerde ohnehin
  # maskiert.
  echo "Projekt $slot"

  if [ -z "$key" ]; then
    echo "  Kein Schluessel eingetragen"
    kaputt="$kaputt\n- Projekt $slot: kein anon-Schluessel eingetragen."
    echo
    continue
  fi

  erfolge=0
  letzter_hinweis=""

  for i in $(seq 1 "$ANFRAGEN"); do
    if anklopfen "$slot" "$url" "$key" "$tab"; then
      erfolge=$((erfolge + 1))
    fi
    [ -n "$hinweis" ] && letzter_hinweis="$hinweis"
    # Zwischen den Anfragen warten, damit es als verteilte Aktivitaet
    # ankommt und nicht als eine einzige Sekunde Laerm.
    [ "$i" -lt "$ANFRAGEN" ] && sleep "$ABSTAND"
  done

  echo "  $erfolge von $ANFRAGEN Anfragen haben Aktivitaet erzeugt"

  if [ "$erfolge" -eq 0 ]; then
    kaputt="$kaputt\n- Projekt $slot: keine einzige Anfrage kam durch. $letzter_hinweis"
  elif [ -n "$letzter_hinweis" ]; then
    wach="$wach\n- Projekt $slot: wach, aber die Einstellung stimmt nicht. $letzter_hinweis"
  fi
  echo
done

echo "----"

if [ "$gefunden" -eq 0 ]; then
  echo "::error::Kein einziges Projekt eingetragen. Ohne SUPABASE_URL tut der Wachhalter nichts."
  exit 1
fi

echo "$gefunden Projekt(e) geprueft."

if [ -n "$kaputt" ]; then
  echo "::error::Mindestens ein Projekt bekommt keine Aktivitaet:"
  printf "%b\n" "$kaputt"
  exit 1
fi

if [ -n "$wach" ]; then
  echo "::error::Alle Projekte sind wach, aber eine Einstellung ist veraltet:"
  printf "%b\n" "$wach"
  echo "::error::Der Rueckfall haelt das Projekt vorerst wach. Trotzdem reparieren - der naechste Umbau der Datenbank koennte auch ihn treffen."
  exit 1
fi

echo "Alle Projekte sind wach."
