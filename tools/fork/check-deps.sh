#!/usr/bin/env bash
#
# Falha se as dependencias em submodulo nao estiverem exatamente nos commits
# pinados por este commit do fork.
#
# Por que existe: upstream ARMSX3 deixa librashader e libadrenotools como
# checkouts manuais (`git clone` a mao, ambos no .gitignore). O que se compila
# passa a depender do dia em que a pessoa clonou, e duas medicoes tiradas em
# semanas diferentes podem diferir por causa da dependencia e nao do patch --
# exatamente o A/B falso que a regra "medir antes de mudar" precisa excluir.
# Este fork os tornou submodulos; este script impede que voltem a derivar em
# silencio.
#
# Uso:  tools/fork/check-deps.sh [--fix] [--require-all]
#
#   --fix           roda `git submodule update --init --recursive` antes de conferir.
#   --require-all   exige TODO submodulo inicializado, nao so os dois do fork.
#                   E o modo que tools/fork/build.sh e o CI usam: um build real
#                   precisa de llvm, glslang, zlib e companhia. Sem a flag o
#                   script confere o que existe e apenas informa o que falta,
#                   para poder rodar num checkout parcial sem exigir ~20 GB.
#
# Saida:  0 = pins intactos;  1 = deriva, sujeira ou falta;  2 = erro de uso.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FIX=0
REQUIRE_ALL=0
for arg in "$@"; do
	case "$arg" in
		--fix)         FIX=1 ;;
		--require-all) REQUIRE_ALL=1 ;;
		*) echo "uso: $0 [--fix] [--require-all]" >&2; exit 2 ;;
	esac
done

# Os dois que este fork pinou e que o upstream nao pina. Sao exigidos sempre:
# guarda-los e a razao de ser deste script.
FORK_PINNED=(
	"3rdparty/librashader"
	"android/armsx3-ui/app/src/main/cpp/libadrenotools"
)

is_fork_pinned() {
	local p="$1" f
	for f in "${FORK_PINNED[@]}"; do [ "$p" = "$f" ] && return 0; done
	return 1
}

if [ "$FIX" = 1 ]; then
	echo "==> git submodule update --init --recursive"
	git submodule update --init --recursive || exit 1
fi

fail=0
missing_optional=0

# `git submodule status --recursive` marca cada linha:
#   ' '  no commit gravado        '-'  nao inicializado
#   '+'  em commit diferente      'U'  conflito de merge
# Ele so desce em submodulos ja inicializados, entao a lista cresce conforme o
# checkout, e nao ha como pedir o estado de algo que ainda nao existe.
while IFS= read -r line; do
	[ -n "$line" ] || continue
	marker="${line:0:1}"
	rest="${line:1}"
	sha="${rest%% *}"
	path="${rest#* }"
	path="${path% (*}"

	case "$marker" in
		' ') ;;
		'+') echo "DERIVA     $path esta em $sha, nao no commit pinado"; fail=1 ;;
		'U') echo "CONFLITO   $path tem conflito de merge"; fail=1 ;;
		'-')
			if [ "$REQUIRE_ALL" = 1 ] || is_fork_pinned "$path"; then
				echo "FALTANDO   $path nao esta inicializado"; fail=1
			else
				missing_optional=$((missing_optional + 1))
			fi
			;;
		*) echo "DESCONHECIDO marcador '$marker' em $path"; fail=1 ;;
	esac
done < <(git submodule status --recursive)

# Um submodulo no commit certo mas com arquivos editados produz um binario que
# nenhum commit descreve -- para uma medicao isso e tao ruim quanto deriva de
# commit, e o `ignore = dirty` que o fork herda do estilo do upstream esconde
# exatamente este caso, entao ele e conferido a parte.
#
# So vale para submodulos JA inicializados: `git -C` num diretorio vazio sobe a
# arvore ate o superprojeto e devolveria a sujeira DELE como se fosse a do
# submodulo. Comparar o toplevel com o caminho e o que descarta esse caso.
while IFS= read -r path; do
	[ -n "$path" ] || continue
	[ -e "$path/.git" ] || continue
	top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || continue
	[ "$top" = "$ROOT/$path" ] || continue
	if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
		echo "SUJO       $path tem modificacoes locais nao commitadas"
		fail=1
	fi
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

if [ "$fail" != 0 ]; then
	echo
	echo "As dependencias nao batem com os pins deste commit." >&2
	echo "Rode  tools/fork/check-deps.sh --fix  e refaca o build antes de medir." >&2
	exit 1
fi

if [ "$missing_optional" -gt 0 ]; then
	echo "OK: os pins do fork estao intactos ($missing_optional submodulo(s) upstream" \
	     "nao inicializado(s); use --require-all antes de um build)."
else
	echo "OK: todos os submodulos estao nos commits pinados e limpos."
fi
