#!/usr/bin/env bash
# Motor de instalación de uxdeployar en un VPS limpio (Debian 13 o Ubuntu 26.04), como root.
# No pregunta nada: lo lanza el programa del PC (`uxdeployar-pc instalar`) con todas las
# opciones y --yes. Endurece el VPS (etapas E00-E16), instala la plataforma y publica
# uxdeployar con las imágenes fijadas por digest del release. Sigue sola tras desconexiones y
# reinicios (servicio uxdeployar-install); el avance se ve con `uxdeployar logs`.
# Opciones: install.sh --help. Este archivo lo genera `pnpm installer:build`
# (installer/install.sh + runtime/lib/release.sh); el que se publica es installer/dist/install.sh.
set -euo pipefail

UX_SIGNING_PUBKEY_DEFAULT='RWTeEjmBL57PV3enaNRPhNvmmUnFWAzhnB0PT1qy77rCq35f1lduXfCr'
UX_ETC_APP=/etc/ux/uxdeployar
UX_PACK=/opt/ux-infra/05-vps/agent
UX_RELEASES=/opt/ux-infra/05-vps/releases

# shellcheck shell=bash
# Releases de uxdeployar: descarga por la API de GitHub (o de un espejo,
# UX_RELEASE_URL) y verificación (firma minisign de SHA256SUMS, sumas de cada
# asset y versión del manifest).
# La usan la CLI `uxdeployar` y install.sh (pnpm installer:build la incrusta).
# Intenta sin credenciales; con UX_GH_TOKEN la cabecera va por stdin de curl,
# nunca en argv, y nunca se envía al espejo.

: "${UX_RELEASE_REPO:=uxlelmar-eaac/uxdeployar-backend}"
: "${UX_GH_API:=https://api.github.com}"
UX_RELEASE_ASSETS=(manifest.json uxdeployar-bundle.tar.gz)

ux__curl() { # curl args... (token por --config en stdin)
  local -a base=(-sS -L --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 20)
  if [ -n "${UX_GH_TOKEN:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$UX_GH_TOKEN" | curl "${base[@]}" --config - "$@"
  else
    curl "${base[@]}" "$@" </dev/null
  fi
}

# Imprime el código HTTP; el cuerpo queda en <salida>.
ux_gh() { # url salida [accept]
  ux__curl -o "$2" -w '%{http_code}' -H "Accept: ${3:-application/vnd.github+json}" \
    -H 'X-GitHub-Api-Version: 2022-11-28' "$1" || printf '000'
}

ux_es_version() { [[ ${1:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; }

# 0 = JSON del release en <salida>; 2 = pide token (401/403/404 sin token); 1 = otro fallo.
ux_release_json() { # version|latest salida
  local url code
  if [ "$1" = latest ]; then
    url="$UX_GH_API/repos/$UX_RELEASE_REPO/releases/latest"
  else
    ux_es_version "$1" || { echo "versión inválida: $1 (vX.Y.Z)" >&2; return 1; }
    url="$UX_GH_API/repos/$UX_RELEASE_REPO/releases/tags/$1"
  fi
  code="$(ux_gh "$url" "$2")"
  case "$code" in
    200) return 0 ;;
    401 | 403 | 404)
      [ -z "${UX_GH_TOKEN:-}" ] && return 2
      echo "GitHub respondió $code para $UX_RELEASE_REPO ($1): el token no puede leer ese release" >&2
      return 1
      ;;
    *) echo "GitHub respondió $code para $UX_RELEASE_REPO ($1)" >&2; return 1 ;;
  esac
}

# Versiones publicadas con todos los assets, de la más reciente a la más antigua: «<versión> <0|1>»
# por línea (1 = prerelease). La firma se comprueba al descargar. Retorna como ux_release_json.
ux_releases_listar() {
  local tmp code rc=0 v
  tmp="$(mktemp)"
  if [ -n "${UX_RELEASE_URL:-}" ]; then
    code="$(ux__espejo "$UX_RELEASE_URL/latest" "$tmp")"
    v="$(tr -d '[:space:]' <"$tmp")"
    rm -f "$tmp"
    [ "$code" = 200 ] && ux_es_version "$v" || { echo "el espejo $UX_RELEASE_URL respondió $code para latest" >&2; return 1; }
    printf '%s 0\n' "$v"
    return 0
  fi
  code="$(ux_gh "$UX_GH_API/repos/$UX_RELEASE_REPO/releases?per_page=30" "$tmp")"
  case "$code" in
    200) ;;
    401 | 403 | 404) [ -z "${UX_GH_TOKEN:-}" ] && rc=2 || rc=1 ;;
    *) rc=1 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    [ "$rc" -eq 2 ] || echo "GitHub respondió $code al listar los releases de $UX_RELEASE_REPO" >&2
    return "$rc"
  fi
  python3 - "$tmp" "${UX_RELEASE_ASSETS[@]}" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
needed = {"SHA256SUMS", "SHA256SUMS.minisig", *sys.argv[2:]}
for r in data:
    tag = r.get("tag_name", "")
    names = {a.get("name") for a in r.get("assets", [])}
    if r.get("draft") or not re.fullmatch(r"v\d+\.\d+\.\d+(-rc\.\d+)?", tag) or not needed <= names:
        continue
    print(tag, 1 if r.get("prerelease") else 0)
PY
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# Campos del JSON sin jq: tag o URL de API de un asset.
ux_release_campo() { # json tag|asset:<nombre>
  python3 - "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
what = sys.argv[2]
if what == "tag":
    print(data.get("tag_name", ""))
else:
    name = what.split(":", 1)[1]
    print(next((a["url"] for a in data.get("assets", []) if a.get("name") == name), ""))
PY
}

# Assets de un release de GitHub en <dir>; imprime la etiqueta. Retorna como ux_release_json.
ux__bajar_github() { # version|latest dir
  local dir="$2" json tag nombre url code rc=0
  json="$dir/release.json"
  ux_release_json "$1" "$json" || rc=$?
  [ "$rc" -eq 0 ] || { rm -f "$json"; return "$rc"; }
  tag="$(ux_release_campo "$json" tag)"
  ux_es_version "$tag" || { echo "el release no tiene una etiqueta vX.Y.Z: $tag" >&2; return 1; }
  for nombre in SHA256SUMS SHA256SUMS.minisig "${UX_RELEASE_ASSETS[@]}"; do
    url="$(ux_release_campo "$json" "asset:$nombre")"
    [ -n "$url" ] || { echo "el release $tag no trae $nombre" >&2; return 1; }
    code="$(ux_gh "$url" "$dir/$nombre" application/octet-stream)"
    [ "$code" = 200 ] || { echo "no pude descargar $nombre de $tag (HTTP $code)" >&2; return 1; }
  done
  rm -f "$json"
  printf '%s\n' "$tag"
}

# Espejo propio: <url>/latest con la etiqueta y <url>/<versión>/<asset>. Sin token; la firma protege
# el contenido, así que también vale http (p. ej. un servidor de la red interna).
ux__espejo() { # url salida
  curl -sS -L --proto '=https,http' --retry 3 --retry-delay 2 --connect-timeout 20 \
    -o "$2" -w '%{http_code}' "$1" </dev/null || printf '000'
}

ux__bajar_espejo() { # version|latest dir
  local tag="$1" dir="$2" nombre code
  if [ "$tag" = latest ]; then
    code="$(ux__espejo "$UX_RELEASE_URL/latest" "$dir/latest")"
    [ "$code" = 200 ] || { echo "el espejo $UX_RELEASE_URL respondió $code para latest" >&2; return 1; }
    tag="$(tr -d '[:space:]' <"$dir/latest")"
    rm -f "$dir/latest"
  fi
  ux_es_version "$tag" || { echo "versión inválida: $tag (vX.Y.Z)" >&2; return 1; }
  for nombre in SHA256SUMS SHA256SUMS.minisig "${UX_RELEASE_ASSETS[@]}"; do
    code="$(ux__espejo "$UX_RELEASE_URL/$tag/$nombre" "$dir/$nombre")"
    [ "$code" = 200 ] || { echo "no pude descargar $nombre de $tag del espejo (HTTP $code)" >&2; return 1; }
  done
  printf '%s\n' "$tag"
}

# Descarga y verifica un release en <dir> y extrae su paquete en <dir>/bundle.
# Imprime la versión. Retorna como ux_release_json.
ux_release_descargar() { # version|latest dir
  local version="$1" dir="$2" tag rc=0
  : "${UX_SIGNING_PUBKEY:?falta la llave pública de firma (--signing-pubkey)}"
  install -d -m 755 "$dir"
  if [ -n "${UX_RELEASE_URL:-}" ]; then
    tag="$(ux__bajar_espejo "$version" "$dir")" || return 1
  else
    tag="$(ux__bajar_github "$version" "$dir")" || { rc=$?; return "$rc"; }
  fi
  ux_release_verificar "$dir" "$tag" || return 1
  install -d -m 755 "$dir/bundle"
  tar --no-same-owner -xzf "$dir/uxdeployar-bundle.tar.gz" -C "$dir/bundle" ||
    { echo "no pude extraer el paquete de $tag" >&2; return 1; }
  [ -x "$dir/bundle/installer/runtime/uxdeployar" ] ||
    { echo "el paquete de $tag no trae installer/runtime/uxdeployar" >&2; return 1; }
  printf '%s\n' "$tag"
}

# Firma con la llave configurada, suma de cada asset y manifest de esa misma versión.
ux_release_verificar() { # dir version
  local dir="$1" nombre
  minisign -Vq -P "$UX_SIGNING_PUBKEY" -m "$dir/SHA256SUMS" -x "$dir/SHA256SUMS.minisig" >/dev/null 2>&1 ||
    { echo "la firma de SHA256SUMS no coincide con la llave configurada: release rechazado" >&2; return 1; }
  for nombre in "${UX_RELEASE_ASSETS[@]}"; do
    grep -qE "^[0-9a-f]{64}  $nombre\$" "$dir/SHA256SUMS" ||
      { echo "SHA256SUMS no incluye $nombre: release rechazado" >&2; return 1; }
  done
  (cd "$dir" && grep -E "  ($(IFS='|'; echo "${UX_RELEASE_ASSETS[*]//./\\.}"))\$" SHA256SUMS | sha256sum -c --quiet -) >/dev/null 2>&1 ||
    { echo "las sumas de los assets no coinciden: release rechazado" >&2; return 1; }
  [ "$(ux_manifest "$dir/manifest.json" version)" = "$2" ] ||
    { echo "manifest.json no es de $2: release rechazado" >&2; return 1; }
}

# Campos del manifest: version | <rol>.repo | <rol>.tag | <rol>.digest
ux_manifest() { # manifest campo
  python3 - "$1" "$2" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
field = sys.argv[2]
if field == "version":
    print(m.get("version", ""))
    raise SystemExit
role, key = field.split(".", 1)
value = m.get("images", {}).get(role, {}).get(key, "")
checks = {"repo": r"[a-z0-9][a-z0-9./_-]*", "tag": r"[0-9a-f]{12}", "digest": r"sha256:[0-9a-f]{64}"}
if not re.fullmatch(checks[key], value):
    raise SystemExit("manifest: %s inválido" % field)
print(value)
PY
}

uso() {
  cat <<'EOF'
Uso: install.sh --panel-domain FQDN --api-domain FQDN --acme-email CORREO [opciones] --yes
  --panel-domain FQDN      dominio del panel (p. ej. panel.ejemplo.com)
  --api-domain FQDN        dominio de la API (p. ej. api.ejemplo.com)
  --acme-email CORREO      correo para Let's Encrypt (también el del administrador del panel)
  --admin-email CORREO     correo del administrador del panel (por defecto, el de ACME)
  --ssh-port N             puerto SSH final (1024-65535; por defecto 2222)
  --ssh-key ARCHIVO        llave pública del administrador (por defecto, las de root)
  --admin-user NOMBRE      usuario administrador del VPS (por defecto vpsadmin)
  --public-ip IP           IP pública si el VPS no la ve en su interfaz (NAT)
  --timezone ZONA          zona horaria IANA (por defecto la del sistema, o UTC)
  --version vX.Y.Z         versión a instalar (por defecto la última)
  --token-file ARCHIVO     token de GitHub de solo lectura (repos privados; - lo lee de stdin)
  --release-repo DUEÑO/REPO   origen de los releases (UX_RELEASE_REPO)
  --release-url URL           espejo propio de los releases (<url>/latest, <url>/<versión>/<asset>)
  --registry HOST/DUEÑO       registro de las imágenes (UX_IMAGE_REGISTRY)
  --signing-pubkey LLAVE      llave pública minisign de los releases
  --acme-ca URL               CA ACME privada en lugar de Let's Encrypt (directorio https)
  --acme-ca-root ARCHIVO      raíz PEM que firma el certificado TLS de esa CA
  --yes                    confirma la instalación (sin él solo muestra el resumen)
Respaldos, alertas y 2FA de SSH se configuran después desde el panel.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf -- '-> %s\n' "$*"; }

leer_archivo() {
  if [ "$1" = - ]; then
    head -n 1 | tr -d '\r\n'
    return 0
  fi
  [ -r "$1" ] || die "no puedo leer $1"
  head -n 1 "$1" | tr -d '\r\n'
}

opciones() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --help | -h) uso; exit 0 ;;
      --yes) SI=1; shift; continue ;;
    esac
    [ $# -ge 2 ] || die "falta el valor de $1"
    case "$1" in
      --panel-domain) UX_PANEL_DOMAIN="$2" ;;
      --api-domain) UX_API_DOMAIN="$2" ;;
      --acme-email) UX_ACME_EMAIL="$2" ;;
      --admin-email) UX_ADMIN_EMAIL="$2" ;;
      --ssh-port) UX_SSH_PORT="$2" ;;
      --ssh-key) LLAVE_ADMIN="$(cat "$2")" || die "no puedo leer $2" ;;
      --admin-user) UX_ADMIN_USER="$2" ;;
      --public-ip) UX_PUBLIC_IP="$2" ;;
      --timezone) UX_TIMEZONE="$2" ;;
      --version) VERSION="$2" ;;
      --token-file) UX_GH_TOKEN="$(leer_archivo "$2")" ;;
      --release-repo) UX_RELEASE_REPO="$2" ;;
      --release-url) UX_RELEASE_URL="${2%/}" ;;
      --acme-ca) UX_ACME_CA="$2" ;;
      --acme-ca-root) RAIZ_ACME="$2" ;;
      --registry) UX_IMAGE_REGISTRY="$2" ;;
      --signing-pubkey) UX_SIGNING_PUBKEY="$2" ;;
      *) die "opción desconocida: $1 (ver --help)" ;;
    esac
    shift 2
  done
}

sistema_soportado() {
  local id ver
  id="$(. /etc/os-release && printf '%s' "${ID:-}")"
  ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  case "$id:$ver" in
    debian:13 | ubuntu:26.04) return 0 ;;
  esac
  die "sistema no soportado: $id $ver (se requiere Debian 13 o Ubuntu 26.04)"
}

ip_publica() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

validar() {
  local d
  [ -n "$UX_PANEL_DOMAIN" ] || die "falta --panel-domain"
  [ -n "$UX_API_DOMAIN" ] || die "falta --api-domain"
  [ -n "$UX_ACME_EMAIL" ] || die "falta --acme-email"
  for d in "$UX_PANEL_DOMAIN" "$UX_API_DOMAIN"; do
    [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "dominio inválido (minúsculas, FQDN): $d"
  done
  [ "$UX_PANEL_DOMAIN" != "$UX_API_DOMAIN" ] || die "el panel y la API necesitan dominios distintos"
  [[ $UX_ACME_EMAIL =~ ^[^@[:space:]\']+@[^@[:space:]\']+\.[^@[:space:]\']+$ ]] || die "correo inválido: $UX_ACME_EMAIL"
  [[ $UX_ADMIN_EMAIL =~ ^[^@[:space:]\']+@[^@[:space:]\']+\.[^@[:space:]\']+$ ]] || die "correo inválido: $UX_ADMIN_EMAIL"
  [[ $UX_SSH_PORT =~ ^[0-9]+$ ]] && [ "$UX_SSH_PORT" -ge 1024 ] && [ "$UX_SSH_PORT" -le 65535 ] ||
    die "--ssh-port fuera de 1024-65535: $UX_SSH_PORT"
  [[ $UX_ADMIN_USER =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "usuario administrador inválido: $UX_ADMIN_USER"
  [ -f "/usr/share/zoneinfo/$UX_TIMEZONE" ] || die "zona horaria desconocida: $UX_TIMEZONE"
  [[ $UX_PUBLIC_IP =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "no pude averiguar la IP pública (usa --public-ip)"
  grep -qE '^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com) ' <<< "$LLAVE_ADMIN" ||
    die "falta una llave pública ed25519 o ecdsa del administrador (--ssh-key, o en /root/.ssh/authorized_keys)"
  [ -z "$UX_RELEASE_URL" ] || [[ $UX_RELEASE_URL =~ ^https?://[A-Za-z0-9.:/_~%-]+$ ]] ||
    die "--release-url inválida: $UX_RELEASE_URL"
  [ -z "$UX_ACME_CA" ] || [[ $UX_ACME_CA =~ ^https://[A-Za-z0-9.:/_~%-]+$ ]] || die "--acme-ca: URL https sin espacios"
  [ -z "$RAIZ_ACME" ] || { [ -n "$UX_ACME_CA" ] && grep -q 'BEGIN CERTIFICATE' "$RAIZ_ACME" 2>/dev/null; } ||
    die "--acme-ca-root necesita --acme-ca y un certificado PEM legible"
}

dns_apunta() {
  local d ips
  for d in "$UX_PANEL_DOMAIN" "$UX_API_DOMAIN"; do
    ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ' ' -)"
    grep -qwF "$UX_PUBLIC_IP" <<< "$ips" ||
      die "$d apunta a «${ips:-nada}», no a $UX_PUBLIC_IP. Crea el registro A y espera a que propague."
  done
}

paquetes_previos() {
  local falta=() p
  for p in curl ca-certificates python3 minisign; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || falta+=("$p")
  done
  [ "${#falta[@]}" -eq 0 ] && return 0
  info "instalando ${falta[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${falta[@]}" >/dev/null
}

descargar() {
  local tmp="$UX_RELEASES/.descarga" rc=0
  rm -rf "$tmp"
  VERSION="$(ux_release_descargar "$VERSION" "$tmp")" || rc=$?
  if [ "$rc" -eq 2 ]; then
    [ -n "$UX_GH_TOKEN" ] || die "el release de $UX_RELEASE_REPO no es público: pasa un token de solo lectura con --token-file"
    rc=0
    VERSION="$(ux_release_descargar "$VERSION" "$tmp")" || rc=$?
  fi
  [ "$rc" -eq 0 ] || die "no pude descargar un release verificado de ${UX_RELEASE_URL:-$UX_RELEASE_REPO}"
  rm -rf "${UX_RELEASES:?}/$VERSION"
  mv "$tmp" "$UX_RELEASES/$VERSION"
  info "release $VERSION verificado (firma, sumas y manifest)"
}

escribir_conf() {
  local v
  install -d -m 700 "$UX_ETC_APP"
  (
    umask 077
    {
      echo "# Configuración de la instalación de uxdeployar (install.sh $VERSION). Solo root."
      for v in UX_RELEASE_REPO UX_RELEASE_URL UX_IMAGE_REGISTRY UX_SIGNING_PUBKEY UX_PANEL_DOMAIN UX_API_DOMAIN \
        UX_ACME_EMAIL UX_ACME_CA UX_ADMIN_EMAIL UX_ADMIN_USER UX_SSH_PORT UX_PUBLIC_IP UX_TIMEZONE; do
        printf '%s=%q\n' "$v" "${!v}"
      done
    } > "$UX_ETC_APP/install.conf"
    printf '%s\n' "$LLAVE_ADMIN" > "$UX_ETC_APP/admin_authorized_keys"
    [ -z "$UX_GH_TOKEN" ] || printf '%s\n' "$UX_GH_TOKEN" > "$UX_ETC_APP/github-token"
  )
  [ -z "$RAIZ_ACME" ] || install -m 644 "$RAIZ_ACME" "$UX_ETC_APP/acme-ca-root.pem"
  printf '%s\n' "$VERSION" > "$UX_ETC_APP/target-version"
}

main() {
  local SI=0 VERSION=latest LLAVE_ADMIN="" RAIZ_ACME=""
  UX_PANEL_DOMAIN="" UX_API_DOMAIN="" UX_ACME_EMAIL="" UX_ADMIN_EMAIL="" UX_SSH_PORT=""
  UX_ADMIN_USER="" UX_PUBLIC_IP="" UX_TIMEZONE="" UX_GH_TOKEN="${UX_GH_TOKEN:-}"
  UX_ACME_CA="" UX_RELEASE_URL="${UX_RELEASE_URL:-}"
  UX_IMAGE_REGISTRY="${UX_IMAGE_REGISTRY:-}" UX_SIGNING_PUBKEY="${UX_SIGNING_PUBKEY:-$UX_SIGNING_PUBKEY_DEFAULT}"
  opciones "$@"

  [ "$(id -u)" -eq 0 ] || die "ejecútalo como root (curl … | sudo bash)"
  sistema_soportado
  [ ! -s "$UX_ETC_APP/version" ] || die "uxdeployar ya está instalado ($(cat "$UX_ETC_APP/version")): usa sudo uxdeployar update"
  [[ $UX_SIGNING_PUBKEY == RW* ]] || die "falta la llave pública de firma de los releases (--signing-pubkey)"

  UX_ADMIN_EMAIL="${UX_ADMIN_EMAIL:-$UX_ACME_EMAIL}"
  UX_SSH_PORT="${UX_SSH_PORT:-2222}"
  UX_ADMIN_USER="${UX_ADMIN_USER:-vpsadmin}"
  [ -n "$UX_TIMEZONE" ] || UX_TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  UX_TIMEZONE="${UX_TIMEZONE:-UTC}"
  [ -n "$UX_PUBLIC_IP" ] || UX_PUBLIC_IP="$(ip_publica)"
  [ -n "$LLAVE_ADMIN" ] || LLAVE_ADMIN="$(grep -E '^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com) ' /root/.ssh/authorized_keys 2>/dev/null || true)"
  validar
  dns_apunta

  local ca="$UX_ACME_CA"
  [ -n "$ca" ] || ca="Let's Encrypt"
  cat <<EOF

uxdeployar se instalará en este VPS ($UX_PUBLIC_IP):
  panel  https://$UX_PANEL_DOMAIN      API  https://$UX_API_DOMAIN
  SSH    $UX_ADMIN_USER@$UX_PUBLIC_IP -p $UX_SSH_PORT (solo llave)
  TLS    $ca
El endurecimiento no se deshace y el puerto 22 se cierra en la etapa E03.
Respaldos (E14), alertas y 2FA de SSH quedan para el panel.
EOF
  [ "$SI" = 1 ] || die "repite con --yes para confirmar"

  paquetes_previos
  install -d -m 755 "$UX_RELEASES"
  descargar
  escribir_conf
  bash "$UX_RELEASES/$VERSION/bundle/installer/runtime/uxdeployar" _activar "$VERSION"
  info "instalación en marcha como servicio (sigue sola tras cortes y reinicios)"
  exec /usr/local/bin/uxdeployar logs --hasta-terminar
}

main "$@"
