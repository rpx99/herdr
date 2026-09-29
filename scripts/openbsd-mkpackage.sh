#!/bin/sh
#
# Baut das OpenBSD-Paket herdr-X.Y.Z.tgz aus dem lokalen Repo-Stand -
# komplett OHNE root (alles landet unter ~/.herdr-ports und openbsd-port/
# im Repo). Nur die optionale Installation mit pkg_add braucht doas.
#
# Aufruf bei einem neuen Release:
#   ./scripts/openbsd-mkpackage.sh --check    # neuer Commit auf herdrdev/herdr?
#   git fetch upstream && git rebase upstream/main   # Sync holen (nicht git pull)
#   ./scripts/openbsd-mkpackage.sh            # nur bauen
#   ./scripts/openbsd-mkpackage.sh -i         # bauen + installieren
#   ./scripts/openbsd-mkpackage.sh -p         # bauen + committen + auf Fork pushen
#   ./scripts/openbsd-mkpackage.sh -ip        # alles zusammen
#   ./scripts/openbsd-mkpackage.sh -i 0.9.4   # Version explizit vorgeben
#
# Ueberschreibbar per Env: HERDR_PORTS_BASE, DISTDIR, WRKOBJDIR,
# PACKAGE_REPOSITORY (oder historisch PACKAGES), PLIST_REPOSITORY, PORTTREE,
# PORTSDIR, MAINTAINER, FORK_URL, UPSTREAM_URL, DRY_RUN=1
set -eu

DRY=${DRY_RUN:-0}
MAINTAINER=${MAINTAINER:-Robert Palm <developer@robert-palm.de>}
INSTALL_AFTER=0
PUSH_AFTER=0
FORK_URL=${FORK_URL:-}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/herdrdev/herdr.git}

run() {
	if [ "$DRY" = 1 ]; then echo "[dry] $*"; else "$@"; fi
}

usage() {
	cat <<EOF
usage: $(basename "$0") [-h] [--check] [-i] [-p] [-ip] [VERSION]

Baut herdr-VERSION.tgz aus dem lokalen Repo-Stand - ohne root.
Nur die optionale Installation mit pkg_add braucht doas.

Optionen:
  -h, --help   diese Hilfe
  --check      neuen Upstream-Sync pruefen (upstream/main, nicht der Fork)
  -i           nach dem Bau mit pkg_add installieren
  -p           nach dem Bau committen und auf den Fork pushen
  -ip, -pi     -i und -p zusammen
  VERSION      z.B. 0.9.4 (sonst aus Cargo.toml)

Umgebung:
  DRY_RUN=1              nur anzeigen, nichts schreiben
  REVISION=0             Ports-REVISION (Paket 0.9.3p0). Leer = erste
                         Ausgabe dieser Cargo-Version. Ungesetzt = auto
                         (naechstes pN wenn Tag vVERSION-openbsd existiert)
  HERDR_PORTS_BASE       Default: ~/.herdr-ports
  KEEP_BUILDS=2          so viele zuletzt gebaute Versionen behalten
  DISTDIR, WRKOBJDIR, PACKAGE_REPOSITORY, PLIST_REPOSITORY
  PORTTREE, PORTSDIR, MAINTAINER, FORK_URL, UPSTREAM_URL

Beispiele:
  $0                 nur bauen
  $0 -i              bauen und installieren
  $0 --check
  $0 -i 0.9.4
EOF
}

ver_of() {
	awk '/^version/ {gsub(/"/, "", $3); print $3; exit}' "$1"
}

# Alte Build-Reste loeschen und nur die KEEP_BUILDS zuletzt erfolgreich
# gebauten Versionen behalten. Basis sind die vorhandenen Pakete: nur ein
# erfolgreicher 'package'-Lauf hinterlaesst herdr-V.tgz.
clean_old_builds() {
	[ "$DRY" = 1 ] && return 0
	KEEP=${KEEP_BUILDS:-2}
	case $KEEP in
	""|*[!0-9]*) echo "FEHLER: KEEP_BUILDS muss eine Zahl sein (ist: '$KEEP')"; exit 1 ;;
	esac
	all=$(ls -1t "$PACKAGE_REPOSITORY"/*/all/herdr-*.tgz 2>/dev/null) || true
	[ -n "$all" ] || return 0
	keep=""
	drop=""
	for f in $all; do
		b=${f##*/}
		v=${b#herdr-}
		v=${v%.tgz}
		case " $keep $drop " in
		*" $v "*)	continue ;;
		esac
		if [ "$(printf '%s\n' $keep | grep -c .)" -lt "$KEEP" ]; then
			keep="$keep $v"
		else
			drop="$drop $v"
		fi
	done
	# Laufende Version nie anfassen, auch wenn KEEP_BUILDS kleiner ist.
	case " $drop " in
	*" $FULLPKG_VERSION "*)	drop=$(printf '%s\n' $drop | while read -r v; do
			[ "$v" = "$FULLPKG_VERSION" ] || echo "$v"
		done);;
	esac
	[ -n "$drop" ] || return 0
	for v in $drop; do
		echo "==> Aufraeumen: alte Version $v (behalte:$(printf ' %s' $keep))"
		rm -rf "${WRKOBJDIR:?}/herdr-$v"
		cv=${v%p*}
		rm -f "${DISTDIR:?}/herdr-$cv.tar.gz"
		rm -f "$PACKAGE_REPOSITORY"/*/all/"herdr-$v.tgz"
		rm -f "$PACKAGE_REPOSITORY"/*/ftp/"herdr-$v.tgz"
		rm -f "$PLIST_REPOSITORY"/*/"herdr-$v"
	done
}

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
	|| { echo "FEHLER: nicht in einem Git-Repository"; exit 1; }

BASE=${HERDR_PORTS_BASE:-$HOME/.herdr-ports}
DISTDIR=${DISTDIR:-$BASE/distfiles}
WRKOBJDIR=${WRKOBJDIR:-$BASE/wrk}
PACKAGE_REPOSITORY=${PACKAGE_REPOSITORY:-${PACKAGES:-$BASE/packages}}
PLIST_REPOSITORY=${PLIST_REPOSITORY:-$BASE/plist}
PORTSDIR=${PORTSDIR:-/usr/ports}
# User-eigener Ports-Baum im "mystuff"-Stil: <tree>/devel/herdr,
# wird per PORTSDIR_PATH vor /usr/ports durchsucht.
PORTTREE=${PORTTREE:-$REPO/openbsd-port}

MODE=build
V_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help)	usage; exit 0 ;;
	--check)	MODE=check ;;
	-i)		INSTALL_AFTER=1 ;;
	-p)		PUSH_AFTER=1 ;;
	-ip|-pi)	INSTALL_AFTER=1; PUSH_AFTER=1 ;;
	-.*)		echo "FEHLER: unbekannte Option '$1'" >&2; usage >&2; exit 1 ;;
	-*)		echo "FEHLER: unbekannte Option '$1'" >&2; usage >&2; exit 1 ;;
	*)		V_OVERRIDE=$1 ;;
	esac
	shift
done

V=${V_OVERRIDE:-$(ver_of "$REPO/Cargo.toml")}
[ -n "$V" ] || { echo "FEHLER: Version nicht ermittelbar (Parameter angeben)"; exit 1; }

# Same Cargo version, new upstream dump: OpenBSD REVISION (0.9.3 -> 0.9.3p0).
# Tag vX.Y.Z-openbsd is the first package; vX.Y.Z-openbsd.1 is p0, .2 is p1.
PKG_REVISION=""
if [ "${REVISION+x}" = x ]; then
	PKG_REVISION=$REVISION
else
	git -C "$REPO" fetch origin --tags >/dev/null 2>&1 || true
	if git -C "$REPO" rev-parse -q --verify "refs/tags/v${V}-openbsd" >/dev/null 2>&1; then
		n=0
		while git -C "$REPO" rev-parse -q --verify "refs/tags/v${V}-openbsd.$((n + 1))" >/dev/null 2>&1; do
			n=$((n + 1))
		done
		PKG_REVISION=$n
	fi
fi
if [ -z "$PKG_REVISION" ]; then
	FULLPKG_VERSION="$V"
else
	FULLPKG_VERSION="${V}p${PKG_REVISION}"
fi
FULLPKG="herdr-$FULLPKG_VERSION"
if [ -z "$PKG_REVISION" ]; then
	GH_TAG="v${V}-openbsd"
else
	GH_TAG="v${V}-openbsd.$((PKG_REVISION + 1))"
fi

if [ "$MODE" = check ]; then
	# origin is the fork. New upstream syncs land on upstream/main.
	if ! git -C "$REPO" remote get-url upstream >/dev/null 2>&1; then
		git -C "$REPO" remote add upstream "$UPSTREAM_URL"
	fi
	git -C "$REPO" fetch upstream main >/dev/null 2>&1 \
		|| { echo "FEHLER: git fetch upstream fehlgeschlagen (Netz?)"; exit 1; }
	CARGO=Cargo.toml
	LV=$(ver_of "$REPO/$CARGO")
	RV=$(git -C "$REPO" show "upstream/main:$CARGO" \
		| awk '/^version/ {gsub(/"/, "", $3); print $3; exit}')
	HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
	UP_SHA=$(git -C "$REPO" rev-parse upstream/main)
	BASE_SHA=$(git -C "$REPO" merge-base HEAD upstream/main)
	echo "lokal    : $LV ($(git -C "$REPO" rev-parse --short HEAD))"
	echo "upstream : $RV ($(git -C "$REPO" rev-parse --short upstream/main))"
	O=$(git -C "$REPO" rev-parse --short origin/main 2>/dev/null || true)
	if [ -n "$O" ]; then
		echo "Fork     : $O (origin, nicht die Sync-Quelle)"
	fi
	if [ "$UP_SHA" = "$BASE_SHA" ]; then
		echo "==> kein neuer Upstream-Sync: upstream/main steckt bereits in HEAD."
	else
		N=$(git -C "$REPO" rev-list --count "$BASE_SHA".."$UP_SHA")
		echo "==> $N neuer Upstream-Commit(s) auf upstream/main (nicht in HEAD):"
		git -C "$REPO" --no-pager log --oneline -15 "$BASE_SHA".."$UP_SHA"
		if [ "$N" -gt 15 ]; then
			echo "    ... ($N insgesamt)"
		fi
		if [ "$LV" = "$RV" ]; then
			echo "==> Cargo-Version bleibt $RV (Upstream bumpt nicht bei jedem Sync)."
		else
			echo "==> Cargo-Version $LV -> $RV"
		fi
		echo "Dann (nicht git pull — origin ist der Fork):"
		echo "    git fetch upstream && git rebase upstream/main"
		echo "    $0"
	fi
	exit 0
fi

for tool in git rustc cargo pkg-config make awk grep pax; do
	command -v "$tool" >/dev/null || { echo "FEHLER: '$tool' fehlt"; exit 1; }
done
# libghostty-vt (Zig) braucht zig 0.16; liegt es nur im User-Prefix, ZIG_BIN setzen.
if ! command -v zig >/dev/null 2>&1; then
	LOCAL_ZIG="$HOME/.herdr-ports/opt/zig/bin/zig"
	[ -x "$LOCAL_ZIG" ] || { echo "FEHLER: zig 0.16 nicht gefunden (doas pkg_add zig oder ~/.herdr-ports/opt/zig)"; exit 1; }
	ZIG_BIN="$LOCAL_ZIG"
	echo "==> ZIG_BIN=$ZIG_BIN"
fi
[ -d "$PORTSDIR" ] || { echo "FEHLER: $PORTSDIR existiert nicht (ports(7))"; exit 1; }

echo "==> Version: $V${PKG_REVISION:+p$PKG_REVISION}  (GitHub-Tag $GH_TAG)"
echo "==> Verzeichnisse: PORTTREE=$PORTTREE DISTDIR=$DISTDIR"

# 1. Quell-Tarball aus dem lokalen Stand (inkl. uncommitteter Aenderungen;
#    Kern-Dumps und Paket-Metadaten-Reste ausschliessen)
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT INT TERM
(cd "$REPO" && git ls-files -co --exclude-standard \
	| grep -vE '(^|/)([^/]*\.core|core|\+[^/]*)$' \
	| while IFS= read -r file; do
		if [ -e "$file" ] || [ -L "$file" ]; then
			printf '%s\n' "$file"
		fi
	done) >"$LIST"

# Ein Dry-Run darf weder den Workdir loeschen noch die eingecheckten
# Port-Metadaten ueberschreiben oder leeren.
if [ "$DRY" = 1 ]; then
	echo "[dry] pax -w -z -f $DISTDIR/herdr-$V.tar.gz  (< Dateiliste, Prefix herdr-$V/)"
	echo "[dry] Port-Skelett unter $PORTTREE/devel/herdr erzeugen"
	echo "[dry] modcargo-gen-crates, makesum und package ausfuehren"
	exit 0
fi

# Alte Build-Reste wegwerfen: Extraktion muss IMMER dem aktuellen Tarball
# entsprechen (Cookie-Timestamps truegen sonst bei geaendertem Inhalt).
rm -rf "${WRKOBJDIR:?}/herdr-$V"

mkdir -p "$DISTDIR"
(cd "$REPO" && pax -w -z -x ustar -s ",^,herdr-$V/," -f "$DISTDIR/herdr-$V.tar.gz" <"$LIST")

# 2. Port-Skelett schreiben (im Repo, user-eigen, Kategorie-Layout).
#    Makefile/DESCR/PLIST bleiben zwischen Versionen stabil; nur V und
#    REVISION werden gesetzt.
PORTDIR="$PORTTREE/devel/herdr"
mkdir -p "$PORTDIR/pkg"

REVISION_LINE=""
if [ -n "$PKG_REVISION" ]; then
	REVISION_LINE="REVISION =	$PKG_REVISION"
fi

if [ ! -f "$PORTDIR/Makefile" ]; then
	echo "FEHLER: $PORTDIR/Makefile fehlt (sollte eingecheckt sein)"; exit 1
fi

: >"$PORTDIR/crates.inc"
# distinfo ebenfalls wegwerfen: es referenziert die alten Cargo-Eintraege,
# die die (noch leere) Liste bei NO_CHECKSUM als "Extra file" meldet.
rm -f "$PORTDIR/distinfo"

# 3. Port-Mechanik - alle Schreibpfade liegen beim Nutzer, kein root noetig.
#    Variablen als MAKE-ARGUMENTE: Kommandozeile schlaegt auch /etc/mk.conf.
MKVARS="PORTSDIR=$PORTSDIR PORTSDIR_PATH=$PORTTREE:$PORTSDIR:$PORTSDIR/mystuff WRKOBJDIR=$WRKOBJDIR LOCKDIR=$BASE/locks DISTDIR=$DISTDIR PACKAGE_REPOSITORY=$PACKAGE_REPOSITORY PLIST_REPOSITORY=$PLIST_REPOSITORY ${ZIG_BIN:+ZIG_BIN=$ZIG_BIN}"
mkdir -p "$BASE/locks" "$PLIST_REPOSITORY"

# 3b. Crate-Liste aus Cargo.lock generieren (erster Lauf ohne Checksummen),
#     dann laedt makesum alle Crates und schreibt die Pruefsummen.
cd "$PORTDIR"
make $MKVARS modcargo-gen-crates NO_CHECKSUM=Yes >"$LIST"
grep '^MODCARGO_CRATES' "$LIST" >"$PORTDIR/crates.inc"
[ -s "$PORTDIR/crates.inc" ] \
	|| { echo "FEHLER: keine Crates in Cargo.lock erkannt"; exit 1; }
echo "==> crates.inc: $(grep -c . "$PORTDIR/crates.inc") Crates"
run make $MKVARS makesum
echo "==> distinfo: $(grep -c 'SHA256' "$PORTDIR/distinfo" 2>/dev/null || echo 0) Checksummen"
# Crates sind jetzt komplett da -> Workdir verwerfen, damit das folgende
# 'package' sie frisch extrahiert (sonst leert der alte Cookie den Vendor-Dir).
# Das vorhandene .tgz IST der Ports-Cookie (_PACKAGE_COOKIE): ohne Loeschen
# macht 'make package' nur "Link to .../ftp/..." und baut nicht neu.
rm -rf "${WRKOBJDIR:?}/herdr-$V"
if [ -d "$PACKAGE_REPOSITORY" ]; then
	find "$PACKAGE_REPOSITORY" -name "$FULLPKG.tgz" -print -delete
fi

# Preflight: WANTLIB des Ports-Baums gegen die tatsaechlich installierten
# Bibliotheken pruefen. Reine Metadaten-Auswertung, ~2s.
check_wantlib() {
	make $MKVARS port-wantlib-args >"$LIST" 2>/dev/null \
		|| { echo "FEHLER: make port-wantlib-args fehlgeschlagen (PORTSDIR/PORTSDIR_PATH pruefen)"; exit 1; }
	bad=0
	while read -r tag lib; do
		[ "$tag" = "-W" ] || continue
		[ -n "$lib" ] || continue
		name=${lib%%.*}
		ver=${lib#*.}
		found=0
		for d in /usr/local/lib /usr/lib /usr/X11R6/lib; do
			if [ -e "$d/lib${name}.so.${ver}" ]; then found=1; break; fi
		done
		if [ "$found" = 0 ]; then
			bad=1
			echo "   fehlt installiert: $lib"
		fi
	done <"$LIST"
	if [ "$bad" = 1 ]; then
		echo "FEHLER: Ports-Baum ($PORTSDIR) und installierte Pakete sind nicht synchron."
		echo "Beheben: Baum aelter als Pakete -> doas git -C $PORTSDIR pull"
		echo "         Baum neuer als Pakete -> doas pkg_add -u"
		exit 1
	fi
}
check_wantlib

run make $MKVARS package

PKG=""
for f in "$PACKAGE_REPOSITORY"/*/all/"$FULLPKG".tgz; do
	if [ -f "$f" ]; then
		PKG=$f
		break
	fi
done
if [ -z "$PKG" ]; then
	echo "FEHLER: fertiges Paket nicht gefunden (make-Ausgabe oben pruefen)"; exit 1
fi

echo "==> Paket: $PKG"
echo "==> GitHub-Tag: $GH_TAG"

# 3e. Alte Versionen wegraeumen (Default: nur die 2 zuletzt gebauten behalten).
clean_old_builds

# 4. Optional: Stand committen und auf den eigenen Fork pushen
if [ "$PUSH_AFTER" = 1 ]; then
	cd "$REPO"
	# Remotes sicherstellen: origin=Fork, upstream=herdrdev. Ein vorhandenes
	# origin, das nicht herdrdev ist, gilt als Fork und braucht kein FORK_URL.
	if ORIGIN_URL=$(git remote get-url origin 2>/dev/null); then
		case "$ORIGIN_URL" in
		*github.com/herdrdev/herdr*)
			if git remote get-url upstream >/dev/null 2>&1; then
				[ -n "$FORK_URL" ] || {
					echo "FEHLER: origin zeigt auf herdrdev; FORK_URL fuer den eigenen Fork setzen." >&2
					exit 1
				}
				git remote set-url origin "$FORK_URL"
			else
				git remote rename origin upstream
				ORIGIN_URL=""
			fi
			;;
		esac
	else
		ORIGIN_URL=""
	fi
	if ! git remote get-url origin >/dev/null 2>&1; then
		[ -n "$FORK_URL" ] || {
			echo "FEHLER: kein Fork als origin; FORK_URL setzen." >&2
			exit 1
		}
		git remote add origin "$FORK_URL"
	fi
	FORK_URL=$(git remote get-url origin)
	git remote get-url upstream >/dev/null 2>&1 \
		|| git remote add upstream "$UPSTREAM_URL"

	# Alles Uncommittete rein (ausser Kern-Dumps/Paket-Reste)
	if ! git diff --quiet HEAD || ! git diff --cached --quiet HEAD \
		|| [ -n "$(git ls-files --others --exclude-standard | grep -vE '(^|/)([^/]*\.core|core|\+[^/]*)$')" ]; then
		git add -A -- . ':(exclude)*.core' ':(exclude)+*' 2>/dev/null || git add -A
		git commit -m "OpenBSD port support (herdr $V)

- openbsd-port/-Skeleton und Paketbau-Skript (ports(7), ohne root)"
	else
		echo "==> Keine Aenderungen zu committen."
	fi
	echo "==> Push auf $FORK_URL ..."
	if ! git push origin main; then
		echo "HINWEIS: Push fehlgeschlagen. Fork anlegen und als origin konfigurieren:" >&2
		echo "  git remote set-url origin <URL-DES-EIGENEN-FORKS>" >&2
	fi
fi

# 5. Optional installieren - pkg_add ist Systemverwaltung und braucht doas.
#    -u interpretiert Argumente als installierte PaketNAMEN, nicht als
#    Dateipfad. -r ersetzt das vorhandene Paket, -D unsigned erlaubt das
#    unsignierte Lokal-tgz.
if [ "$INSTALL_AFTER" = 1 ]; then
	if [ "$(id -u)" = 0 ]; then
		pkg_add -r -D unsigned "$PKG"
	else
		if command -v doas >/dev/null 2>&1; then
			doas pkg_add -r -D unsigned "$PKG"
		else
			sudo pkg_add -r -D unsigned "$PKG"
		fi
	fi
else
	echo "==> Installieren (nicht -u mit Dateipfad!):"
	echo "    doas pkg_add -r -D unsigned $PKG"
fi
