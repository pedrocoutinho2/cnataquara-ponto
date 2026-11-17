#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Extrai migrations aplicadas no Supabase para arquivos .sql versionaveis.
#
# Le supabase_migrations.schema_migrations e grava um arquivo por migration,
# no formato <version>_<name>.sql. Confere o md5 de cada arquivo contra o
# banco e aborta se algum divergir.
#
# Uso:
#   export PGURI='postgresql://postgres.<ref>:<senha>@<host>:5432/postgres'
#   ./extrair-migrations.sh <pasta-destino> [version-minima]
#
# Exemplos:
#   ./extrair-migrations.sh sql                 # todas
#   ./extrair-migrations.sh sql 20260827000000  # so as de 27/08 em diante
#
# A connection string sai de: Supabase > Project Settings > Database >
# Connection string > URI. Ela contem a senha do banco: nunca commite,
# nunca cole em chat. Use export no shell ou um gerenciador de senhas.
# ---------------------------------------------------------------------------
set -euo pipefail

DEST="${1:?informe a pasta destino, ex: sql}"
DESDE="${2:-00000000000000}"

if [ -z "${PGURI:-}" ]; then
  echo "ERRO: variavel PGURI nao definida." >&2
  echo "  export PGURI='postgresql://postgres.<ref>:<senha>@<host>:5432/postgres'" >&2
  exit 1
fi

command -v psql >/dev/null 2>&1 || {
  echo "ERRO: psql nao encontrado. Instale com: brew install libpq" >&2
  echo "  e adicione ao PATH: echo 'export PATH=\"/opt/homebrew/opt/libpq/bin:\$PATH\"' >> ~/.zshrc" >&2
  exit 1
}

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Lendo migrations >= $DESDE ..."

# Lista de version|name|md5, separada por barra vertical.
psql "$PGURI" -At -F '|' -v ON_ERROR_STOP=1 <<SQL > "$TMP/lista"
select version,
       name,
       md5(convert_to(array_to_string(statements, E'\n'), 'UTF8'))
  from supabase_migrations.schema_migrations
 where version >= '$DESDE'
 order by version;
SQL

TOTAL=$(wc -l < "$TMP/lista" | tr -d ' ')
if [ "$TOTAL" = "0" ]; then
  echo "Nenhuma migration encontrada nesse intervalo."
  exit 0
fi
echo "$TOTAL migrations encontradas."
echo

FALHAS=0
while IFS='|' read -r VERSION NAME MD5_ESPERADO; do
  [ -z "$VERSION" ] && continue
  ARQ="$DEST/${VERSION}_${NAME}.sql"

  # -X evita que um ~/.psqlrc injete texto no output.
  psql "$PGURI" -At -X -v ON_ERROR_STOP=1 <<SQL > "$ARQ"
select array_to_string(statements, E'\n')
  from supabase_migrations.schema_migrations
 where version = '$VERSION';
SQL

  # psql -At acrescenta um \n final que nao existe no valor da coluna.
  perl -0777 -pi -e 's/\n\z//' "$ARQ"

  MD5_OBTIDO=$(md5 -q "$ARQ" 2>/dev/null || md5sum "$ARQ" | cut -d' ' -f1)

  if [ "$MD5_OBTIDO" = "$MD5_ESPERADO" ]; then
    printf '  OK     %s\n' "$(basename "$ARQ")"
  else
    printf '  FALHA  %s  (esperado %s, obtido %s)\n' "$(basename "$ARQ")" "$MD5_ESPERADO" "$MD5_OBTIDO"
    FALHAS=$((FALHAS + 1))
  fi
done < "$TMP/lista"

echo
if [ "$FALHAS" -gt 0 ]; then
  echo "$FALHAS arquivo(s) com md5 divergente. NAO comite antes de investigar." >&2
  exit 1
fi

echo "Todos os $TOTAL arquivos conferem por md5."
echo "Proximo passo: git add $DEST && git commit"
